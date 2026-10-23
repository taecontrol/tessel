import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct LayerStage {
    @Test("#38 E4: rail motion captures tiles and no hidden local or remote floats")
    func hiddenFloatsAreNotCaptured() {
        requireLayer(Scenario.run("rail motion with hidden local and remote floats") { s in
            let f = LayerFixture(s, floatSpecs: (0..<3).map { _ in WindowSpec(subrole: "AXFloatingWindow") }, duration: 250)
            f.press("toggle layer"); f.press("focus left"); f.press("send 3"); f.press("workspace 1")
            let remote = f.floats[2], local = Array(f.floats.prefix(2))
            f.select(f.tiles[1])
            let before = f.frames(local)
            f.mac.clearMotionHistory()
            f.press("focus right"); f.focus(f.tiles[2])
            let expected = Set(f.tiles)
            s.expect("motion captures exactly its tiles: expected \(expected.sorted()), requested \(f.captures)", Set(f.captures) == expected && f.captures.count == expected.count)
            s.expect("the hidden workspace float is never captured", !f.captures.contains(remote))
            let exclusions = f.captureRequests.compactMap(\.backgroundExcluding)
            s.expect("motion requests exactly one background capture", exclusions.count == 1)
            let floatCaptures = f.captureRequests.flatMap { $0.windows.sorted() }.filter { f.floats.contains($0) }
            s.expect("hidden floats request no captures, including refreshes", floatCaptures.isEmpty)
            f.unchanged(before)
        })
    }
}
