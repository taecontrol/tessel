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
    static func validate() {
        let tests = CommandLine.arguments.filter { $0.hasPrefix("--test-") }
        guard tests.isEmpty || fixtureOnly && tests.allSatisfy({ ["--test-fixture-only", "--test-missing-skylight", "--test-failed-hide", "--test-capture-ui"].contains($0) }) else { exit(2) }
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
    #if TESSEL_DEVELOPMENT
    private let capture = LaunchOptions.captureUI ? DevelopmentCapture() : nil
    #endif
    private let trusted = AXIsProcessTrusted()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigManager()
        self.config = config
        let store = SnapshotStore(status: appStatus(config.status))
        self.store = store
        do { server = try SocketServer { store.reply(to: $0) } }
        catch { NSApp.terminate(nil); return }
        let workspaces = Workspaces(store: store, trusted: trusted, configuration: config.status.effective,
                                    simulateMissing: LaunchOptions.missingSkyLight, simulateFailedHide: LaunchOptions.failedHide)
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
            windows = WindowCatalog(workspaces: workspaces, fixtureOnly: LaunchOptions.fixtureOnly)
            workspaces.catalog = windows
        } else {
            let monitor = PermissionMonitor { [weak self] in self?.relaunch() }
            permissionMonitor = monitor
            monitor.start()
        }
        store.update(status: appStatus(config.status))
        // Harness termination and ordinary SIGTERM share the normal cleanup path.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        self.termination = termination
        store.markReady()
    }

    private func appStatus(_ config: ConfigStatus) -> AppStatus {
        var status = AppStatus(permission: trusted ? "granted" : "needed", config: config, version: BuildInfo.version, pid: getpid())
        status.workspaces = workspaces?.status ?? WorkspaceStatus()
        return status
    }

    private func updateMenu() {
        guard let config else { return }
        let menu = NSMenu()
        let workspace = workspaces?.status ?? WorkspaceStatus()
        if workspace.enabled {
            statusItem?.button?.title = String(workspace.active)
            menu.addItem(withTitle: "Workspace \(workspace.active)", action: nil, keyEquivalent: "")
        } else {
            // Reuse the number's text renderer. Images and fallback symbol fonts
            // keep extra graphics/font caches resident while workspaces are enabled.
            statusItem?.button?.title = "t"
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
        let reload = menu.addItem(withTitle: "Reload config", action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        menu.addItem(withTitle: config.status.path, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit tessel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        let label = config.status.error.map { "Configuration error (line \($0.line))" }
            ?? (workspace.enabled ? "Workspace \(workspace.active)" : "Workspaces disabled: \(workspace.reason)")
        statusItem?.button?.setAccessibilityLabel("tessel: " + label)
        statusItem?.button?.toolTip = label
        #if TESSEL_DEVELOPMENT
        if let button = statusItem?.button { capture?.update(button: button, menu: menu, status: workspace) }
        #endif
    }

    @objc private func reloadConfig() { config?.reload() }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func relaunch() {
        server?.stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-n", "-g"]
        if let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            arguments += ["--env", "XDG_CONFIG_HOME=" + configHome]
        }
        arguments.append(Bundle.main.bundleURL.path)
        if LaunchOptions.fixtureOnly { arguments += ["--args", "--test-fixture-only"] }
        process.arguments = arguments
        do { try process.run(); NSApp.terminate(nil) }
        catch {
            // Leave a useful menu if LaunchServices cannot relaunch the bundle.
            let alert = NSAlert()
            alert.messageText = "Reopen tessel to use Accessibility"
            alert.informativeText = "The permission is granted. Quit and open tessel again."
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaces?.disable(reason: "experiment off")
        server?.stop()
    }
}
