import AppKit
import ApplicationServices

@MainActor
final class MinimizeRecorder: NSObject {
    private(set) var events: [[String: Any]] = []
    private weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
        super.init()
        for name in [NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: window)
        }
    }

    @objc private func changed(_ notification: Notification) {
        guard let window else { return }
        events.append(["name": notification.name.rawValue, "minimized": window.isMiniaturized,
                       "key": window.isKeyWindow, "main": window.isMainWindow, "active": NSApp.isActive,
                       "sampledAt": Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9])
    }
}

extension FixtureContracts {
    func scenario(_ operation: String, _ command: [String: Any], application: AXUIElement, pid: pid_t) throws -> [String: Any] {
        switch operation {
        case "activateAX":
            let result = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            let frontmost = read(application, kAXFrontmostAttribute)
            return ["result": result.rawValue, "readError": frontmost.error.rawValue,
                    "frontmost": frontmost.value as? Bool as Any? ?? NSNull()]
        case "publication":
            let ids = command["ids"] as? [UInt32] ?? []
            var reply = snapshot(application, pid: pid)
            reply["retainedWindows"] = try ids.map { describe(try retained(["id": $0], pid: pid)) }
            return reply
        case "chrome":
            let window = try retained(command, pid: pid)
            var inspected = 0
            func groups(_ node: AXUIElement, depth: Int) -> [[String: Any]] {
                guard depth < 8, inspected < 100 else { return [] }
                inspected += 1
                let childReply = read(node, kAXChildrenAttribute), tabReply = read(node, kAXTabsAttribute), contentReply = read(node, kAXContentsAttribute)
                let children = childReply.value as? [AXUIElement] ?? []
                let tabs = tabReply.value as? [AXUIElement] ?? []
                let contents = contentReply.value as? [AXUIElement] ?? []
                func roles(_ elements: [AXUIElement]) -> [String] {
                    elements.map { read($0, kAXRoleAttribute).value as? String ?? "unavailable" }
                }
                var result: [[String: Any]] = []
                if !tabs.isEmpty || roles(children).contains(kAXRadioButtonRole) {
                    let tabChildren = tabs.map { read($0, kAXChildrenAttribute) }
                    result.append(["role": read(node, kAXRoleAttribute).value as? String as Any? ?? NSNull(),
                                   "tabs": roles(tabs), "contents": roles(contents), "children": roles(children),
                                   "tabsError": tabReply.error.rawValue, "tabsIsArray": tabReply.value is [AXUIElement],
                                   "contentsError": contentReply.error.rawValue, "contentsIsArray": contentReply.value is [AXUIElement],
                                   "childrenError": childReply.error.rawValue, "childrenIsArray": childReply.value is [AXUIElement],
                                   "tabChildren": tabChildren.map { roles($0.value as? [AXUIElement] ?? []) },
                                   "tabChildrenErrors": tabChildren.map { $0.error.rawValue }, "tabChildrenAreArrays": tabChildren.map { $0.value is [AXUIElement] },
                                   "tabsInContents": !tabs.isEmpty && tabs.allSatisfy { tab in contents.contains { CFEqual(tab, $0) } }])
                }
                return result + children.flatMap { groups($0, depth: depth + 1) }
            }
            return ["chrome": groups(window, depth: 0)]
        default: throw FixtureContractError("unknown native scenario operation")
        }
    }
}
