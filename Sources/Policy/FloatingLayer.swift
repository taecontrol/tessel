/// Visibility and entry intent belong to each workspace. Focus history and
/// arrival order remain owned by Workspaces; the layer never copies them.
struct FloatingLayer {
    enum Entry: Equatable {
        case rails, single(UInt32), all
    }
    var entry = Entry.rails
    var pinned = false

    var focused: Bool { entry != .rails }
    var status: LayerStatus {
        let state: String
        if pinned { state = "pinned" }
        else {
            state = switch entry { case .rails: "hidden"; case .single: "single"; case .all: "shown" }
        }
        return LayerStatus(state: state, focused: focused)
    }
    func shows(_ id: UInt32) -> Bool { pinned || entry == .all || entry == .single(id) }
    mutating func arrive(_ id: UInt32) {
        entry = pinned || entry == .all ? .all : .single(id)
    }
    mutating func togglePin() {
        pinned.toggle()
        if focused { entry = .all }
    }
}
