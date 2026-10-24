import CoreGraphics
import Testing
@testable import Policy

/// The accepted #39 state table at the value type's seam. Scenarios own the
/// gesture, closet, sizing and screen guards; these tests own counts and tickets.
@Suite struct ExpectedPositionsTests {
    private static let point = CGPoint(x: 100, y: 43)
    private static let away = CGPoint(x: 200, y: 70)
    private static let frame = CGRect(origin: point, size: CGSize(width: 400, height: 600))

    @Test("an unplaced tile is unwatched, including after a failed first placement")
    func unplacedIsUnwatched() {
        var positions = ExpectedPositions()
        #expect(positions.observe(1, at: Self.away) == false)
        _ = positions.queue(1, layoutReason: true)
        let ticket = positions.writing(1)
        positions.ended(ticket, accepted: nil)
        #expect(positions.observe(1, at: Self.away) == false)
        #expect(positions.correctionOrigin(1) == nil)
    }

    @Test("each axis shares the presenter's inclusive one-point tolerance", arguments: [false, true])
    func onePointTolerance(_ vertical: Bool) {
        var positions = placed()
        for delta in [-1.0, 0, 1] {
            let point = Self.point.offsetBy(dx: vertical ? 0 : delta, dy: vertical ? delta : 0)
            #expect(positions.observe(1, at: point) == false)
        }
        let moved = Self.point.offsetBy(dx: vertical ? 0 : 1.01, dy: vertical ? 1.01 : 0)
        #expect(positions.observe(1, at: moved) == true)
    }

    @Test("owed snapshots count once; correction readbacks keep the count and become the expected point")
    func correctionReadbacksAndConcession() {
        var positions = placed()
        var accepted = Self.frame
        for correction in 1...2 {
            #expect(positions.observe(1, at: Self.away) == true)
            #expect(positions.observe(1, at: Self.away) == true)
            #expect(positions.correctionOrigin(1) == accepted.origin)
            let ticket = positions.writing(1)
            #expect(positions.observe(1, at: Self.away) == false)
            accepted.origin.x += CGFloat(correction) / 4
            positions.ended(ticket, accepted: accepted)
            #expect(positions.observe(1, at: accepted.origin) == false)
        }
        for _ in 0..<3 { #expect(positions.observe(1, at: Self.away) == false) }
        #expect(positions.correctionOrigin(1) == nil)
    }

    @Test("a layout readback resets watched and conceded tiles", arguments: [0, 1, 2, 3])
    func layoutResetsAllowance(_ moves: Int) {
        var positions = afterMoves(moves)
        _ = positions.queue(1, layoutReason: true)
        let ticket = positions.writing(1)
        var accepted = Self.frame
        accepted.origin = Self.away
        positions.ended(ticket, accepted: accepted)
        #expect(positions.observe(1, at: Self.away) == false)
        expectAllowance(&positions, id: 1, point: Self.away, remaining: 2)
    }

    @Test("a drag resets watched and conceded tiles at its drop point", arguments: [0, 1, 2, 3])
    func dragResetsAllowance(_ moves: Int) {
        var positions = afterMoves(moves)
        positions.dragged(1, to: Self.away)
        #expect(positions.observe(1, at: Self.away) == false)
        expectAllowance(&positions, id: 1, point: Self.away, remaining: 2)
    }

    @Test("a write ending without a frame keeps its point and count", arguments: [false, true])
    func missingFrameKeepsState(_ correction: Bool) {
        var positions = afterMoves(1)
        if correction { #expect(positions.observe(1, at: Self.away) == true) }
        _ = positions.queue(1, layoutReason: !correction)
        let ticket = positions.writing(1)
        positions.ended(ticket, accepted: nil)
        if correction {
            #expect(positions.correctionOrigin(1) == Self.point)
            // Retrying a failed second correction must not spend a third or
            // reset the allowance as though it had become a layout placement.
            #expect(positions.observe(1, at: Self.away) == true)
            let retry = positions.writing(1)
            positions.ended(retry, accepted: Self.frame)
            #expect(positions.observe(1, at: Self.away) == false)
        } else {
            #expect(positions.observe(1, at: Self.point) == false)
            #expect(positions.observe(1, at: Self.away) == true)
            #expect(positions.correctionOrigin(1) == nil)
            let retry = positions.writing(1)
            positions.ended(retry, accepted: Self.frame)
            expectAllowance(&positions, id: 1, point: Self.point, remaining: 2)
        }
    }

    @Test("a failed layout placement leaves a conceded tile conceded")
    func failedLayoutDoesNotResumeWatching() {
        var positions = afterMoves(3)
        _ = positions.queue(1, layoutReason: true)
        let ticket = positions.writing(1)
        positions.ended(ticket, accepted: nil)
        #expect(positions.observe(1, at: Self.away) == false)
    }

    @Test("only this tile's write suppresses its snapshots, and its own readback decides the point")
    func writesArePerTile() {
        var positions = placed()
        positions.dragged(2, to: Self.point)
        _ = positions.queue(1, layoutReason: true)
        let ticket = positions.writing(1)
        #expect(positions.observe(1, at: Self.away) == false)
        #expect(positions.observe(2, at: Self.away) == true)
        var accepted = Self.frame
        accepted.origin = Self.away
        positions.ended(ticket, accepted: accepted)
        #expect(positions.observe(1, at: Self.away) == false)
        #expect(positions.observe(1, at: Self.point) == true)
        #expect(positions.correctionOrigin(1) == Self.away)
    }

    @Test("a retry remains a correction when a cancelled request ends after its dispatch", arguments: [false, true])
    func staleCompletionCannotEndRetry(_ frame: Bool) {
        var positions = placed()
        #expect(positions.observe(1, at: Self.away) == true)
        let old = positions.writing(1)
        let retry = positions.writing(1)
        #expect(positions.correctionOrigin(1) == Self.point)
        positions.ended(old, accepted: frame ? CGRect(origin: Self.away, size: Self.frame.size) : nil)
        #expect(positions.observe(1, at: Self.away) == false)
        positions.ended(retry, accepted: Self.frame)
        expectAllowance(&positions, id: 1, point: Self.point, remaining: 1)
        positions.ended(old, accepted: nil)
        #expect(positions.correctionOrigin(1) == nil)
    }

    @Test("a layout supersedes an owed or in-flight correction, including a layout left pending", arguments: [false, true], [false, true])
    func layoutReasonWinsOverCorrection(_ inFlight: Bool, _ fails: Bool) {
        var positions = afterMoves(1)
        #expect(positions.observe(1, at: Self.away) == true)
        let old = inFlight ? positions.writing(1) : nil
        _ = positions.queue(1, layoutReason: true)
        let layout = positions.writing(1)
        if let old { positions.ended(old, accepted: nil) }
        if fails {
            positions.ended(layout, accepted: nil)
            let retry = positions.writing(1)
            positions.ended(retry, accepted: Self.frame)
        } else { positions.ended(layout, accepted: Self.frame) }
        expectAllowance(&positions, id: 1, point: Self.point, remaining: 2)
    }

    @Test("a queued layout keeps its origin and allowance reset through replanning and replacement", arguments: [false, true], [false, true])
    func queuedLayoutKeepsItsReason(_ inFlight: Bool, _ replace: Bool) {
        var positions = afterMoves(1)
        #expect(positions.observe(1, at: Self.away) == true)
        let old = inFlight ? positions.writing(1) : nil
        #expect(positions.queue(1, layoutReason: true) == nil)
        // Even a readback delivered after planning cannot erase the queued
        // layout's reason. Its eventual dispatch must still reset the count.
        if let old { positions.ended(old, accepted: Self.frame) }
        if replace { positions.replace(1, with: 2) }
        let id: UInt32 = replace ? 2 : 1
        #expect(positions.observe(id, at: Self.away) == false)
        #expect(positions.queue(id, layoutReason: false) == nil)
        let layout = positions.writing(id)
        let accepted = CGRect(origin: Self.away, size: Self.frame.size)
        positions.ended(layout, accepted: accepted)
        expectAllowance(&positions, id: id, point: Self.away, remaining: 2)
    }

    @Test("queued placements wait for dispatch; replacing or cancelling a sweep releases only its queued work")
    func queuedSnapshotsWaitForDispatch() {
        var positions = placed()
        positions.dragged(2, to: Self.point)
        #expect(positions.observe(2, at: Self.away) == true)
        #expect(positions.queue(1, layoutReason: true) == nil)
        #expect(positions.queue(2, layoutReason: false) == Self.point)
        for id: UInt32 in [1, 2] { #expect(positions.observe(id, at: Self.away) == false) }
        positions.retainQueued([1])
        #expect(positions.observe(1, at: Self.away) == false)
        #expect(positions.observe(2, at: Self.away) == true)
        let writing = positions.writing(2)
        positions.cancelQueued()
        #expect(positions.observe(1, at: Self.away) == true)
        #expect(positions.observe(2, at: Self.away) == false)
        positions.ended(writing, accepted: Self.frame)
        expectAllowance(&positions, id: 2, point: Self.point, remaining: 1)
    }

    @Test("native replacement transfers the expected point, allowance and concession", arguments: [0, 1, 2, 3])
    func replacementTransfersState(_ moves: Int) {
        var positions = afterMoves(moves)
        positions.replace(1, with: 2)
        #expect(positions.observe(1, at: Self.away) == false)
        #expect(positions.observe(2, at: Self.point) == false)
        expectAllowance(&positions, id: 2, point: Self.point, remaining: max(0, 2 - moves))
    }

    @Test("native replacement transfers an owed correction and drops the old window's write", arguments: [false, true])
    func replacementTransfersUnfinishedCorrection(_ inFlight: Bool) {
        var positions = afterMoves(1)
        #expect(positions.observe(1, at: Self.away) == true)
        let old = inFlight ? positions.writing(1) : nil
        positions.replace(1, with: 2)
        #expect(positions.correctionOrigin(2) == Self.point)
        #expect(positions.observe(2, at: Self.away) == true)
        let retry = positions.writing(2)
        if let old { positions.ended(old, accepted: CGRect(origin: Self.away, size: Self.frame.size)) }
        #expect(positions.observe(2, at: Self.away) == false)
        positions.ended(retry, accepted: Self.frame)
        #expect(positions.observe(2, at: Self.away) == false)
        #expect(positions.observe(1, at: Self.away) == false)
    }

    @Test("a replaced layout write cannot accept a frame for either window")
    func replacementDropsLayoutWrite() {
        var positions = afterMoves(1)
        _ = positions.queue(1, layoutReason: true)
        let old = positions.writing(1)
        positions.replace(1, with: 2)
        positions.ended(old, accepted: CGRect(origin: Self.away, size: Self.frame.size))
        #expect(positions.observe(1, at: Self.away) == false)
        #expect(positions.observe(2, at: Self.point) == false)
        let retry = positions.writing(2)
        positions.ended(retry, accepted: Self.frame)
        expectAllowance(&positions, id: 2, point: Self.point, remaining: 2)
    }

    @Test("drag and forget invalidate queued work and old tickets; reusing an ID never reuses its ticket", arguments: [false, true], [false, true])
    func dragAndForgetInvalidateWrites(_ forget: Bool, _ queued: Bool) {
        var positions = placed()
        #expect(positions.observe(1, at: Self.away) == true)
        let old = positions.writing(1)
        if queued { #expect(positions.queue(1, layoutReason: true) == nil) }
        if forget {
            positions.forget(1)
            positions.ended(old, accepted: Self.frame)
            #expect(positions.observe(1, at: Self.away) == false)
            _ = positions.queue(1, layoutReason: true)
            let next = positions.writing(1)
            positions.ended(old, accepted: Self.frame)
            positions.ended(next, accepted: CGRect(origin: Self.away, size: Self.frame.size))
        } else {
            positions.dragged(1, to: Self.away)
            positions.ended(old, accepted: Self.frame)
        }
        #expect(positions.observe(1, at: Self.away) == false)
        expectAllowance(&positions, id: 1, point: Self.away, remaining: 2)
    }

    private func placed() -> ExpectedPositions {
        var positions = ExpectedPositions()
        _ = positions.queue(1, layoutReason: true)
        let ticket = positions.writing(1)
        positions.ended(ticket, accepted: Self.frame)
        return positions
    }

    private func afterMoves(_ moves: Int) -> ExpectedPositions {
        var positions = placed()
        for move in 0..<moves {
            let correct = positions.observe(1, at: Self.away)
            #expect(correct == (move < 2))
            if correct {
                let ticket = positions.writing(1)
                positions.ended(ticket, accepted: Self.frame)
            }
        }
        return positions
    }

    private func expectAllowance(_ positions: inout ExpectedPositions, id: UInt32, point: CGPoint, remaining: Int,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let moved = point.offsetBy(dx: 20, dy: 30)
        for _ in 0..<remaining {
            #expect(positions.observe(id, at: moved) == true, sourceLocation: sourceLocation)
            let ticket = positions.writing(id)
            positions.ended(ticket, accepted: CGRect(origin: point, size: Self.frame.size))
        }
        #expect(positions.observe(id, at: moved) == false, sourceLocation: sourceLocation)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
