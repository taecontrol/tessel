import AppKit

// SPIKE (deterministic policy). Not production code; see README.md.
// E2 "the focused window keeps its focus" when rails is enabled while the
// user's latest native selection has not yet reached tessel.

@main struct Spike {
    enum Step: String, CaseIterable { case userSelects = "U", read = "R", deliver = "D", enable = "E" }
    enum Writes: String, CaseIterable { case eager, writesFirst, readsFirst }

    @MainActor static func run(_ steps: [Step], writes: Writes) -> String? {
        let world = World()
        World.current = world
        // One app with three windows; the last opened, 3, is key.
        for (index, id) in [UInt32(1), 2, 3].enumerated() {
            world.windows[id] = .init(pid: 100, frame: CGRect(x: Double(index) * 40, y: 41, width: 451, height: 400))
        }
        world.zOrder = [3, 2, 1]
        world.keyWindow[100] = 3
        world.front = 100
        world.workspaces = Workspaces(store: world.store, trusted: true, configuration: Configuration(),
                                      simulateMissing: false, simulateFailedHide: false, system: world)
        world.workspaces.catalog = world.catalog
        world.read(100, change: .snapshot); world.deliver()

        for step in steps {
            switch step {
            case .userSelects: world.focus(1)
            case .read:
                let (pid, change) = world.notifications.removeFirst()
                world.read(pid, change: change)
            case .deliver: world.deliver()
            case .enable: world.workspaces.configure(Configuration(experiments: ["rails": true]))
            }
            if writes == .eager { while !world.writes.isEmpty { world.executeWrite() } }
        }
        world.settle(writesFirst: writes != .readsFirst)

        var failures: [String] = []
        if world.keyWindow[100] != 1 { failures.append("key window is \(world.keyWindow[100].map(String.init) ?? "none"), not 1") }
        if let w = world.windows[1], w.hidden || w.frame.minX < 0 || w.frame.maxX > 1024 {
            failures.append("window 1 is not fully shown: \(w.frame) hidden \(w.hidden)")
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    /// Every order of the four steps in which the read follows the selection
    /// and the delivery follows the read.
    static var orders: [[Step]] {
        func permutations(_ items: [Step]) -> [[Step]] {
            items.count <= 1 ? [items] : items.indices.flatMap { i in
                var rest = items; let head = rest.remove(at: i)
                return permutations(rest).map { [head] + $0 }
            }
        }
        return permutations(Step.allCases).filter { order in
            let index = { (step: Step) in order.firstIndex(of: step)! }
            return index(.userSelects) < index(.read) && index(.read) < index(.deliver)
        }
    }

    @MainActor static func main() {
        var report: [String] = []
        for order in orders {
            for writes in Writes.allCases {
                let name = order.map(\.rawValue).joined() + " " + writes.rawValue
                report.append("\(name): " + (run(order, writes: writes).map { "FAIL \($0)" } ?? "pass"))
            }
        }
        print(report.joined(separator: "\n"))
        let repetitions = Int(CommandLine.arguments.dropFirst().first ?? "0") ?? 0
        guard repetitions > 0 else { return }
        let start = Date()
        var identical = 0
        for _ in 0..<repetitions {
            var again: [String] = []
            for order in orders {
                for writes in Writes.allCases {
                    let name = order.map(\.rawValue).joined() + " " + writes.rawValue
                    again.append("\(name): " + (run(order, writes: writes).map { "FAIL \($0)" } ?? "pass"))
                }
            }
            if again == report { identical += 1 }
        }
        let schedules = repetitions * orders.count * Writes.allCases.count
        print("repetitions \(repetitions): \(identical) identical; \(schedules) schedules in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    }
}
