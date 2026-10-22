import Foundation
#if SWIFT_PACKAGE
import Ports
#endif

@MainActor
final class WindowCloset {
    typealias Unavailable = ClosetUnavailable
    private let mechanics: any ClosetPort
    init(mechanics: any ClosetPort) { self.mechanics = mechanics }
    func start() throws { try mechanics.start() }
    func hide(_ windows: [UInt32]) { if !windows.isEmpty { mechanics.hide(windows.sorted()) } }
    func show(_ windows: [UInt32]) { if !windows.isEmpty { mechanics.show(windows.sorted()) } }
    func stop(returning windows: [UInt32]) { mechanics.stop(returning: windows.sorted()) }

    /// Ordinary memberships omit hidden Spaces. Wide memberships distinguish a
    /// surviving closet from an orphan without exposing private Space IDs.
    func recover(_ windows: [UInt32], offscreen: Set<UInt32>) {
        var restore: [UInt32] = []
        for id in windows where offscreen.contains(id) {
            guard mechanics.memberships(id, scope: .ordinary).isEmpty else { continue }
            let wide = mechanics.memberships(id, scope: .all)
            guard !wide.contains(mechanics.activeSpace()), !wide.contains(mechanics.closetSpace) else { continue }
            restore.append(id)
        }
        show(restore)
    }
}
