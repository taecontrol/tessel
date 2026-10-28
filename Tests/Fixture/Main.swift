import AppKit
import ApplicationServices
import Darwin
import Security
import SwiftUI
import WebKit

@_silgen_name("_AXUIElementGetWindow")
func fixtureWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

final class DialogWindow: NSWindow {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

final class NewTabWindow: NSWindow {
    override func newWindowForTab(_ sender: Any?) {}
}

final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class FixtureApplication: NSApplication {
    var windowList: [NSWindow]?
    var withholdsFocusedWindow = false

    override func accessibilityWindows() -> [Any]? {
        windowList ?? super.accessibilityWindows()
    }

    override func accessibilityFocusedWindow() -> Any? {
        withholdsFocusedWindow ? nil : super.accessibilityFocusedWindow()
    }
}

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    static weak var current: Fixture?
    var windows: [String: NSWindow] = [:]
    private var retainedClosedWindows: [NSWindow] = []
    private var minimizeRecorders: [String: MinimizeRecorder] = [:]
    var socketFD: Int32 = -1
    var source: DispatchSourceRead?
    var socketPath = ""
    var transitions: [UUID: NSObjectProtocol] = [:]
    var keyCount = 0
    var clicks: [Int: Int] = [:]
    var keyMonitor: Any?
    let contracts = FixtureContracts()

    override init() {
        super.init()
        Self.current = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown { self?.keyCount += 1 }
                else if let window = event.window { self?.clicks[window.windowNumber, default: 0] += 1 }
            }
            return event
        }
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
        // A twenty-window observation exceeds macOS's 2 KiB datagram default.
        var replyCapacity: Int32 = 65_536
        guard setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF, &replyCapacity, socklen_t(MemoryLayout.size(ofValue: replyCapacity))) == 0 else { exit(2) }
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

    func applicationWillTerminate(_ notification: Notification) {
        _ = try? contracts.perform(["operation":"reset"])
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
        let key = command["key"] as? String ?? "window"
        if ["minimize", "restore", "fullscreen"].contains(action), let window = windows[key],
           action == "fullscreen" || window.isMiniaturized != (action == "minimize") {
            // The accepted deadline starts after the native Dock animation, at
            // AppKit's completion notification, rather than at the request.
            let operation = UUID()
            let destination = sender
            let destinationLength = length
            let respondsOnCompletion = command["waitForTransition"] as? Bool != false
            guard let margin = command["transitionMargin"] as? Double else {
                send(["error": "native transition requires the harness margin"], to: sender, length: length)
                return
            }
            let name = action == "fullscreen"
                ? (window.styleMask.contains(.fullScreen) ? NSWindow.didExitFullScreenNotification : NSWindow.didEnterFullScreenNotification)
                : (action == "minimize" ? NSWindow.didMiniaturizeNotification : NSWindow.didDeminiaturizeNotification)
            transitions[operation] = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishTransition(operation, to: destination, length: destinationLength, responding: respondsOnCompletion)
                }
            }
            _ = perform(command)
            if !respondsOnCompletion { send(snapshot, to: sender, length: length) }
            DispatchQueue.main.asyncAfter(deadline: .now() + margin) { [weak self] in
                self?.finishTransition(operation, to: destination, length: destinationLength, responding: respondsOnCompletion,
                                       error: "native window transition did not finish")
            }
            return
        }
        send(perform(command), to: sender, length: length)
        if action == "hang" {
            // A real blocked AppKit main thread, after acknowledging the request.
            DispatchQueue.main.async { while true { sleep(3600) } }
        }
    }

    func finishTransition(_ operation: UUID, to sender: sockaddr_un, length: socklen_t, responding: Bool, error: String? = nil) {
        guard let token = transitions.removeValue(forKey: operation) else { return }
        NotificationCenter.default.removeObserver(token)
        if responding { send(error.map { ["error": $0] } ?? snapshot, to: sender, length: length) }
    }

    func send(_ response: [String: Any], to sender: sockaddr_un, length: socklen_t) {
        var destination = sender
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketFD, bytes.baseAddress, data.count, 0, $0, length) }
            }
        }
        if sent < 0, errno == EMSGSIZE, response["error"] == nil {
            send(["error": "fixture response exceeds its socket buffer (\(data.count) bytes)"], to: sender, length: length)
        }
    }

    func perform(_ command: [String: Any]) -> [String: Any] {
        let action = command["action"] as? String ?? ""
        let key = command["key"] as? String ?? "window"
        switch action {
        case "contract":
            var reply = snapshot
            do { reply["contract"] = try contracts.perform(command) }
            catch { return ["error": String(describing: error)] }
            return reply
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "ping":
            if CommandLine.arguments.contains("--swiftui"), windows["window"] == nil,
               let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) { windows["window"] = window }
        case "reset":
            transitions.values.forEach { NotificationCenter.default.removeObserver($0) }
            transitions.removeAll()
            (NSApp as? FixtureApplication)?.windowList = nil
            (NSApp as? FixtureApplication)?.withholdsFocusedWindow = false
            NSApp.unhide(nil)
            for window in windows.values where window.sheetParent != nil { window.sheetParent?.endSheet(window) }
            for window in windows.values { window.close() }
            windows.removeAll()
            retainedClosedWindows.removeAll()
            minimizeRecorders.removeAll()
        case "open":
            let kind = command["kind"] as? String ?? "standard"
            let count = command["count"] as? Int ?? 3
            if kind == "tabs" {
                let windowKind = command["windowKind"] as? String ?? "standard"
                let closable = command["closable"] as? Bool ?? true
                let first = makeWindow(key: key + "0", kind: windowKind, closable: closable)
                first.tabbingMode = .preferred
                first.tabbingIdentifier = key
                for index in 1..<max(1, count) {
                    let window = makeWindow(key: key + String(index), kind: windowKind, closable: closable)
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
                let window = makeWindow(key: key, kind: kind, title: command["title"] as? String, show: !background, color: command["color"] as? Int)
                if let fraction = command["widthFraction"] as? Double, let screen = NSScreen.screens.first {
                    var frame = window.frame
                    frame.size.width = ((screen.visibleFrame.width - 20) * fraction).rounded(.down)
                    window.setFrame(frame, display: true)
                }
                if background { window.orderBack(nil) }
            }
        case "replaceChromeDescendant":
            guard let content = windows[key]?.contentView,
                  let child = content.subviews.first(where: { $0 is NSTextField }) else { return ["error": "a fixture subview is required"] }
            let frame = child.frame
            child.removeFromSuperview()
            let replacement = NSTextField(labelWithString: "Replacement fixture content")
            replacement.frame = frame
            content.addSubview(replacement)
        case "paint":
            guard let window = windows[key], let color = command["color"] as? Int, FixtureInstantRecording.colors.indices.contains(color) else { return ["error": "paint needs a fixture window and palette index"] }
            paint(window, color: color)
            window.displayIfNeeded()
        case "preventsCapture":
            guard let video = windows[key]?.contentView as? FixtureVideo, let enabled = command["enabled"] as? Bool else {
                return ["error": "capture protection needs a video fixture and a boolean"]
            }
            video.preventCapture(enabled, afterResize: command["afterResize"] as? Bool == true)
        case "windowLevels":
            let ordinary = makeWindow(key: "ordinary", kind: "standard")
            let dialog = makeWindow(key: "dialog", kind: "dialog")
            makeWindow(key: "panel", kind: "panel")
            ordinary.level = .normal
            dialog.level = .normal
            let popup = NSWindow(contentRect: NSRect(x: 140, y: 180, width: 376, height: 22),
                                 styleMask: .borderless, backing: .buffered, defer: false)
            popup.isReleasedWhenClosed = false
            popup.level = .normal
            popup.animationBehavior = .none
            ordinary.addChildWindow(popup, ordered: .above)
            popup.orderFront(nil)
            windows["popup"] = popup
            let status = makeWindow(key: "status", kind: "dialog", show: false)
            status.level = .statusBar
            status.orderFront(nil)
            ordinary.makeKeyAndOrderFront(nil)
        case "detachTab": windows[key]?.moveTabToNewWindow(nil)
        case "tab": windows[key]?.makeKeyAndOrderFront(nil)
        case "windowList":
            // Model AppKit's lagging AXWindows enumeration with real windows.
            // AXFocusedWindow and the native tab bar still come from AppKit.
            guard let application = NSApp as? FixtureApplication,
                  let keys = command["keys"] as? [String], keys.allSatisfy({ windows[$0] != nil }) else {
                return ["error": "windowList requires existing fixture windows"]
            }
            application.windowList = keys.compactMap { windows[$0] }
        case "focusedWindow":
            // Model AppKit publishing the selected tab's focus only after its
            // bar has left the former root. Publishing announces the real focus.
            guard let application = NSApp as? FixtureApplication else { return ["error": "focusedWindow requires the fixture application"] }
            application.withholdsFocusedWindow = command["published"] as? Bool != true
            if !application.withholdsFocusedWindow {
                // Inactive apps can expose real AX focus without a key window.
                NSAccessibility.post(element: application, notification: .focusedWindowChanged)
                NSAccessibility.post(element: application, notification: .mainWindowChanged)
            }
        case "addTab":
            if let reference = windows[command["reference"] as? String ?? "tabs0"] {
                let activating = command["activating"] as? Bool != false
                let window = makeWindow(key: key, kind: "standard", show: activating)
                window.tabbingMode = .preferred
                reference.addTabbedWindow(window, ordered: .above)
                if activating { window.makeKeyAndOrderFront(nil) }
                else { reference.tabGroup?.selectedWindow = window }
            }
        case "close":
            if let window = windows.removeValue(forKey: key) {
                window.sheetParent?.endSheet(window)
                if command["retain"] as? Bool == true { retainedClosedWindows.append(window) }
                window.close()
            }
        case "minimize": windows[key]?.miniaturize(nil)
        case "restore": windows[key]?.deminiaturize(nil)
        case "hide": NSApp.hide(nil)
        case "show": NSApp.unhide(nil)
        case "yieldActivation":
            // Every fixture shares one bundle ID; yield to the intended process.
            guard let pid = command["pid"] as? Int32, FixtureProbe.isFixture(pid),
                  let target = NSRunningApplication(processIdentifier:pid) else { return ["error":"activation yields accept fixture processes only"] }
            NSApp.yieldActivation(to:target)
        case "fixtureReady":
            var reply = snapshot
            if let pid = command["pid"] as? Int32, FixtureProbe.isFixture(pid) {
                reply["ready"] = FixtureProbe.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) != nil
            } else { reply["ready"] = false }
            return reply
        case "activate":
            if let sourcePID = FixtureProbe.frontmostPID(), FixtureProbe.isFixture(sourcePID),
               let source = NSRunningApplication(processIdentifier:sourcePID) {
                _ = NSRunningApplication.current.activate(from:source,options:[])
            } else {
                // Initial activation has no fixture handoff source.
                NSApp.activate(ignoringOtherApps:true)
            }
            if let window = windows[key] { window.makeKeyAndOrderFront(nil) }
        case "activateFixture":
            guard let pid = command["pid"] as? Int32,
                  FixtureProbe.isFixture(pid) else {
                return ["error": "activation accepts fixture processes only"]
            }
            let application = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let id = command["id"] as? UInt32 {
                for window in FixtureProbe.value(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                    var found: UInt32 = 0
                    _ = fixtureWindowID(window, &found)
                    if found == id {
                        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    }
                }
            }
        case "move":
            if let frame = command["frame"] as? [Double], frame.count == 4 {
                let height = NSScreen.screens.first?.frame.height ?? 0
                windows[key]?.setFrame(NSRect(x: frame[0], y: height - frame[1] - frame[3], width: frame[2], height: frame[3]), display: true)
            }
        case "limitWidth":
            if let window = windows[key], let width = command["width"] as? Double {
                let chrome = window.frame.width - window.contentRect(forFrameRect: window.frame).width
                window.contentMaxSize = NSSize(width:width-chrome,height:10000)
            }
        case "limitHeight":
            if let window = windows[key], let height = command["height"] as? Double {
                let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
                window.contentMaxSize = NSSize(width: 10000, height: height - chrome)
            }
        case "limits":
            guard let window = windows[key], let minimum = command["minimum"] as? [Double], minimum.count == 2 else {
                return ["error": "minimum size requires an existing fixture window and two numbers"]
            }
            window.contentMinSize = NSSize(width: minimum[0], height: minimum[1])
        case "fullscreen": windows[key]?.toggleFullScreen(nil)
        case "observe":
            guard let pids = command["pids"] as? [Int32], pids.allSatisfy(FixtureProbe.isFixture) else {
                return ["error": "the observer accepts fixture processes only"]
            }
            let focusedOnly = command["focusedOnly"] as? Bool == true
            let expectedPID = command["expectedPID"] as? Int32
            if let expectedPID, !focusedOnly || !pids.contains(expectedPID) {
                return ["error": "the focused target must belong to the observed fixture processes"]
            }
            var reply = snapshot
            reply["observation"] = observe(pids, inspectFinder: command["finder"] as? Bool == true,
                                           focusedOnly: focusedOnly, expectedPID: expectedPID)
            return reply
        case "menu":
            guard let pid = command["pid"] as? Int32,
                  FixtureProbe.hasSignature(pid, identifier: "com.taecontrol.tessel.dev") else {
                return ["error": "menu inspection accepts the development app only"]
            }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            guard let bar = FixtureProbe.value(application, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
                  let item = (FixtureProbe.value(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first else {
                return ["error": "development status item unavailable"]
            }
            let open = command["open"] as? Bool ?? false
            if open && command["press"] as? Bool != false { _ = AXUIElementPerformAction(item, kAXPressAction as CFString) }
            let expected = command["expected"] as? String ?? ""
            var found = false
            var inspected = 0
            func inspect(_ element: AXUIElement, depth: Int) {
                guard depth < 8, inspected < 100 else { return }
                inspected += 1
                // Only menu-item titles are read. Window titles are never queried.
                let role = FixtureProbe.value(element, kAXRoleAttribute) as? String
                let attribute = role == kAXMenuItemRole ? kAXTitleAttribute : kAXDescriptionAttribute
                if (open ? role == kAXMenuItemRole : role == kAXMenuBarItemRole),
                   let text = FixtureProbe.value(element, attribute) as? String,
                   (command["suffix"] as? Bool == true ? text.hasSuffix(expected) : text.contains(expected)) { found = true }
                for child in FixtureProbe.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { inspect(child, depth: depth + 1) }
            }
            inspect(item, depth: 0)
            let menus = (FixtureProbe.value(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .filter { FixtureProbe.value($0, kAXRoleAttribute) as? String == kAXMenuRole }
            if open && command["keepOpen"] as? Bool != true {
                for child in menus {
                    _ = AXUIElementPerformAction(child, kAXCancelAction as CFString)
                }
            }
            var reply = snapshot
            reply["menuContains"] = found
            return reply
        case "hotkey":
            // A missed hotkey must never type in a real user's app, even on failure.
            guard let front = FixtureProbe.frontmostPID(), FixtureProbe.isFixture(front),
                  let window = FixtureProbe.value(AXUIElementCreateApplication(front), kAXFocusedWindowAttribute),
                  CFGetTypeID(window) == AXUIElementGetTypeID() else {
                return ["error": "refusing synthetic hotkey: a fixture window must be frontmost"]
            }
            var id: CGWindowID = 0
            _ = fixtureWindowID(window as! AXUIElement, &id)
            let onscreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard onscreen.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
                  let code = command["code"] as? Int, FixtureProbe.frontmostPID() == front else {
                return ["error": "refusing synthetic hotkey: the fixture window must be on screen"]
            }
            let names = command["modifiers"] as? [String] ?? (["alt"] + (command["shift"] as? Bool == true ? ["shift"] : []))
            let modifiers: [String: CGEventFlags] = ["alt": .maskAlternate, "shift": .maskShift, "ctrl": .maskControl, "cmd": .maskCommand]
            guard names.allSatisfy({ modifiers[$0] != nil }) else { return ["error": "invalid fixture key modifiers"] }
            let flags = names.reduce(CGEventFlags()) { $0.union(modifiers[$1]!) }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
            let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)!
            down.flags = flags
            up.flags = flags
            let posted = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            var reply = snapshot
            reply["postedAt"] = posted
            return reply
        case "hang":
            // A genuine resize notification is delivered just before AppKit blocks.
            // This makes tessel attempt a refresh against the hung application.
            windows["window"]?.setContentSize(NSSize(width: 500, height: 320))
        case "replaceProcess":
            // Keep the PID alive with different code to check the observer's
            // signature boundary. The reply is sent before this queued exec.
            guard windows.isEmpty else { return ["error": "process replacement requires an empty fixture"] }
            DispatchQueue.main.async {
                var arguments = [strdup("/bin/sleep"), strdup("2"), nil]
                arguments.withUnsafeMutableBufferPointer { _ = execv("/bin/sleep", $0.baseAddress!) }
                _exit(127)
            }
        default: return ["error": "unknown fixture command"]
        }
        return snapshot
    }

    var snapshot: [String: Any] {
        ["pid": getpid(), "active": NSApp.isActive, "keyCount": keyCount, "transitionCount": transitions.count, "windows": windows.mapValues { $0.windowNumber },
         "clicks": Dictionary(uniqueKeysWithValues: clicks.map { (String($0.key), $0.value) }),
         "keyWindow": NSApp.keyWindow.map { $0.windowNumber } as Any? ?? NSNull(),
         "mainWindow": NSApp.mainWindow.map { $0.windowNumber } as Any? ?? NSNull(),
         "minimizeEvents": minimizeRecorders.mapValues(\.events),
         "miniaturized": windows.mapValues(\.isMiniaturized),
         "videosReady": windows.mapValues { ($0.contentView as? FixtureVideo)?.video.isReadyForDisplay ?? false },
         "axWindowOrder": (NSApp.accessibilityWindows() ?? []).compactMap { ($0 as? NSWindow).map { $0.windowNumber } },
         "frames": windows.mapValues { window in
             let frame = window.frame
             return [frame.minX, frame.minY, frame.width, frame.height]
         },
         "nativeTabs": windows.mapValues { $0.tabGroup?.windows.count ?? 1 },
         "closable": windows.mapValues { $0.styleMask.contains(.closable) },
         "contentPages": windows.mapValues { window in
             if let controller = window.contentViewController as? NSTabViewController { return controller.tabViewItems.count }
             return window.contentView?.subviews.compactMap { ($0 as? NSTabView)?.numberOfTabViewItems }.max() ?? 0
         }]
    }

    @discardableResult
    func makeWindow(key: String, kind: String, title: String? = nil, show: Bool = true, closable: Bool = true, color: Int? = nil) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if !closable { style.remove(.closable) }
        if kind != "fixed" { style.insert(.resizable) }
        let rect = NSRect(x: 100, y: 120, width: 480, height: 300)
        let window: NSWindow
        if kind == "panel" || kind == "normalPanel" {
            window = NSPanel(contentRect: rect, styleMask: style.union(.utilityWindow), backing: .buffered, defer: false)
            (window as? NSPanel)?.isFloatingPanel = true
            (window as? NSPanel)?.hidesOnDeactivate = false
            if kind == "normalPanel" { window.level = .normal }
        } else if kind == "dialog" {
            window = DialogWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        } else if kind == "newTabButton" {
            window = NewTabWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        } else if kind == "unconstrained" {
            window = UnconstrainedWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        } else {
            window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.tabbingMode = .disallowed
        window.title = title ?? "Fixture " + key
        if kind == "maxWidth" { window.contentMaxSize = NSSize(width: 480, height: 10_000) }
        if kind == "noFullscreen" { window.collectionBehavior = .fullScreenNone }
        let label = NSTextField(labelWithString: "Generic fixture window")
        label.frame = NSRect(x: 30, y: 100, width: 350, height: 30)
        window.contentView?.addSubview(label)
        if kind == "video" { window.contentView = FixtureVideo(frame: window.contentView!.bounds) }
        if kind == "heavyText" {
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width,.height]
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.string = (1...4_000).map { "Invented fixture paragraph \($0): window movement redraws this text." }.joined(separator: "\n")
            text.autoresizingMask = [.width]
            scroll.documentView = text
            window.contentView = scroll
        }
        if kind == "web" {
            let web = WKWebView(frame: window.contentView!.bounds)
            web.autoresizingMask = [.width,.height]
            web.loadHTMLString("<html><body style='font:16px system-ui'>" + (1...300).map { "<p>Invented fixture row \($0)</p>" }.joined() + "</body></html>",baseURL:nil)
            window.contentView = web
        }
        if ["contentTabs", "emptyContentTabs", "manyContentTabs"].contains(kind) {
            let tabs = NSTabView(frame: NSRect(x: 20, y: 20, width: 420, height: 220))
            for index in 1...(kind == "manyContentTabs" ? 5 : 3) {
                let item = NSTabViewItem(identifier: index)
                item.label = "Fixture page " + String(index)
                if kind != "emptyContentTabs" {
                    let page = NSView(frame: tabs.bounds)
                    let content = NSTextField(labelWithString: "Invented page content")
                    content.frame = NSRect(x: 20, y: 30, width: 250, height: 30)
                    page.addSubview(content)
                    item.view = page
                }
                tabs.addTabViewItem(item)
            }
            window.contentView?.addSubview(tabs)
        }
        if kind == "segmentedTabs" {
            let controller = NSTabViewController()
            controller.tabStyle = .segmentedControlOnTop
            for index in 1...3 {
                let page = NSViewController()
                page.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
                page.view.addSubview(NSTextField(labelWithString: "Invented segmented page content"))
                let item = NSTabViewItem(viewController: page)
                item.label = "Fixture section " + String(index)
                controller.addTabViewItem(item)
            }
            window.contentViewController = controller
        }
        windows[key] = window
        if kind == "minimize" { minimizeRecorders[key] = MinimizeRecorder(window) }
        if let color, FixtureInstantRecording.colors.indices.contains(color) {
            paint(window, color: color)
        }
        if show { window.makeKeyAndOrderFront(nil) }
        return window
    }

    /// Uniform content makes owner IDs an exact pixel-content oracle inside
    /// the excluded 12-point border, including the otherwise varying titlebar.
    private func paint(_ window: NSWindow, color: Int) {
        let rgb = FixtureInstantRecording.colors[color]
        let fill = NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.backgroundColor = fill
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = fill.cgColor
    }

    /// An independent AX/CG client; all returned window data belongs to fixtures.
    func observe(_ pids: [pid_t], inspectFinder: Bool, focusedOnly: Bool, expectedPID: pid_t? = nil) -> [String: Any] {
        // Timed checks poll focused-only observations against a deadline, so a
        // busy app is asked again rather than allowed to consume that deadline.
        // Setup and one-shot reads wait for a briefly busy app to answer.
        let timeout: Float = focusedOnly ? FixtureProbe.focusedObservationTimeout : FixtureProbe.observationTimeout
        var front = FixtureProbe.frontmostPID(timeout: timeout)
        var listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var visible = Set(listed.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        var visibleIDs = listed.compactMap { item -> UInt32? in
            guard let owner = item[kCGWindowOwnerPID as String] as? NSNumber, pids.contains(owner.int32Value) else { return nil }
            return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        var order = Dictionary(uniqueKeysWithValues: listed.enumerated().compactMap { index, item -> (UInt32, Int)? in
            (item[kCGWindowNumber as String] as? NSNumber).map { ($0.uint32Value, index) }
        })
        var result: [[String: Any]] = []
        var owners: [UInt32: pid_t] = [:], mains: [UInt32: Bool] = [:]
        for pid in pids {
            // A command can change frontmost apps after that early snapshot.
            // Never block a destination check on the now-hidden source's AX.
            if focusedOnly && (front != pid || expectedPID != nil && expectedPID != pid) { continue }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, timeout)
            var focusedID: UInt32 = 0
            var focusedElement: AXUIElement?
            if let focused = FixtureProbe.value(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(element, timeout)
                focusedElement = element
                _ = fixtureWindowID(element, &focusedID)
            }
            let focusedSheet = focusedElement.map { FixtureProbe.value($0, kAXRoleAttribute) as? String == kAXSheetRole } ?? false
            func describe(_ window: AXUIElement, parent: UInt32? = nil, knownID: UInt32? = nil) {
                AXUIElementSetMessagingTimeout(window, timeout)
                var id: CGWindowID = knownID ?? 0
                if knownID == nil { _ = fixtureWindowID(window, &id) }
                guard id != 0 else { return }
                // Read the same facts in one AX message during timed switches.
                let includeChildren = !focusedOnly || focusedSheet
                let attributes = [kAXPositionAttribute, kAXSizeAttribute, kAXMainAttribute, "AXFullScreen"]
                    + (includeChildren ? [kAXChildrenAttribute] : [])
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(window, attributes as CFArray, [], &values) == .success,
                      let fields = values as? [AnyObject], fields.count == attributes.count else { return }
                var position = CGPoint.zero, size = CGSize.zero
                if CFGetTypeID(fields[0]) == AXValueGetTypeID() {
                    _ = AXValueGetValue(fields[0] as! AXValue, .cgPoint, &position)
                }
                if CFGetTypeID(fields[1]) == AXValueGetTypeID() {
                    _ = AXValueGetValue(fields[1] as! AXValue, .cgSize, &size)
                }
                let main = fields[2] as? Bool ?? false
                owners[id] = pid; mains[id] = main
                result.append(["id": id, "frame": [position.x, position.y, size.width, size.height],
                               "visible": visible.contains(id), "main": main && front == pid,
                               "focused": focusedID == id && front == pid,
                               "parent": parent.map { $0 as Any } ?? NSNull(),
                               "order": order[id] ?? Int.max,
                               "nativeFullscreen": fields[3] as? Bool ?? false])
                if includeChildren {
                    for child in fields[4] as? [AXUIElement] ?? []
                        where FixtureProbe.value(child, kAXRoleAttribute) as? String == kAXSheetRole { describe(child, parent: id) }
                }
            }
            if !focusedOnly || focusedSheet {
                for window in FixtureProbe.value(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] { describe(window) }
            }
            // A Space move can temporarily omit even the focused AX window.
            // Read its live handle directly, including a focused sheet's parent.
            if let focusedElement, focusedID != 0, !result.contains(where: { $0["id"] as? UInt32 == focusedID }) {
                var parentID: UInt32?
                if focusedSheet, let parent = FixtureProbe.value(focusedElement, kAXParentAttribute),
                   CFGetTypeID(parent) == AXUIElementGetTypeID() {
                    var id: UInt32 = 0
                    AXUIElementSetMessagingTimeout(parent as! AXUIElement, timeout)
                    _ = fixtureWindowID(parent as! AXUIElement, &id)
                    if id != 0 {
                        parentID = id
                        if !result.contains(where: { $0["id"] as? UInt32 == id }) { describe(parent as! AXUIElement, knownID: id) }
                    }
                }
                if !result.contains(where: { $0["id"] as? UInt32 == focusedID }) { describe(focusedElement, parent: parentID, knownID: focusedID) }
            }
        }
        let screen = NSScreen.screens.first!
        let area = screen.visibleFrame
        var desktop = false
        var finderHasNoOrdinaryWindows: Bool?
        if inspectFinder, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let application = AXUIElementCreateApplication(finder.processIdentifier)
            AXUIElementSetMessagingTimeout(application, timeout)
            if let windows = FixtureProbe.value(application, kAXWindowsAttribute) as? [AXUIElement] {
                finderHasNoOrdinaryWindows = true
                for window in windows {
                    guard let role = FixtureProbe.value(window, kAXRoleAttribute) as? String else {
                        finderHasNoOrdinaryWindows = nil
                        break
                    }
                    if role != kAXScrollAreaRole {
                        finderHasNoOrdinaryWindows = false
                        break
                    }
                }
            }
            if finderHasNoOrdinaryWindows == true, front == finder.processIdentifier,
               FixtureProbe.hasSignature(finder.processIdentifier, identifier: "com.apple.finder"),
               let focused = FixtureProbe.value(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                desktop = FixtureProbe.value(focused as! AXUIElement, kAXSubroleAttribute) == nil
            }
        }
        if !focusedOnly {
            // A multi-window AX read spans several display frames. Pair its
            // geometry with live focus and CG membership taken afterwards,
            // just like the motion probe, rather than an earlier preparation
            // snapshot which would force another full observation.
            front = FixtureProbe.frontmostPID(timeout: timeout)
            var focusedID: UInt32 = 0
            if let front, pids.contains(front), FixtureProbe.isFixture(front) {
                let application = AXUIElementCreateApplication(front)
                AXUIElementSetMessagingTimeout(application, timeout)
                if let focused = FixtureProbe.value(application, kAXFocusedWindowAttribute),
                   CFGetTypeID(focused) == AXUIElementGetTypeID() {
                    _ = fixtureWindowID(focused as! AXUIElement, &focusedID)
                }
            }
            listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            visible = Set(listed.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            visibleIDs = listed.compactMap { item -> UInt32? in
                guard let owner = item[kCGWindowOwnerPID as String] as? NSNumber, pids.contains(owner.int32Value) else { return nil }
                return (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
            order = Dictionary(uniqueKeysWithValues: listed.enumerated().compactMap { index, item -> (UInt32, Int)? in
                (item[kCGWindowNumber as String] as? NSNumber).map { ($0.uint32Value, index) }
            })
            for index in result.indices {
                guard let id = result[index]["id"] as? UInt32 else { continue }
                result[index]["visible"] = visible.contains(id)
                result[index]["order"] = order[id] ?? Int.max
                result[index]["main"] = mains[id] == true && owners[id] == front
                result[index]["focused"] = id == focusedID && owners[id] == front
            }
        }
        let frontmostFixture = front.map { pids.contains($0) } ?? false
        // Cached activation metadata serves setup, outside the switch deadline.
        let workspaceFront = focusedOnly ? nil : NSWorkspace.shared.frontmostApplication?.processIdentifier
        return ["windows": result, "visibleIDs": visibleIDs, "frontmostFixture": frontmostFixture,
                "frontmostFixturePID": frontmostFixture ? front! : 0,
                "activeFixturePID": workspaceFront.flatMap { pids.contains($0) ? $0 : nil } ?? 0,
                "finderDesktop": desktop, "finderHasNoOrdinaryWindows": finderHasNoOrdinaryWindows.map { $0 as Any } ?? NSNull(),
                "area": [area.minX, screen.frame.height - area.maxY, area.width, area.height],
                // The same raw monotonic clock as the harness; every read above is complete.
                "sampledAt": Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9]
    }
}

private struct CaptureWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CaptureView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class CaptureView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { Fixture.current?.windows["window"] = window }
        }
    }
}

private struct FixedWidthFixture: SwiftUI.App {
    @NSApplicationDelegateAdaptor(Fixture.self) var delegate
    var body: some Scene {
        Window("Generic fixed-width fixture", id: "fixed") {
            Text("Generic fixture window").frame(width: 480).frame(minHeight: 300, maxHeight: .infinity)
                .background(CaptureWindow())
        }.windowResizability(.contentSize).defaultLaunchBehavior(.presented)
    }
}

/// Signature validation for the code objects one thread owns. The main actor
/// and the motion sampler thread each keep their own cache.
struct FixtureCodes {
    static let fixture = "com.taecontrol.tessel.fixture"
    private var processCodes: [pid_t: SecCode] = [:]

    /// LaunchServices can temporarily omit live processes during activation.
    /// Validate the running code's signature instead of trusting that cache.
    mutating func hasSignature(_ pid: pid_t, identifier: String) -> Bool {
        guard let code = runningCode(pid) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(("identifier \"" + identifier + "\"") as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        // Revalidate every operation. Only the audit-bound code object is
        // retained; its token rejects exec and PID reuse through the kernel.
        let valid = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        if !valid { processCodes.removeValue(forKey: pid) }
        return valid
    }

    private mutating func runningCode(_ pid: pid_t) -> SecCode? {
        if let code = processCodes[pid] { return code }
        if let code = Self.auditBoundCode(pid) {
            processCodes = processCodes.filter { kill($0.key, 0) == 0 }
            if processCodes.count >= 32 { processCodes.removeAll() }
            processCodes[pid] = code
            return code
        }
        // Preserve fresh stateless validation if the process denies a task name.
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func auditBoundCode(_ pid: pid_t) -> SecCode? {
        var task: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS, task != 0 else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var token = audit_token_t()
        let words = MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(words)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: words) {
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == mach_msg_type_number_t(words) else { return nil }
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit as CFData] as CFDictionary, [], &code) == errSecSuccess else { return nil }
        return code
    }
}

// The independent oracle reads only this repository's fixture. It never reads titles.
enum FixtureProbe {
    @MainActor private static var codes = FixtureCodes()

    @MainActor static func hasSignature(_ pid: pid_t, identifier: String) -> Bool {
        codes.hasSignature(pid, identifier: identifier)
    }

    @MainActor static func isFixture(_ pid: pid_t) -> Bool { hasSignature(pid, identifier: FixtureCodes.fixture) }

    /// A timed-out AX read means the app did not answer, not that a window is
    /// absent or unfocused. The system-wide focused-application read is also
    /// answered by the frontmost app. A briefly busy main thread can miss
    /// 20 ms; a stopped app still costs one bounded wait per read.
    static let observationTimeout: Float = 0.1
    /// Focused-only observations and the motion sampler's focus read use a
    /// shorter bound, so a busy app cannot stall the next sample.
    static let focusedObservationTimeout: Float = 0.02

    static func frontmostPID(timeout: Float = observationTimeout) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard let application = value(system, kAXFocusedApplicationAttribute), CFGetTypeID(application) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application as! AXUIElement, &pid) == .success else { return nil }
        return pid
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func tabGroups(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 5 else { return [] }
        if value(element, kAXRoleAttribute) as? String == kAXTabGroupRole {
            return [element]
        }
        return (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(40).flatMap { tabGroups($0, depth: depth + 1) }
    }

    @MainActor static func run(pid: pid_t, resizeID: Int?) {
        guard isFixture(pid) else { exit(3) }
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
            let groups = tabGroups(window)
            let tabItems = groups.map { value($0, kAXTabsAttribute) as? [AXUIElement] ?? [] }
            let extraButtons = groups.flatMap { value($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
                .filter { value($0, kAXRoleAttribute) as? String == kAXButtonRole }.count
            let perTabButtons = tabItems.flatMap { $0 }.flatMap { value($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
                .filter { value($0, kAXRoleAttribute) as? String == kAXButtonRole }.count
            var result: [String: Any] = ["id": id, "subrole": value(window, kAXSubroleAttribute) as? String ?? "missing",
                "role": value(window, kAXRoleAttribute) as? String ?? "missing", "sizeSettable": settable.boolValue,
                "fullscreen": fullscreen, "tabs": tabItems.map(\.count).max() ?? 0,
                "extraTabButtons": extraButtons, "perTabButtons": perTabButtons]
            if resizeID == Int(id) {
                var size = CGSize(width: 650, height: 400)
                let axSize = AXValueCreate(.cgSize, &size)!
                result["resizeError"] = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize).rawValue
                if let returned = value(window, kAXSizeAttribute), CFGetTypeID(returned) == AXValueGetTypeID() {
                    var accepted = CGSize.zero
                    _ = AXValueGetValue(returned as! AXValue, .cgSize, &accepted)
                    result["acceptedSize"] = [accepted.width, accepted.height]
                }
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
        if args.contains("--swiftui") { FixedWidthFixture.main(); return }
        if args.dropFirst().first == "--check-session" {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
            exit(CGDisplayIsAsleep(CGMainDisplayID()) == 0 && !locked ? 0 : 5)
        }
        if args.count > 2, args[1] == "--probe", let pid = Int32(args[2]) {
            FixtureProbe.run(pid: pid, resizeID: args.count > 3 ? Int(args[3]) : nil)
            return
        }
        let app = FixtureApplication.shared
        if args.contains("--prohibited"), !app.setActivationPolicy(.prohibited) { exit(6) }
        let delegate = Fixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
