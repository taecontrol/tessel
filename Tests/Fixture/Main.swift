import AppKit
import ApplicationServices
import Darwin

@_silgen_name("_AXUIElementGetWindow")
func fixtureWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

final class DialogWindow: NSWindow {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    var windows: [String: NSWindow] = [:]
    var socketFD: Int32 = -1
    var source: DispatchSourceRead?
    var socketPath = ""
    var transitions: [UUID: NSObjectProtocol] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWindow.allowsAutomaticWindowTabbing = false
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--socket"), index + 1 < args.count else { exit(2) }
        socketPath = args[index + 1]
        socketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(2) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        unlink(socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { exit(2) }
        chmod(socketPath, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        source.setEventHandler { [weak self] in self?.receive() }
        source.resume()
        self.source = source
    }

    func receive() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var sender = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let count = withUnsafeMutablePointer(to: &sender) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0, let command = try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any] else { return }
        let action = command["action"] as? String ?? ""
        if ["minimize", "restore"].contains(action), let key = command["key"] as? String, let window = windows[key],
           window.isMiniaturized != (action == "minimize") {
            // The accepted deadline starts after the native Dock animation, at
            // AppKit's completion notification, rather than at the request.
            let operation = UUID()
            let destination = sender
            let destinationLength = length
            let name = action == "minimize" ? NSWindow.didMiniaturizeNotification : NSWindow.didDeminiaturizeNotification
            transitions[operation] = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishTransition(operation, to: destination, length: destinationLength)
                }
            }
            _ = perform(command)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finishTransition(operation, to: destination, length: destinationLength, error: "native window transition did not finish")
            }
            return
        }
        send(perform(command), to: sender, length: length)
        if action == "hang" {
            // A real blocked AppKit main thread, after acknowledging the request.
            DispatchQueue.main.async { while true { sleep(3600) } }
        }
    }

    func finishTransition(_ operation: UUID, to sender: sockaddr_un, length: socklen_t, error: String? = nil) {
        guard let token = transitions.removeValue(forKey: operation) else { return }
        NotificationCenter.default.removeObserver(token)
        send(error.map { ["error": $0] } ?? snapshot, to: sender, length: length)
    }

    func send(_ response: [String: Any], to sender: sockaddr_un, length: socklen_t) {
        var destination = sender
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketFD, bytes.baseAddress, data.count, 0, $0, length) }
            }
        }
    }

    func perform(_ command: [String: Any]) -> [String: Any] {
        let action = command["action"] as? String ?? ""
        let key = command["key"] as? String ?? "window"
        switch action {
        case "ping": break
        case "reset":
            NSApp.unhide(nil)
            for window in windows.values where window.sheetParent != nil { window.sheetParent?.endSheet(window) }
            for window in windows.values { window.close() }
            windows.removeAll()
        case "open":
            let kind = command["kind"] as? String ?? "standard"
            let count = command["count"] as? Int ?? 3
            if kind == "tabs" {
                let first = makeWindow(key: key + "0", kind: "standard")
                first.tabbingMode = .preferred
                first.tabbingIdentifier = key
                for index in 1..<max(1, count) {
                    let window = makeWindow(key: key + String(index), kind: "standard")
                    window.tabbingMode = .preferred
                    window.tabbingIdentifier = key
                    first.addTabbedWindow(window, ordered: .above)
                }
                if first.tabGroup?.isTabBarVisible != true { first.toggleTabBar(nil) }
                first.makeKeyAndOrderFront(nil)
            } else if kind == "sheet" {
                let parent = makeWindow(key: key + "Parent", kind: "standard")
                let sheet = makeWindow(key: key, kind: "dialog", show: false)
                parent.beginSheet(sheet)
            } else {
                let background = command["background"] as? Bool ?? false
                let window = makeWindow(key: key, kind: kind, title: command["title"] as? String, show: !background)
                if background { window.orderBack(nil) }
            }
        case "tab": windows[key]?.makeKeyAndOrderFront(nil)
        case "addTab":
            if let reference = windows[command["reference"] as? String ?? "tabs0"] {
                let window = makeWindow(key: key, kind: "standard")
                window.tabbingMode = .preferred
                reference.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        case "close":
            if let window = windows.removeValue(forKey: key) {
                window.sheetParent?.endSheet(window)
                window.close()
            }
        case "minimize": windows[key]?.miniaturize(nil)
        case "restore": windows[key]?.deminiaturize(nil)
        case "hide": NSApp.hide(nil)
        case "show": NSApp.unhide(nil)
        case "hang":
            // A genuine resize notification is delivered just before AppKit blocks.
            // This makes tessel attempt a refresh against the hung application.
            windows["window"]?.setContentSize(NSSize(width: 500, height: 320))
        default: return ["error": "unknown fixture command"]
        }
        return snapshot
    }

    var snapshot: [String: Any] { ["pid": getpid(), "windows": windows.mapValues { $0.windowNumber }] }

    @discardableResult
    func makeWindow(key: String, kind: String, title: String? = nil, show: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if kind != "fixed" { style.insert(.resizable) }
        let rect = NSRect(x: 100, y: 120, width: 480, height: 300)
        let window: NSWindow
        if kind == "panel" {
            window = NSPanel(contentRect: rect, styleMask: style.union(.utilityWindow), backing: .buffered, defer: false)
            (window as? NSPanel)?.isFloatingPanel = true
            (window as? NSPanel)?.hidesOnDeactivate = false
        } else if kind == "dialog" {
            window = DialogWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        } else {
            window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.tabbingMode = .disallowed
        window.title = title ?? "Fixture " + key
        if kind == "noFullscreen" { window.collectionBehavior = .fullScreenNone }
        let label = NSTextField(labelWithString: "Generic fixture window")
        label.frame = NSRect(x: 30, y: 100, width: 350, height: 30)
        window.contentView?.addSubview(label)
        if kind == "contentTabs" {
            let tabs = NSTabView(frame: NSRect(x: 20, y: 20, width: 420, height: 220))
            for index in 1...3 {
                let item = NSTabViewItem(identifier: index)
                item.label = "Fixture page " + String(index)
                tabs.addTabViewItem(item)
            }
            window.contentView?.addSubview(tabs)
        }
        windows[key] = window
        if show { window.makeKeyAndOrderFront(nil) }
        return window
    }
}

// The independent oracle reads only this repository's fixture. It never reads titles.
enum FixtureProbe {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func tabs(_ element: AXUIElement, depth: Int = 0) -> Int {
        guard depth < 5 else { return 0 }
        if value(element, kAXRoleAttribute) as? String == kAXTabGroupRole {
            return (value(element, kAXTabsAttribute) as? [AXUIElement])?.count ?? 0
        }
        return (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(40).map { tabs($0, depth: depth + 1) }.max() ?? 0
    }

    @MainActor static func run(pid: pid_t, resizeID: Int?) {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.taecontrol.tessel.fixture" else { exit(3) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            print("{\"error\":\"fixture AX windows unavailable\"}")
            exit(4)
        }
        func describe(_ window: AXUIElement) -> [String: Any] {
            var id: CGWindowID = 0
            _ = fixtureWindowID(window, &id)
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
            let fullscreen = value(window, kAXFullScreenButtonAttribute).map { value in
                (self.value(value as! AXUIElement, kAXEnabledAttribute) as? Bool ?? false) ? "enabled" : "disabled"
            } ?? "none"
            var result: [String: Any] = ["id": id, "subrole": value(window, kAXSubroleAttribute) as? String ?? "missing",
                "role": value(window, kAXRoleAttribute) as? String ?? "missing", "sizeSettable": settable.boolValue,
                "fullscreen": fullscreen, "tabs": tabs(window)]
            if resizeID == Int(id) {
                var size = CGSize(width: 650, height: 400)
                let axSize = AXValueCreate(.cgSize, &size)!
                result["resizeError"] = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize).rawValue
            }
            result["sheets"] = (value(window, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .filter { value($0, kAXRoleAttribute) as? String == kAXSheetRole }.map(describe)
            return result
        }
        let data = try! JSONSerialization.data(withJSONObject: ["windows": windows.map(describe)], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

@main
struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--check-session" {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
            exit(CGDisplayIsAsleep(CGMainDisplayID()) == 0 && !locked ? 0 : 5)
        }
        if args.count > 2, args[1] == "--probe", let pid = Int32(args[2]) {
            FixtureProbe.run(pid: pid, resizeID: args.count > 3 ? Int(args[3]) : nil)
            return
        }
        let app = NSApplication.shared
        let delegate = Fixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
