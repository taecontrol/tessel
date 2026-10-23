/// Visibility and entry intent belong to each workspace. Focus history and
/// arrival order remain owned by Workspaces; the layer never copies them.
struct FloatingLayer {
    enum Entry: Equatable {
        case rails, single(UInt32), all
    }
    var entry = Entry.rails
    var focused: Bool { entry != .rails }
    var status: LayerStatus {
        let state = switch entry { case .rails: "hidden"; case .single: "single"; case .all: "shown" }
        return LayerStatus(state: state, focused: focused)
    }
    func shows(_ id: UInt32) -> Bool { entry == .all || entry == .single(id) }
    mutating func arrive(_ id: UInt32) {
        entry = entry == .all ? .all : .single(id)
    }
}
