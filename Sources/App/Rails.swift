import Foundation

/// The rail policy owns ring geometry, remembered focus and stable row identity.
/// Coordinates are relative to the rail area; the presenter owns AX and hiding.
struct Rails {
    struct Tile {
        var id: UInt32
        var size: CGSize
    }
    struct Rail {
        let identity = UUID()
        var tiles: [Tile] = []
        var offset: Double = 0
        var focused: UInt32?
    }
    struct Workspace {
        var rails: [Rail] = []
        var current = 0
    }
    struct Place {
        let workspace: Int
        let rail: UUID
        let left: UInt32?
    }
    var workspaces: [Int: Workspace] = [:]
    private var suspended: [UInt32: Place] = [:]
    var width: Double = 1
    var gap: Double = 10
    static let peek: Double = 56

    func location(_ id: UInt32) -> (workspace: Int, rail: Int, slot: Int)? {
        for (number,ws) in workspaces {
            for (r,rail) in ws.rails.enumerated() {
                if let slot = rail.tiles.firstIndex(where: { $0.id == id }) { return (number,r,slot) }
            }
        }
        return nil
    }
    func current(_ workspace: Int) -> Rail? {
        guard let ws = workspaces[workspace], ws.rails.indices.contains(ws.current) else { return nil }
        return ws.rails[ws.current]
    }
    func remembered(_ workspace: Int) -> UInt32? { current(workspace)?.focused }
    func size(_ id: UInt32) -> CGSize? {
        guard let p = location(id) else { return nil }
        return workspaces[p.workspace]?.rails[p.rail].tiles[p.slot].size
    }
    mutating func setSize(_ id: UInt32, _ size: CGSize) {
        guard let p = location(id) else { return }
        workspaces[p.workspace]?.rails[p.rail].tiles[p.slot].size = size
    }
    mutating func select(_ id: UInt32, direction: Int = 0) {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return }
        ws.current = p.rail
        ws.rails[p.rail].focused = id
        reveal(&ws.rails[p.rail], direction: direction)
        workspaces[p.workspace] = ws
    }
    mutating func appendInitial(_ tile: Tile, workspace: Int) {
        var ws = workspaces[workspace] ?? Workspace()
        if ws.rails.isEmpty { ws.rails.append(Rail()) }
        ws.rails[0].tiles.append(tile)
        if ws.rails[0].focused == nil { ws.rails[0].focused = tile.id }
        workspaces[workspace] = ws
    }
    mutating func insert(_ tile: Tile, workspace: Int, restoring: Bool = false) {
        var ws = workspaces[workspace] ?? Workspace()
        let previous = suspended.removeValue(forKey: tile.id)
        if ws.rails.isEmpty { ws.rails.append(Rail()); ws.current = 0 }
        var target = ws.current
        var left: UInt32?
        if restoring, let previous, previous.workspace == workspace,
           let r = ws.rails.firstIndex(where: { $0.identity == previous.rail }) {
            target = r; left = previous.left
        }
        insert(tile, into: &ws.rails[target], after: left)
        ws.current = target
        workspaces[workspace] = ws
    }
    private func insert(_ tile: Tile, into rail: inout Rail, after left: UInt32? = nil) {
        let anchorID = left.flatMap { id in rail.tiles.contains { $0.id == id } ? id : nil } ?? rail.focused
        let index = anchorID.flatMap { id in rail.tiles.firstIndex { $0.id == id } }
        let x = index.map { positions(rail)[$0] }
        rail.tiles.insert(tile, at: index.map { $0 + 1 } ?? 0)
        if let anchorID, let x { anchor(&rail, id: anchorID, x: x) }
        rail.focused = tile.id
        reveal(&rail, direction: 1)
    }
    @discardableResult
    mutating func remove(_ id: UInt32, suspending: Bool = false) -> UInt32? {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return nil }
        let rail = ws.rails[p.rail]
        let leftIndex = (p.slot + rail.tiles.count - 1) % rail.tiles.count
        let left = rail.tiles.count > 1 ? rail.tiles[leftIndex].id : nil
        if suspending { suspended[id] = Place(workspace:p.workspace,rail:rail.identity,left:left) }
        else { suspended[id] = nil }
        if rail.tiles.count == 1 {
            ws.rails.remove(at:p.rail)
            if p.rail < ws.current { ws.current -= 1 }
            ws.current = max(0,min(ws.current,ws.rails.count-1))
        } else {
            let x = positions(rail)[leftIndex]
            ws.rails[p.rail].tiles.remove(at:p.slot)
            if rail.focused == id { ws.rails[p.rail].focused = left }
            if let left { anchor(&ws.rails[p.rail],id:left,x:x) }
            reveal(&ws.rails[p.rail],direction:0)
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
        if let place = suspended.removeValue(forKey:old) { suspended[id] = place }
        for (key,place) in suspended where place.left == old { suspended[key] = Place(workspace:place.workspace,rail:place.rail,left:id) }
    }
    mutating func focusX(_ workspace: Int, direction: Int) -> UInt32? {
        guard let rail = current(workspace), let focused = rail.focused,
              let i = rail.tiles.firstIndex(where: { $0.id == focused }), rail.tiles.count > 1 else { return nil }
        let id = rail.tiles[(i+direction+rail.tiles.count)%rail.tiles.count].id
        select(id,direction:direction)
        return id
    }
    mutating func focusY(_ workspace: Int, direction: Int) -> UInt32? {
        guard var ws = workspaces[workspace], ws.rails.indices.contains(ws.current+direction) else { return nil }
        ws.current += direction; workspaces[workspace] = ws
        return ws.rails[ws.current].focused
    }
    mutating func moveX(_ id: UInt32, direction: Int) -> Bool {
        guard let p = location(id), var ws = workspaces[p.workspace] else { return false }
        var rail = ws.rails[p.rail]
        guard rail.tiles.count > 1 else { return false }
        let j = (p.slot+direction+rail.tiles.count)%rail.tiles.count
        let x = positions(rail)[p.slot], other = rail.tiles[j].id
        rail.tiles.swapAt(p.slot,j)
        anchor(&rail,id:other,x:x); reveal(&rail,direction:direction)
        ws.rails[p.rail] = rail; workspaces[p.workspace] = ws
        return true
    }
    mutating func moveY(_ id: UInt32, direction: Int) -> Bool {
        guard let p = location(id), let ws = workspaces[p.workspace] else { return false }
        let alone = ws.rails[p.rail].tiles.count == 1
        guard !(alone && (direction < 0 ? p.rail == 0 : p.rail == ws.rails.count-1)) else { return false }
        let tile = ws.rails[p.rail].tiles[p.slot]
        remove(id)
        var next = workspaces[p.workspace]!
        var target = direction > 0 ? (alone ? p.rail : p.rail+1) : p.rail-1
        if target < 0 { next.rails.insert(Rail(),at:0); target = 0 }
        if target >= next.rails.count { next.rails.append(Rail()) }
        insert(tile,into:&next.rails[target]); next.current = target
        workspaces[p.workspace] = next
        return true
    }
    func frames(_ workspace: Int, area: CGRect) -> [UInt32:CGRect] {
        guard let rail = current(workspace) else { return [:] }
        let xs = positions(rail)
        return Dictionary(uniqueKeysWithValues: rail.tiles.enumerated().map { i,tile in
            (tile.id, CGRect(origin:CGPoint(x:area.minX+xs[i],y:area.minY),size:tile.size))
        })
    }
    private func metrics(_ rail: Rail) -> (starts:[Double],circumference:Double,fits:Bool) {
        var starts:[Double] = [], total:Double = 0
        for tile in rail.tiles { starts.append(total); total += tile.size.width+gap }
        return (starts,max(1,total),total-gap <= width)
    }
    private func mod(_ x: Double, _ n: Double) -> Double { let r = x.truncatingRemainder(dividingBy:n); return r < 0 ? r+n : r }
    private func copies(_ rail: Rail, index: Int) -> [Double] {
        let m = metrics(rail)
        if m.fits { return [m.starts[index]] }
        let x = mod(m.starts[index]-rail.offset,m.circumference)
        return [x,x-m.circumference,x+m.circumference]
    }
    private func positions(_ rail: Rail) -> [Double] {
        rail.tiles.enumerated().map { i,tile in
            copies(rail,index:i).max { a,b in
                max(0,min(a+tile.size.width,width+gap)-max(a,-gap)) < max(0,min(b+tile.size.width,width+gap)-max(b,-gap))
            }!
        }
    }
    private func anchor(_ rail: inout Rail, id: UInt32, x: Double) {
        guard let i = rail.tiles.firstIndex(where: { $0.id == id }) else { return }
        let m = metrics(rail)
        rail.offset = m.fits ? 0 : mod(m.starts[i]-x,m.circumference)
    }
    private func reveal(_ rail: inout Rail, direction: Int) {
        let m = metrics(rail)
        if m.fits { rail.offset = 0; return }
        guard let i = rail.tiles.firstIndex(where: { $0.id == rail.focused }) else { return }
        let w = rail.tiles[i].size.width, xs = copies(rail,index:i)
        if xs.contains(where: { $0 >= -0.5 && $0+w <= width+0.5 }) { return }
        let wide = w > width-2*Self.peek
        let right = wide ? (width-w)/2 : width-Self.peek-w
        let left = wide ? (width-w)/2 : Self.peek
        let targets = direction > 0 ? [right] : direction < 0 ? [left] : [left,right]
        let delta = xs.flatMap { x in targets.map { x-$0 } }.min { abs($0) < abs($1) } ?? 0
        rail.offset = mod(rail.offset+delta,m.circumference)
    }
}
