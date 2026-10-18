import Foundation

package struct SpaceToken: Hashable, Sendable {
    private let value: UInt64
    package init(adapterValue: UInt64) { value = adapterValue }
}

package enum SpaceScope: Sendable { case ordinary, all }

package struct ClosetUnavailable: Error {
    package let reason: String
    package init(reason: String) { self.reason = reason }
}

@MainActor
package protocol ClosetPort {
    func start() throws
    func hide(_ windows: [UInt32])
    func show(_ windows: [UInt32])
    func stop(returning windows: [UInt32])
    func memberships(_ window: UInt32, scope: SpaceScope) -> [SpaceToken]
    func activeSpace() -> SpaceToken
    var closetSpace: SpaceToken { get }
}
