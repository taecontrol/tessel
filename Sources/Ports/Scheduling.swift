import Foundation

package protocol ScheduledWork: Sendable { func cancel() }

package protocol SerialLane: Sendable {
    func async(_ work: @escaping @Sendable () -> Void)
    @discardableResult func after(milliseconds: Int, _ work: @escaping @Sendable () -> Void) -> any ScheduledWork
    func sync(_ work: @Sendable () -> Void)
}

package protocol MainLane: Sendable {
    func async(_ work: @escaping @MainActor @Sendable () -> Void)
    @discardableResult func after(milliseconds: Int, _ work: @escaping @MainActor @Sendable () -> Void) -> any ScheduledWork
}

package protocol PolicyLock: Sendable {
    func lock()
    func unlock()
}

extension PolicyLock {
    package func withLock<Value>(_ work: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try work()
    }
}

package protocol SchedulingPort: Sendable {
    var main: any MainLane { get }
    func serialLane(label: String) -> any SerialLane
    func backgroundAsync(_ work: @escaping @Sendable () -> Void)
    func makeLock() -> any PolicyLock
}
