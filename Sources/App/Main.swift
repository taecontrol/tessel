import AppKit
import ApplicationServices

@main
struct Main {
    @MainActor static func main() {
        LaunchOptions.validate()
        if CommandLine.arguments.dropFirst().first == "--check-permission" {
            exit(AXIsProcessTrusted() ? 0 : 1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum LaunchOptions {
    static var fixtureOnly: Bool {
        #if TESSEL_DEVELOPMENT
        Bundle.main.bundleIdentifier == "com.taecontrol.tessel.dev" && CommandLine.arguments.contains("--test-fixture-only")
        #else
        false
        #endif
    }
    static var missingSkyLight: Bool { fixtureOnly && CommandLine.arguments.contains("--test-missing-skylight") }
    static var failedHide: Bool { fixtureOnly && CommandLine.arguments.contains("--test-failed-hide") }
    static var captureUI: Bool { fixtureOnly && CommandLine.arguments.contains("--test-capture-ui") }
    static var failedRelaunch: Bool { fixtureOnly && CommandLine.arguments.contains("--test-failed-relaunch") }
    static var shortRestartWait: Bool { fixtureOnly && CommandLine.arguments.contains("--test-short-restart-wait") }
    static let restartAfter: Int32? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--restart-after") else { return nil }
        guard args.filter({ $0 == "--restart-after" }).count == 1,
              args.indices.contains(index + 1), let pid = Int32(args[index + 1]), pid > 0 else { exit(2) }
        return pid
    }()

    static var restartArguments: [String] {
        let args = CommandLine.arguments
        var carried = args.filter { $0.hasPrefix("--test-") }
        // Preserve the harness's process-local motion preference as well as its
        // fixture isolation; never inherit the desktop's preference on restart.
        if fixtureOnly, let index = args.firstIndex(of: "-reduceMotion"), args.indices.contains(index + 1) {
            carried += [args[index], args[index + 1]]
        }
        return carried
    }

    static func validate() {
        _ = restartAfter
        let tests = CommandLine.arguments.filter { $0.hasPrefix("--test-") }
        guard tests.isEmpty || fixtureOnly && tests.allSatisfy({ ["--test-fixture-only", "--test-missing-skylight", "--test-failed-hide", "--test-capture-ui", "--test-failed-relaunch", "--test-short-restart-wait"].contains($0) }) else { exit(2) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var config: ConfigManager?
    private var store: SnapshotStore?
    private var server: SocketServer?
    private var windows: WindowCatalog?
    private var permissionMonitor: PermissionMonitor?
    private var workspaces: Workspaces?
    private var termination: DispatchSourceSignal?
    private let diagnostics = SystemDiagnostics()
    private lazy var restart = Restart(now: { DispatchTime.now().uptimeNanoseconds }, record: diagnostics.record,
                                       launch: { done in SystemRelaunch.launch { done($0) } },
                                       quit: { [weak self] in self?.quit() })
    private var systemEvents: SystemEvents?
    #if TESSEL_DEVELOPMENT
    private let capture = LaunchOptions.captureUI ? DevelopmentCapture() : nil
    #else
    private let loginItem = SystemLoginItem()
    #endif
    private let trusted = AXIsProcessTrusted()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SystemRelaunch.awaitPrevious(ready: { [weak self] in self?.setUp() }, abandoned: { [weak self] pid in
            self?.diagnostics.record(.restartAbandoned(previous: pid))
            NSApp.terminate(nil)
        }) { return }
        setUp()
    }

    private func setUp() {
        let scheduler = SystemScheduler()
        let applications = SystemApplications()
        let ax = SystemAccessibility()
        let file = ConfigFile()
        let config = ConfigManager(path: file.file.path, main: scheduler.main, diagnostics: diagnostics,
                                   load: { try file.load() }, watch: { file.watch() })
        diagnostics.record(.started(version: BuildInfo.version, permission: trusted, config: config.status.state))
        systemEvents = SystemEvents(diagnostics: diagnostics)
        file.onChange = { [weak config] in config?.scheduleReload() }
        self.config = config
        #if TESSEL_DEVELOPMENT
        let openAtLogin = OpenAtLogin(development: true, bundle: Bundle.main.bundleURL,
                                      home: FileManager.default.homeDirectoryForCurrentUser, read: { .notRegistered })
        let store = SnapshotStore(status: appStatus(config.status), openAtLogin: openAtLogin)
        #else
        var openAtLogin = OpenAtLogin(development: false, bundle: Bundle.main.bundleURL,
                                      home: FileManager.default.homeDirectoryForCurrentUser, read: loginItem.state)
        // Register before permission-dependent setup: tessel must also return at
        // login to explain a missing Accessibility grant.
        if let request = openAtLogin.launchRequest {
            let refused = loginItem.perform(request)
            openAtLogin = openAtLogin.performed(refused: refused, now: loginItem.state())
        }
        let store = SnapshotStore(status: appStatus(config.status), openAtLogin: openAtLogin, readLoginItem: loginItem.state)
        #endif
        self.store = store
        let stage = SystemMotionStage()
        let map = SystemRailsMap()
        #if TESSEL_DEVELOPMENT
        if LaunchOptions.fixtureOnly {
            store.enableMotionInstrumentation()
            stage.onEvent = { store.recordStage($0) }
            store.recordMap(AppStatus.TestMap())
            map.onEvent = { store.recordMap($0) }
            map.onCapture = { [weak self] in self?.capture?.update(map: $0) }
        }
        #endif
        do {
            server = try SocketServer(respond: { store.reply(to: $0) }, restart: { [weak self] deadline, reply in
                guard let self else { reply(Reply(error: "Tessel is quitting")); return }
                self.restart.request(.cli, deadline: deadline) { outcome in
                    switch outcome {
                    case .restarted(let pid): reply(Reply(restarted: pid))
                    case .failed(let reason): reply(Reply(error: RestartWait.launchFailed(reason)))
                    case .refused(let reason): reply(Reply(error: reason))
                    }
                }
            })
        }
        catch { NSApp.terminate(nil); return }
        var skyLight: SkyLightCloset?
        let workspaces = Workspaces(store: store, trusted: trusted, configuration: config.status.effective,
                                    applications: applications, ax: ax, screens: SystemScreen(), windowOrder: SystemWindowOrder(),
                                    scheduler: scheduler, hotkeys: SystemHotkeys(), fixtureOnly: LaunchOptions.fixtureOnly,
                                    motionPreferences: SystemMotionPreferences(), stage: stage, pointerActivity: SystemPointerActivity(), map: map,
                                    diagnostics: diagnostics) {
            let closet = try SkyLightCloset(simulateMissing: LaunchOptions.missingSkyLight, simulateFailedHide: LaunchOptions.failedHide)
            skyLight = closet
            return closet
        }
        // The closet's Space holds the only windows WindowServer lists off
        // screen that are still drawn.
        if let skyLight { stage.inCloset = { skyLight.memberships($0, scope: .ordinary).isEmpty } }
        self.workspaces = workspaces
        workspaces.onChange = { [weak self] in
            guard let self else { return }
            store.update(status: self.appStatus(config.status))
            self.updateMenu()
        }
        config.onChange = { [weak self] status in
            guard let self else { return }
            workspaces.configure(status.effective)
            store.update(status: self.appStatus(status))
            self.updateMenu()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenu()
        if trusted {
            windows = WindowCatalog(workspaces: workspaces, applications: applications, ax: ax, windowOrder: SystemWindowOrder(), scheduler: scheduler,
                                    diagnostics: diagnostics,
                                    fixtureBundleID: LaunchOptions.fixtureOnly ? "com.taecontrol.tessel.fixture" : nil)
            workspaces.catalog = windows
        } else {
            let monitor = PermissionMonitor { [weak self] in self?.requestRestart(.permission) }
            permissionMonitor = monitor
            monitor.start()
        }
        store.update(status: appStatus(config.status))
        // Harness termination and ordinary SIGTERM share the normal cleanup path.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { [weak self] in self?.quit() }
        termination.resume()
        self.termination = termination
        store.markReady()
    }

    private func appStatus(_ config: ConfigStatus) -> AppStatus {
        var status = AppStatus(permission: trusted ? "granted" : "needed", config: config, version: BuildInfo.version, pid: getpid())
        status.workspaces = workspaces?.status ?? WorkspaceStatus()
        return status
    }

    private func updateMenu(_ existingMenu: NSMenu? = nil) {
        guard let config else { return }
        let menu = existingMenu ?? NSMenu()
        menu.removeAllItems()
        let workspace = workspaces?.status ?? WorkspaceStatus()
        if workspace.enabled {
            statusItem?.button?.title = String(workspace.active)
            if workspace.layout == "carousel" {
                let count = max(1,workspace.railCount)
                let glyph = NSImage(size:NSSize(width:18,height:18),flipped:false) { rect in
                    let step = min(5,18/Double(count)), bar = min(3,step*0.6)
                    for index in 0..<count {
                        NSColor.labelColor.withAlphaComponent(index+1 == workspace.rail ? 1 : 0.35).setFill()
                        NSBezierPath(roundedRect:NSRect(x:0,y:rect.midY+Double(count)*step/2-Double(index+1)*step,
                                                     width:18,height:bar),xRadius:1,yRadius:1).fill()
                    }
                    return true
                }
                glyph.isTemplate = false
                statusItem?.button?.image = glyph
                statusItem?.button?.imagePosition = .imageRight
            } else { statusItem?.button?.image = nil }
            menu.addItem(withTitle: "Workspace \(workspace.active)", action: nil, keyEquivalent: "")
        } else {
            // Reuse the number's text renderer. Images and fallback symbol fonts
            // keep extra graphics/font caches resident while workspaces are enabled.
            statusItem?.button?.title = "t"
            statusItem?.button?.image = nil
            menu.addItem(withTitle: "Workspaces disabled: \(workspace.reason)", action: nil, keyEquivalent: "")
        }
        let permission = trusted ? "Accessibility permission granted" : "Accessibility permission needed"
        menu.addItem(withTitle: permission, action: nil, keyEquivalent: "")
        if !trusted {
            let settings = menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
        }
        if let error = config.status.error {
            menu.addItem(withTitle: "Configuration error (line \(error.line)): \(error.message)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        #if !TESSEL_DEVELOPMENT
        let openAtLogin = store?.openAtLogin ?? .development
        switch openAtLogin.menuItem {
        case .absent: break
        case .disabled(let title):
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        case .toggle(let on):
            let item = menu.addItem(withTitle: "Open at Login", action: #selector(changeOpenAtLogin), keyEquivalent: "")
            item.target = self
            item.state = on ? .on : .off
        case .openSettings:
            let item = menu.addItem(withTitle: "Open at Login…", action: #selector(changeOpenAtLogin), keyEquivalent: "")
            item.target = self
        }
        if case .installed = openAtLogin, let reason = openAtLogin.status.reason {
            menu.addItem(withTitle: reason, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.delegate = self
        #endif
        let reload = menu.addItem(withTitle: "Reload config", action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        menu.addItem(withTitle: config.status.path, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let restartItem = menu.addItem(withTitle: "Restart Tessel", action: #selector(restartTessel), keyEquivalent: "")
        restartItem.target = self
        let quitItem = menu.addItem(withTitle: "Quit Tessel", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        if existingMenu == nil { statusItem?.menu = menu }
        let label = config.status.error.map { "Configuration error (line \($0.line))" }
            ?? (workspace.enabled ? "Workspace \(workspace.active)" + (workspace.layout == "carousel" ? ", rail \(workspace.rail ?? 0) of \(workspace.railCount)" : "") : "Workspaces disabled: \(workspace.reason)")
        statusItem?.button?.setAccessibilityLabel("Tessel: " + label)
        statusItem?.button?.toolTip = label
        #if TESSEL_DEVELOPMENT
        if let button = statusItem?.button { capture?.update(button: button, menu: menu, status: workspace) }
        #endif
    }

    @objc private func reloadConfig() { config?.reload() }

    @objc private func restartTessel() { requestRestart(.menu) }

    private func requestRestart(_ source: RestartSource) {
        restart.request(source, deadline: nil) { outcome in
            guard case .failed(let reason) = outcome else { return }
            // Let the coordinator fail every CLI waiter before a modal alert
            // keeps this callback on the stack until the owner dismisses it.
            DispatchQueue.main.async {
                let alert = NSAlert()
                if source == .permission {
                    alert.messageText = "Reopen Tessel to use Accessibility"
                    alert.informativeText = "The permission is granted. Quit and open Tessel again."
                } else {
                    alert.messageText = "Tessel could not restart"
                    alert.informativeText = reason
                }
                alert.runModal()
            }
        }
    }

    #if !TESSEL_DEVELOPMENT
    @objc private func changeOpenAtLogin() {
        store?.changeOpenAtLogin(loginItem.perform)
        updateMenu()
    }
    #endif

    @objc private func quit() {
        restart.quitting()
        guard let workspaces else { NSApp.terminate(nil); return }
        // Return to the main queue while draining. AppKit's terminateLater
        // wait cannot reenter the queue running the SIGTERM handler.
        workspaces.prepareToQuit { NSApp.terminate(nil) }
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Owned quit sources drain before asking AppKit; logout and other
        // external termination requests must proceed without a modal wait.
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemEvents?.stop()
        if let workspaces { workspaces.disable(reason: "quit") }
        else { diagnostics.record(.quit) }
        server?.stop()
    }
}

#if !TESSEL_DEVELOPMENT
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // AppKit permits rebuilding here, not in menuWillOpen. Shortcut
        // matching needs no titles and must not cause a BTM read.
        guard menu.propertiesToUpdate.contains(.propertyItemTitle) else { return }
        store?.refreshOpenAtLogin()
        updateMenu(menu)
    }
}
#endif
