import Foundation

struct SystemScheduler: SchedulingPort {
    let main: any MainLane = SystemMainLane()
    func serialLane(label: String) -> any SerialLane { SystemSerialLane(label: label) }
    func backgroundAsync(_ work: @escaping @Sendable () -> Void) { DispatchQueue.global(qos: .userInitiated).async(execute: work) }
    func makeLock() -> any PolicyLock { SystemPolicyLock() }
}

private final class SystemWork: ScheduledWork, @unchecked Sendable {
    let item: DispatchWorkItem
    init(_ work: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: work) }
    func cancel() { item.cancel() }
}

private struct SystemSerialLane: SerialLane {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated, autoreleaseFrequency: .workItem) }
    func async(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
    func after(milliseconds: Int, _ work: @escaping @Sendable () -> Void) -> any ScheduledWork {
        let item = SystemWork(work)
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item.item)
        return item
    }
    func sync(_ work: @Sendable () -> Void) { queue.sync(execute: work) }
}

private struct SystemMainLane: MainLane {
    func async(_ work: @escaping @MainActor @Sendable () -> Void) { DispatchQueue.main.async(execute: work) }
    func after(milliseconds: Int, _ work: @escaping @MainActor @Sendable () -> Void) -> any ScheduledWork {
        let item = SystemWork { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: item.item)
        return item
    }
}

private final class SystemPolicyLock: PolicyLock, @unchecked Sendable {
    private let value = NSLock()
    func lock() { value.lock() }
    func unlock() { value.unlock() }
}
