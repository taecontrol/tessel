import CoreGraphics

/// Where tessel or the pointer left each rail tile. An app may move it twice
/// before tessel concedes, until a layout placement or another drag resets it.
struct ExpectedPositions {
    static let corrections = 2
    private enum State { case watching(CGPoint, corrections: Int), conceded }
    private var tiles: [UInt32: State] = [:]
    private var owed: Set<UInt32> = []
    private enum Reason { case layout, correction }
    private var queued: [UInt32: Reason] = [:]
    private var writing: [UInt32: (ticket: UInt64, correction: Bool)] = [:]
    /// Until a layout readback succeeds, a retry still belongs to that layout,
    /// even when its snapshot differs from the previous accepted point.
    private var layoutPending: Set<UInt32> = []
    private var nextTicket: UInt64 = 0

    /// The caller excludes gestures, closeted tiles, resizes and targets not
    /// entirely on screen. True requests a correction or an unfinished layout's
    /// retry; repeated snapshots of an owed move count once.
    mutating func observe(_ id: UInt32, at origin: CGPoint) -> Bool {
        guard queued[id] == nil, writing[id] == nil, case .watching(let point, let count) = tiles[id] else { return false }
        if owed.contains(id) { return true }
        guard !Workspaces.near(point.x, origin.x) || !Workspaces.near(point.y, origin.y) else { return false }
        if layoutPending.contains(id) { return true }
        guard count < Self.corrections else { tiles[id] = .conceded; return false }
        tiles[id] = .watching(point, corrections: count + 1)
        owed.insert(id)
        return true
    }

    /// A correction returns to the accepted point, which may be a pointer
    /// drop away from the layout. A superseded correction still owes its retry.
    func correctionOrigin(_ id: UInt32) -> CGPoint? {
        guard queued[id] != .layout, !layoutPending.contains(id), owed.contains(id) || writing[id]?.correction == true,
              case .watching(let point, _) = tiles[id] else { return nil }
        return point
    }

    /// Every placement must be an owed or in-flight correction; queued or
    /// unfinished layout placements still need their normal presentation.
    func areCorrections(_ ids: Set<UInt32>) -> Bool {
        ids.allSatisfy { correctionOrigin($0) != nil }
    }

    /// Retains a placement's reason before the sweep dispatches it. A layout
    /// queued over an owed correction stays a layout through another render.
    /// Only a correction uses this origin instead of the layout's target.
    mutating func queue(_ id: UInt32, layoutReason: Bool) -> CGPoint? {
        let correction = layoutReason ? nil : correctionOrigin(id)
        queued[id] = correction == nil ? .layout : .correction
        return correction
    }

    /// A new sweep replaces only the queued work; dispatched requests end
    /// through their tickets, even after cancellation.
    mutating func retainQueued(_ ids: Set<UInt32>) { queued = queued.filter { ids.contains($0.key) } }
    mutating func cancelQueued() { queued.removeAll() }

    mutating func writing(_ id: UInt32) -> WriteTicket {
        let layoutReason = queued.removeValue(forKey: id) == .layout
        let due = owed.remove(id) != nil || writing[id]?.correction == true
        let correction = due && !layoutReason && !layoutPending.contains(id)
        if !correction { layoutPending.insert(id) }
        nextTicket += 1
        writing[id] = (nextTicket, correction)
        return WriteTicket(id: id, serial: nextTicket)
    }

    /// Only the latest request may accept a readback or owe a failed correction
    /// again: cancellation can finish after its retry was already dispatched.
    mutating func ended(_ ticket: WriteTicket, accepted: CGRect?) {
        guard let request = writing[ticket.id], request.ticket == ticket.serial else { return }
        writing[ticket.id] = nil
        if let accepted {
            layoutPending.remove(ticket.id)
            var count = 0
            if request.correction, case .watching(_, let corrections) = tiles[ticket.id] { count = corrections }
            tiles[ticket.id] = .watching(accepted.origin, corrections: count)
        } else if request.correction { owed.insert(ticket.id) }
    }

    mutating func dragged(_ id: UInt32, to origin: CGPoint) {
        tiles[id] = .watching(origin, corrections: 0)
        owed.remove(id)
        queued[id] = nil
        writing[id] = nil
        layoutPending.remove(id)
    }

    mutating func replace(_ previous: UInt32, with id: UInt32) {
        guard previous != id else { return }
        forget(id)
        tiles[id] = tiles.removeValue(forKey: previous)
        queued[id] = queued.removeValue(forKey: previous)
        if layoutPending.remove(previous) != nil { layoutPending.insert(id) }
        if owed.remove(previous) != nil { owed.insert(id) }
        if writing.removeValue(forKey: previous)?.correction == true { owed.insert(id) }
    }

    mutating func forget(_ id: UInt32) {
        tiles[id] = nil
        owed.remove(id)
        queued[id] = nil
        writing[id] = nil
        layoutPending.remove(id)
    }
}

struct WriteTicket {
    let id: UInt32
    let serial: UInt64
}
