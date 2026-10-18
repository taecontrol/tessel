import AppKit
import ApplicationServices
import Darwin

/// Retains the same foreign AX handle across a fixture window's close.
@MainActor
final class WindowHandleProbe {
    private var retained: (pid: pid_t, element: AXUIElement)?

    func perform(_ command: [String: Any]) -> [String: Any] {
        if command["action"] as? String == "retainWindowHandle" {
            retained = nil
            guard let pid = command["pid"] as? Int32, FixtureProbe.isFixture(pid),
                  let id = command["id"] as? UInt32 else {
                return ["error": "window handle probes accept fixture windows only"]
            }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, FixtureProbe.observationTimeout)
            for element in FixtureProbe.value(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                var found: UInt32 = 0
                if fixtureWindowID(element, &found) == .success, found == id {
                    AXUIElementSetMessagingTimeout(element, FixtureProbe.observationTimeout)
                    retained = (pid, element)
                    break
                }
            }
        }
        guard let retained, FixtureProbe.isFixture(retained.pid) else {
            return ["error": "no retained fixture window handle"]
        }
        let application = AXUIElementCreateApplication(retained.pid)
        AXUIElementSetMessagingTimeout(application, FixtureProbe.observationTimeout)
        var windows: CFTypeRef?
        let listStatus = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        var id: UInt32 = 0
        let idStatus = fixtureWindowID(retained.element, &id)
        let listed = windows as? [AXUIElement] ?? []
        func status(_ attribute: String) -> Int32 {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(retained.element, attribute as CFString, &value).rawValue
        }
        return ["windowHandle": [
            "idStatus": idStatus.rawValue, "id": id,
            "roleStatus": status(kAXRoleAttribute), "minimizedStatus": status(kAXMinimizedAttribute),
            "positionStatus": status(kAXPositionAttribute), "listStatus": listStatus.rawValue,
            "listed": listed.contains { CFEqual($0, retained.element) }, "listCount": listed.count,
            "sampledAt": Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        ]]
    }
}
