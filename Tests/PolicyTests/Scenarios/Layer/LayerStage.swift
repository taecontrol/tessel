import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerStage {
    @Test("#19 E10: rail motion captures each visible pinned float once, excludes it from background, and captures no hidden float", arguments: [false, true])
    func pinnedFloatCaptureRequests(pinned: Bool) {
        requireLayer(Scenario.run("rail motion with pinned=\(pinned)") { s in
            let f = LayerFixture(s, floatSpecs: (0..<3).map { _ in WindowSpec(subrole: "AXFloatingWindow") }, duration: 250)
            f.press("toggle layer"); f.press("focus left"); f.press("send 3"); f.press("workspace 1")
            let remote = f.floats[2], local = Array(f.floats.prefix(2))
            if pinned { f.press("pin layer") }
            f.select(f.tiles[1])
            let before = f.frames(local), exclusionStart = f.mac.stageBackgroundExclusions.count
            f.mac.clearMotionHistory()
            f.press("focus right"); f.focus(f.tiles[2])
            let expected = Set(f.tiles + (pinned ? local : []))
            s.expect("motion captures exactly its tiles and visible pinned floats", Set(f.captures) == expected && f.captures.count == expected.count)
            s.expect("the hidden workspace float is never captured", !f.captures.contains(remote))
            let exclusions = f.mac.stageBackgroundExclusions.dropFirst(exclusionStart)
            if pinned {
                s.expect("pinned floats are excluded from every background request", !exclusions.isEmpty && exclusions.allSatisfy { Set(local).isSubset(of: $0) })
                let frames = f.mac.stageEvents.flatMap { event -> [[UInt32: CGRect]] in
                    switch event.kind { case .show(let rects), .move(let rects, _): [rects]; default: [] }
                }
                s.expect("each staged frame retains both pinned floats at their fixed rects", !frames.isEmpty && frames.allSatisfy { rects in local.allSatisfy { rects[$0] == before[$0] } })
            }
            f.unchanged(before)
        })
    }
}
