import Foundation
import CoreGraphics

package struct RunningApplication: Sendable {
    package let pid: Int32
    package let bundleID: String?
    package let name: String?
    package let hidden: Bool
    package let terminated: Bool
    package let prohibited: Bool

    package init(pid: Int32, bundleID: String?, name: String?, hidden: Bool, terminated: Bool, prohibited: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
        self.hidden = hidden; self.terminated = terminated; self.prohibited = prohibited
    }
}

package enum ApplicationEvent: Sendable { case launched, activated, hidden, unhidden, terminated }

@MainActor
package protocol ApplicationObservation: AnyObject {}

@MainActor
package protocol ApplicationPort {
    var ownPID: Int32 { get }
    var runningApplications: [RunningApplication] { get }
    var frontmostPID: Int32? { get }
    func application(_ pid: Int32) -> RunningApplication?
    func applications(bundleID: String) -> [RunningApplication]
    func observe(_ receive: @escaping @MainActor (ApplicationEvent, RunningApplication) -> Void) -> any ApplicationObservation
    func activate(_ pid: Int32)
    func isAlive(_ pid: Int32) -> Bool
}

package struct ScreenGeometry: Sendable {
    package let frame: CGRect
    package let visibleFrame: CGRect
    package init(frame: CGRect, visibleFrame: CGRect) { self.frame = frame; self.visibleFrame = visibleFrame }
}

@MainActor
package protocol ScreenPort { var primaryScreen: ScreenGeometry? { get } }

@MainActor
package protocol WindowOrderPort {
    func onScreenOrder() -> [UInt32]
    /// CG window layers, including windows outside the active Space.
    nonisolated func windowLevels() -> [UInt32: Int]
}
