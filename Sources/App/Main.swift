import AppKit
import ApplicationServices

@main
struct Main {
    @MainActor static func main() {
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var config: ConfigManager?
    private var store: SnapshotStore?
    private var server: SocketServer?
    private var windows: WindowCatalog?
    private var permissionMonitor: PermissionMonitor?
    private let trusted = AXIsProcessTrusted()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigManager()
        self.config = config
        let store = SnapshotStore(status: appStatus(config.status))
        self.store = store
        do { server = try SocketServer { store.reply(to: $0) } }
        catch { NSApp.terminate(nil); return }
        config.onChange = { [weak self] status in
            guard let self else { return }
            store.update(status: self.appStatus(status))
            self.updateMenu()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: "tessel")
        updateMenu()
        if trusted {
            windows = WindowCatalog(store: store)
        } else {
            let monitor = PermissionMonitor { [weak self] in self?.relaunch() }
            permissionMonitor = monitor
            monitor.start()
        }
    }

    private func appStatus(_ config: ConfigStatus) -> AppStatus {
        AppStatus(permission: trusted ? "granted" : "needed", config: config, version: BuildInfo.version, pid: getpid())
    }

    private func updateMenu() {
        guard let config else { return }
        let menu = NSMenu()
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
        let label = config.status.error.map { "Configuration error (line \($0.line))" } ?? permission
        statusItem?.button?.setAccessibilityLabel("tessel: " + label)
        statusItem?.button?.toolTip = label
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

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }
}
