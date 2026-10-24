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

package struct WindowListing: Sendable, Equatable {
    package let frame: CGRect
    package let onScreen: Bool
    package init(frame: CGRect, onScreen: Bool) { self.frame = frame; self.onScreen = onScreen }
}

@MainActor
package protocol WindowOrderPort {
    func onScreenOrder() -> [UInt32]
    /// CG layers for just these windows, including those outside the active Space.
    nonisolated func windowLevels(_ windows: Set<UInt32>) -> [UInt32: Int]
    /// What WindowServer lists for these windows, wherever they are. A closed window is missing.
    nonisolated func listings(_ windows: Set<UInt32>) -> [UInt32: WindowListing]
}
