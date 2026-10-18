package struct Precedence<Step: Hashable> {
    let first: Step
    let second: Step
    package init(_ first: Step, before second: Step) { self.first = first; self.second = second }
}

package struct OrderedSteps<Step: Hashable> {
    package let steps: [Step]
    package let writes: WriteOrder
}

extension SimulatedMac {
    /// Enumerate every topological order, crossed with every supported write
    /// strategy. FIFO still fixes the order within an application's lane.
    package func orders<Step: Hashable>(of steps: [Step], requiring edges: [Precedence<Step>],
                                       writes: [WriteOrder] = WriteOrder.allCases) -> [OrderedSteps<Step>] {
        precondition(Set(steps).count == steps.count && edges.allSatisfy { steps.contains($0.first) && steps.contains($0.second) })
        func visit(_ prefix: [Step], _ remaining: [Step]) -> [[Step]] {
            if remaining.isEmpty { return [prefix] }
            return remaining.indices.flatMap { index -> [[Step]] in
                let next = remaining[index]
                guard edges.filter({ $0.second == next }).allSatisfy({ prefix.contains($0.first) }) else { return [] }
                var rest = remaining; rest.remove(at: index)
                return visit(prefix + [next], rest)
            }
        }
        return visit([], steps).flatMap { order in writes.map { OrderedSteps(steps: order, writes: $0) } }
    }
}
