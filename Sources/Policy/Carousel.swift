import CoreGraphics
import Foundation

/// A bounded strip per rail. Nominal widths survive stretching and expansion;
/// the presenter supplies accepted sizes without making navigation decisions.
struct Carousel {
    static let presets = [1.0 / 3, 0.5, 2.0 / 3, 1]
    struct Tile {
        var id: UInt32
        var size: CGSize
        var preset: Double? = nil
        var minimum: Double = 1
        var maximum: Double = .infinity
    }
    enum Expansion { case start, end }
    struct Rail {
        let identity: UInt64
        var tiles: [Tile] = []
        var offset: Double = 0
        var focused: UInt32?
        var expanded: Expansion?
        var acceptsInitialExpansion = true
    }
    struct Workspace {
        var rails: [Rail] = []
        var current = 0
    }
    private struct Place {
        let workspace: Int
        let rail: UInt64
        var left: UInt32?
        var tile: Tile
    }
    private var nextIdentity: UInt64 = 0
    private var suspended: [UInt32: Place] = [:]
    var workspaces: [Int: Workspace] = [:]
    var width: Double = 1
    var gap: Double = 10

    init(width: Double = 1, gap: Double = 10) { self.width = width; self.gap = gap }
    func presetWidth(_ preset: Double) -> Double { max(1, preset * (width + gap) - gap) }
    mutating func resizeArea(height: Double) {
        for number in workspaces.keys.sorted() {
            for r in workspaces[number]!.rails.indices {
                for i in workspaces[number]!.rails[r].tiles.indices {
                    workspaces[number]!.rails[r].tiles[i].size.height = height
                }
                var rail = workspaces[number]!.rails[r]
                reveal(&rail)
                workspaces[number]!.rails[r] = rail
            }
        }
    }
    private mutating func makeRail() -> Rail {
        nextIdentity += 1
        return Rail(identity: nextIdentity)
    }
    func location(_ id: UInt32) -> (workspace: Int, rail: Int, slot: Int)? {
        for number in workspaces.keys.sorted() {
            for (r, rail) in workspaces[number]!.rails.enumerated() {
                if let slot = rail.tiles.firstIndex(where: { $0.id == id }) { return (number, r, slot) }
            }
        }
        return nil
    }
    func current(_ workspace: Int) -> Rail? {
        guard let ws = workspaces[workspace], ws.rails.indices.contains(ws.current) else { return nil }
        return ws.rails[ws.current]
    }
    func remembered(_ workspace: Int) -> UInt32? { current(workspace)?.focused }
    func tile(_ id: UInt32) -> Tile? {
        guard let p = location(id) else { return suspended[id]?.tile }
        return workspaces[p.workspace]?.rails[p.rail].tiles[p.slot]
    }
    func size(_ id: UInt32) -> CGSize? { tile(id).map { CGSize(width: nominal($0), height: $0.size.height) } }
    private func nominal(_ tile: Tile) -> Double {
        min(tile.maximum, max(tile.minimum, min(width, tile.preset.map(presetWidth) ?? tile.size.width)))
    }
    private func fits(_ tile: Tile, _ preset: Double) -> Bool {
        let w = presetWidth(preset)
        return w >= tile.minimum - 1 && w <= tile.maximum + 1
    }

    /// Width changes reported by the mouse are exact, not a preset selection.
    mutating func adoptWidth(_ id: UInt32, _ value: Double) {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return }
        let x = geometry(ws.rails[p.rail])[p.slot].minX
        ws.rails[p.rail].tiles[p.slot].preset = nil
        ws.rails[p.rail].tiles[p.slot].size.width = min(width, value)
        ws.rails[p.rail].expanded = nil
        ws.rails[p.rail].acceptsInitialExpansion = false
        anchor(&ws.rails[p.rail], id: id, x: x)
        reveal(&ws.rails[p.rail])
        workspaces[p.workspace] = ws
    }

    /// Learn AX's bounds; a rejected nominal preset advances to the next
    /// candidate inside those bounds, including wrap after a rejected maximum.
    /// Clipped readbacks cannot establish intrinsic width or height bounds.
    mutating func accept(_ id: UInt32, requested: CGSize, accepted: CGSize, learnBounds: Bool = true) {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return }
        var tile = ws.rails[p.rail].tiles[p.slot]
        if learnBounds { tile.size.height = accepted.height }
        if learnBounds && accepted.width > requested.width + 1 { tile.minimum = accepted.width }
        if learnBounds && accepted.width < requested.width - 1 { tile.maximum = accepted.width }
        if let preset = tile.preset, !fits(tile, preset) {
            let candidates = Self.presets.filter { fits(tile, $0) }
            tile.preset = candidates.first { $0 > preset + 1e-6 } ?? candidates.first
            if tile.preset == nil { tile.size.width = accepted.width }
        } else if tile.preset == nil {
            tile.size.width = min(tile.maximum, max(tile.minimum, tile.size.width))
        }
        ws.rails[p.rail].tiles[p.slot] = tile
        if tile.maximum < width - 1 { ws.rails[p.rail].expanded = nil }
        reveal(&ws.rails[p.rail])
        workspaces[p.workspace] = ws
    }
    mutating func select(_ id: UInt32) {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return }
        ws.current = p.rail
        let changed = ws.rails[p.rail].focused != id
        if changed {
            ws.rails[p.rail].expanded = nil
            ws.rails[p.rail].acceptsInitialExpansion = false
        }
        ws.rails[p.rail].focused = id
        // Reasserting focus after a stop must not reveal past that stop.
        if changed { reveal(&ws.rails[p.rail]) }
        workspaces[p.workspace] = ws
    }
    mutating func appendInitial(_ tile: Tile, workspace: Int) {
        var ws = workspaces[workspace] ?? Workspace()
        if ws.rails.isEmpty { ws.rails.append(makeRail()) }
        ws.rails[0].tiles.append(tile)
        if ws.rails[0].focused == nil { ws.rails[0].focused = tile.id }
        if ws.rails[0].acceptsInitialExpansion, canExpand(ws.rails[0], at: 0) { ws.rails[0].expanded = .start }
        workspaces[workspace] = ws
    }
    mutating func insert(_ tile: Tile, workspace: Int, restoring: Bool = false) {
        var ws = workspaces[workspace] ?? Workspace()
        let previous = suspended.removeValue(forKey: tile.id)
        if ws.rails.isEmpty { ws.rails.append(makeRail()); ws.current = 0 }
        var target = ws.current
        var left: UInt32?
        if restoring, let previous, previous.workspace == workspace,
           let r = ws.rails.firstIndex(where: { $0.identity == previous.rail }) { target = r; left = previous.left }
        insert(restoring ? previous?.tile ?? tile : tile, into: &ws.rails[target], after: left)
        ws.current = target
        workspaces[workspace] = ws
    }
    private func insert(_ tile: Tile, into rail: inout Rail, after left: UInt32? = nil) {
        let anchorID = left.flatMap { id in rail.tiles.contains { $0.id == id } ? id : nil } ?? rail.focused
        let index = anchorID.flatMap { id in rail.tiles.firstIndex { $0.id == id } }
        let x = index.map { geometry(rail)[$0].minX }
        rail.expanded = nil
        rail.acceptsInitialExpansion = false
        rail.tiles.insert(tile, at: index.map { $0 + 1 } ?? 0)
        if let anchorID, let x { anchor(&rail, id: anchorID, x: x) }
        rail.focused = tile.id
        reveal(&rail)
    }
    @discardableResult
    mutating func remove(_ id: UInt32, suspending: Bool = false) -> UInt32? {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return nil }
        let rail = ws.rails[p.rail]
        let neighborIndex = p.slot > 0 ? p.slot - 1 : 1
        let neighbor = rail.tiles.count > 1 ? rail.tiles[neighborIndex].id : nil
        if suspending {
            suspended[id] = Place(workspace: p.workspace, rail: rail.identity,
                                  left: p.slot > 0 ? rail.tiles[p.slot - 1].id : nil, tile: rail.tiles[p.slot])
        } else { suspended[id] = nil }
        if rail.tiles.count == 1 {
            ws.rails.remove(at: p.rail)
            if p.rail < ws.current { ws.current -= 1 }
            ws.current = max(0, min(ws.current, ws.rails.count - 1))
        } else {
            let x = geometry(rail)[neighborIndex].minX
            ws.rails[p.rail].expanded = nil
            ws.rails[p.rail].acceptsInitialExpansion = false
            ws.rails[p.rail].tiles.remove(at: p.slot)
            if rail.focused == id { ws.rails[p.rail].focused = neighbor }
            if let neighbor { anchor(&ws.rails[p.rail], id: neighbor, x: x) }
            reveal(&ws.rails[p.rail])
        }
        workspaces[p.workspace] = ws
        return remembered(p.workspace)
    }
    mutating func forget(_ id: UInt32) { remove(id); suspended[id] = nil }
    mutating func replace(_ old: UInt32, with id: UInt32) {
        if let p = location(old) {
            workspaces[p.workspace]?.rails[p.rail].tiles[p.slot].id = id
            if workspaces[p.workspace]?.rails[p.rail].focused == old { workspaces[p.workspace]?.rails[p.rail].focused = id }
        }
        if var place = suspended.removeValue(forKey: old) { place.tile.id = id; suspended[id] = place }
        for key in suspended.keys.sorted() where suspended[key]?.left == old { suspended[key]?.left = id }
    }
    mutating func cycleWidth(_ id: UInt32) {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return }
        var rail = ws.rails[p.rail]
        let x = geometry(rail)[p.slot].minX, tile = rail.tiles[p.slot], current = nominal(tile)
        let candidates = Self.presets.filter { fits(tile, $0) }
        guard let next = candidates.first(where: { presetWidth($0) > current + 1 }) ?? candidates.first else { return }
        rail.tiles[p.slot].preset = next
        rail.expanded = nil
        rail.acceptsInitialExpansion = false
        anchor(&rail, id: id, x: x); reveal(&rail)
        ws.rails[p.rail] = rail; workspaces[p.workspace] = ws
    }
    mutating func focusX(_ workspace: Int, direction: Int) -> UInt32? {
        guard var ws = workspaces[workspace], ws.rails.indices.contains(ws.current) else { return nil }
        var rail = ws.rails[ws.current]
        guard let i = rail.tiles.firstIndex(where: { $0.id == rail.focused }) else { return nil }
        rail.acceptsInitialExpansion = false
        if let expanded = rail.expanded {
            if (expanded == .end) == (direction > 0) { return nil }
            rail.expanded = nil
        }
        let ahead: (Int) -> Bool = { ($0 - i) * direction > 0 }
        func nearest(_ indices: [Int]) -> Int? { indices.sorted { ($0 - $1) * direction < 0 }.first }
        if let next = nearest(whole(rail).filter(ahead)) {
            rail.focused = rail.tiles[next].id
        } else if let stop = nextStop(rail, direction: direction) {
            rail.offset = stop
            let complete = whole(rail)
            if let next = nearest(complete.filter(ahead)) ?? (complete.contains(i) ? i : complete.first) { rail.focused = rail.tiles[next].id }
        } else if i == (direction > 0 ? rail.tiles.count - 1 : 0), canExpand(rail, at: i) {
            rail.expanded = direction > 0 ? .end : .start
        } else { return nil }
        ws.rails[ws.current] = rail; workspaces[workspace] = ws
        return rail.focused
    }
    mutating func focusY(_ workspace: Int, direction: Int) -> UInt32? {
        guard var ws = workspaces[workspace], ws.rails.indices.contains(ws.current + direction) else { return nil }
        ws.current += direction; workspaces[workspace] = ws
        return ws.rails[ws.current].focused
    }
    mutating func moveX(_ id: UInt32, direction: Int) -> Bool {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return false }
        var rail = ws.rails[p.rail]
        let j = p.slot + direction
        guard rail.tiles.indices.contains(j) else { return false }
        let x = geometry(rail)[p.slot].minX, other = rail.tiles[j].id
        rail.expanded = nil; rail.tiles.swapAt(p.slot, j)
        anchor(&rail, id: other, x: x); reveal(&rail)
        ws.rails[p.rail] = rail; workspaces[p.workspace] = ws
        return true
    }
    mutating func moveY(_ id: UInt32, direction: Int) -> Bool {
        guard let p = location(id), let ws = workspaces[p.workspace] else { return false }
        let alone = ws.rails[p.rail].tiles.count == 1
        guard !(alone && (direction < 0 ? p.rail == 0 : p.rail == ws.rails.count - 1)) else { return false }
        let tile = ws.rails[p.rail].tiles[p.slot]
        remove(id)
        var next = workspaces[p.workspace]!
        var target = direction > 0 ? (alone ? p.rail : p.rail + 1) : p.rail - 1
        if target < 0 { next.rails.insert(makeRail(), at: 0); target = 0 }
        if target >= next.rails.count { next.rails.append(makeRail()) }
        insert(tile, into: &next.rails[target]); next.current = target
        workspaces[p.workspace] = next
        return true
    }
    func frames(_ workspace: Int, area: CGRect) -> [UInt32: CGRect] {
        guard let rail = current(workspace) else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(rail.tiles, geometry(rail)).map { tile, frame in
            (tile.id, frame.offsetBy(dx: area.minX, dy: area.minY))
        })
    }
    private func strip(_ rail: Rail) -> (starts: [Double], widths: [Double], total: Double) {
        var starts: [Double] = [], x = 0.0
        let widths = rail.tiles.map(nominal)
        for w in widths { starts.append(x); x += w + gap }
        return (starts, widths, max(0, x - gap))
    }
    private func geometry(_ rail: Rail, expanded: Bool = true) -> [CGRect] {
        let m = strip(rail), n = rail.tiles.count
        guard n > 0 else { return [] }
        var widths = m.widths, xs = m.starts.map { $0 - rail.offset }
        if expanded, let end = rail.expanded {
            let i = end == .start ? 0 : n - 1
            widths[i] = min(width, rail.tiles[i].maximum)
            var x = end == .start ? 0 : widths[i] - widths.reduce(0, +) - gap * Double(n - 1)
            for j in 0..<n { xs[j] = x; x += widths[j] + gap }
        } else if m.total < width {
            // Accepted maxima cap a tile; remaining capacity goes to its peers.
            var free = Set(0..<n), remaining = max(0, width - gap * Double(n - 1))
            while !free.isEmpty {
                let indices = free.sorted(), sum = indices.reduce(0.0) { $0 + m.widths[$1] }
                let scale = remaining / max(1, sum)
                let capped = indices.filter { m.widths[$0] * scale > rail.tiles[$0].maximum }
                if capped.isEmpty { for j in indices { widths[j] = m.widths[j] * scale }; break }
                for j in capped { widths[j] = rail.tiles[j].maximum; remaining -= widths[j]; free.remove(j) }
            }
            var x = 0.0
            for j in 0..<n { xs[j] = x; x += widths[j] + gap }
        }
        return (0..<n).map { CGRect(x: xs[$0], y: 0, width: widths[$0], height: rail.tiles[$0].size.height) }
    }
    private func whole(_ rail: Rail) -> [Int] {
        geometry(rail, expanded: false).enumerated().compactMap { i, f in f.minX >= -1e-6 && f.maxX <= width + 1e-6 ? i : nil }
    }
    private func canExpand(_ rail: Rail, at i: Int) -> Bool {
        rail.tiles.count > 1 && rail.tiles[i].maximum >= width - 1 && geometry(rail, expanded: false)[i].width < width - 1e-6
    }
    private func clamp(_ rail: inout Rail) { rail.offset = max(0, min(max(0, strip(rail).total - width), rail.offset)) }
    private func anchor(_ rail: inout Rail, id: UInt32, x: Double) {
        guard let i = rail.tiles.firstIndex(where: { $0.id == id }) else { return }
        rail.offset = strip(rail).starts[i] - x; clamp(&rail)
    }
    private func reveal(_ rail: inout Rail) {
        guard rail.expanded == nil, let i = rail.tiles.firstIndex(where: { $0.id == rail.focused }) else { return }
        let m = strip(rail)
        if m.starts[i] < rail.offset { rail.offset = m.starts[i] }
        if m.starts[i] + m.widths[i] > rail.offset + width { rail.offset = m.starts[i] + m.widths[i] - width }
        clamp(&rail)
    }
    private func nextStop(_ rail: Rail, direction: Int) -> Double? {
        let m = strip(rail)
        guard m.total > width else { return nil }
        let limit = m.total - width
        var stops: [Double] = []
        for (i, x) in m.starts.enumerated() {
            stops.append(max(0, min(limit, x)))
            stops.append(max(0, min(limit, x + m.widths[i] - width)))
        }
        let step = Double(direction)
        return stops.filter { ($0 - rail.offset) * step > 1e-6 }.min { ($0 - $1) * step < 0 }
    }
}
