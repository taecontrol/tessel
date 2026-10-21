import Foundation
import CoreGraphics

/// tessel's own overlay, where captures stand in for real windows while they
/// move. Real windows are placed underneath with ordinary writes, so no app
/// has to keep up with the motion. Nothing is captured or kept at rest.
@MainActor
package protocol MotionStagePort: AnyObject {
    /// Screen Recording is granted. Without it there is no stage.
    var available: Bool { get }
    /// Asks for Screen Recording once; macOS may require a relaunch.
    func requestAccess()
    /// Starts capturing whole windows, wherever they are, including the
    /// closet. With `background`, also captures what lies under the area
    /// without those windows. A window already captured for this stage is not
    /// captured again. Foreground stand-ins stay above all moving tiles.
    func capture(_ windows: Set<UInt32>, background excluding: Set<UInt32>?, foreground: Set<UInt32>)
    /// Shows every captured stand-in at its rect in one frame, once all
    /// requested captures have arrived. False when a capture failed or the
    /// stage was cleared meanwhile.
    func show(_ rects: [UInt32: CGRect], completion: @escaping @MainActor @Sendable (Bool) -> Void)
    /// Moves stand-ins to their rects over `duration`, starting from where
    /// and how fast they are moving on screen. A window without a stand-in
    /// yet starts at its `entering` rect, on the same clock, once its capture
    /// arrives; a stand-in missing from `rects` is removed. `settled` fires
    /// once, when every stand-in is close enough to rest that the real
    /// windows can replace them. A later move cancels it.
    func move(_ rects: [UInt32: CGRect], entering: [UInt32: CGRect], duration: TimeInterval,
              settled: @escaping @MainActor @Sendable () -> Void)
    /// Calls `covered` once WindowServer draws the stand-ins opaque again: a
    /// move may stop the stage fading into the real windows.
    func cover(_ covered: @escaping @MainActor @Sendable () -> Void)
    /// Calls `revealed` once WindowServer shows each window at its frame and
    /// each hidden window off screen. Accessibility accepts a placement
    /// before WindowServer draws it. A later move or a clear cancels it.
    func reveal(_ frames: [UInt32: CGRect], hidden: Set<UInt32>, revealed: @escaping @MainActor @Sendable () -> Void)
    /// Captures a window again once it has redrawn, and crossfades to it.
    func refresh(_ window: UInt32)
    /// Removes every stand-in; the real windows show.
    func clear()
}
