import CoreGraphics

/// A burst excuses only its own listed intermediate geometry and affected points.
/// Its start frame is never excused, including while an app commit is pending. Other
/// windows and uncovered parts of the desktop remain observable throughout it.
/// The oracle judges tessel's own ordering (#33 E18). A window an app removes
/// leaves the start view; what its removal exposes is checked against the
/// same change at rest.
struct InstantHandoffOracle {
    let area: CGRect
    let ids: Set<UInt32>
    let before: [UInt32: CGRect]
    let startOrder: [UInt32]
    let final: [UInt32: CGRect]
    let endOrder: [UInt32]

    func violations(frames: [UInt32: CGRect], order: [UInt32], inProgress: Set<UInt32>, showing: Set<UInt32> = []) -> [String] {
        var failures: [String] = []
        for id in ids.sorted() {
            guard let current = frames[id] else { continue } // Closet writes are invisible.
            if showing.contains(id), current != final[id] {
                failures.append("returning window \(id) is shown before its final frame")
            }
            if current != before[id], current != final[id], !inProgress.contains(id) {
                failures.append("window \(id) has intermediate geometry outside its own burst")
            }
        }
        let allFrames = Array(before.values) + Array(final.values) + Array(frames.values)
        let xs = Set(([area.minX, area.maxX] + allFrames.flatMap { [$0.minX, $0.maxX] }).map { min(area.maxX, max(area.minX, $0)) }).sorted()
        let ys = Set(([area.minY, area.maxY] + allFrames.flatMap { [$0.minY, $0.maxY] }).map { min(area.maxY, max(area.minY, $0)) }).sorted()
        func owner(_ frames: [UInt32: CGRect], _ order: [UInt32], at point: CGPoint) -> UInt32? {
            order.first { ids.contains($0) && frames[$0]?.contains(point) == true }
        }
        for (x0, x1) in zip(xs, xs.dropFirst()) where x1 > x0 {
            for (y0, y1) in zip(ys, ys.dropFirst()) where y1 > y0 {
                let point = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                let affected = inProgress.contains { id in
                    frames[id] != nil && frames[id] != before[id] && frames[id] != final[id]
                        && (before[id]?.contains(point) == true || final[id]?.contains(point) == true || frames[id]?.contains(point) == true)
                }
                if affected { continue }
                let old = owner(before, startOrder, at: point), new = owner(final, endOrder, at: point)
                let current = owner(frames, order, at: point)
                if current != nil, current != old, current != new {
                    failures.append("\(point) shows \(String(describing: current)), expected old \(String(describing: old)) or final \(String(describing: new))")
                }
                if old != nil, new != nil, current == nil {
                    failures.append("shared tile coverage exposes desktop at \(point)")
                }
            }
        }
        return failures
    }
}
