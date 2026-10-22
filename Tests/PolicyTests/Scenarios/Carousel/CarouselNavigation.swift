import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselNavigation {
    @Test("#26 E1: half-width traversal stops at both ends without changing a width, and never wraps", arguments: WriteOrder.allCases)
    func halfWidthStopsAndEnds(order: WriteOrder) {
        requireCarousel(Scenario.run("half-width stops and ends", writes: order) { s in
            let f = CarouselFixture(s), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.pair(a, b, focused: a)
            f.press("alt-l"); f.pair(a, b, focused: b)
            f.press("alt-l"); f.pair(b, c, focused: c)
            let end = f.snapshot(); f.press("alt-l"); f.pair(b, c, focused: c); f.unchanged(end)
            f.press("alt-h"); f.pair(b, c, focused: b)
            f.press("alt-h"); f.pair(a, b, focused: a)
            let start = f.snapshot(); f.press("alt-h"); f.pair(a, b, focused: a); f.unchanged(start)
        })
    }

    @Test("#26 E2: focus crosses the visible pair before the carousel moves")
    func focusCrossesPairWithoutGeometryWrites() {
        requireCarousel(Scenario.run("focus crosses pair") { s in
            let f = CarouselFixture(s), b = f.ids[1], c = f.ids[2]
            f.press("alt-l"); f.press("alt-l")
            let before = f.snapshot(); f.mac.clearMotionHistory()
            f.press("alt-h"); f.pair(b, c, focused: b); f.unchanged(before)
            s.expect("a focus-only command performs no geometry writes", f.mac.geometryWrites.isEmpty)
            s.expect("a focus-only command leaves the stage untouched", f.mac.stageEvents.isEmpty)
        })
        requireCarousel(Scenario.run("focus chooses the nearest of several complete thirds") { s in
            let f = CarouselFixture(s, presets: Array(repeating: 1.0/3, count: 5)), ids = f.ids
            f.press("alt-l"); f.focus(ids[1])
            let before = f.snapshot(); f.mac.clearMotionHistory()
            f.press("alt-l"); f.focus(ids[2]); f.unchanged(before)
            f.press("alt-h"); f.focus(ids[1]); f.unchanged(before)
            s.expect("crossing complete thirds neither writes geometry nor uses the stage", f.mac.geometryWrites.isEmpty && f.mac.stageEvents.isEmpty)
        })
    }

    @Test("#26 E3: mixed widths visit every edge stop while focus waits for a complete window")
    func mixedWidthsNeverSkipAStop() {
        requireCarousel(Scenario.run("mixed edge stops") { s in
            let f = CarouselFixture(s, presets: [0.5, 1.0/3, 1.0/3, 1, 0.5]), ids = f.ids
            let widths = [0.5, 1.0/3, 1.0/3, 1, 0.5].map(f.width)
            var starts: [Double] = [], x = 0.0
            for w in widths { starts.append(x); x += w + 10 }
            // Two commands from the start reach E3's stated precondition.
            f.press("alt-l"); f.press("alt-l")
            f.focus(ids[2]); f.near(f.frame(ids[2]).maxX, f.area.maxX, "third right edge in the precondition")
            f.near(f.frame(ids[0]).maxX - f.area.minX, widths[0] - (starts[2] + widths[2] - f.area.width), "first window's exposed portion")
            let cameras = [starts[1], starts[2], starts[3], starts[4] + widths[4] - f.area.width]
            let focuses = [ids[2], ids[2], ids[3], ids[4]]
            for (camera, focus) in zip(cameras, focuses) {
                f.press("alt-l"); f.focus(focus)
                for i in ids.indices where f.mac.isVisible(ids[i]) {
                    f.near(f.frame(ids[i]).minX, f.area.minX + starts[i] - camera, "stop \(camera), window \(ids[i])")
                }
            }
            let end = f.snapshot(); f.press("alt-l"); f.focus(ids[4]); f.unchanged(end)
        })
    }

    @Test("#26 E4: prototype scenarios keep coverage and complete focus over command sequences up to twelve")
    func populatedAreaAndCompleteFocusAreSequenceInvariants() {
        let scenarios: [[Double]] = [[0.5,0.5,0.5], [0.5,0.5], [1,1], Array(repeating: 1.0/3, count: 5),
                                     [0.5,1.0/3,2.0/3,1,0.5], [0.5,1.0/3,1.0/3,1,0.5], [0.5,2.0/3,0.5], [0.5,0.5,0.5,0.5,0.5]]
        let operations = ["alt-h", "alt-l", "alt-j", "alt-k", "alt-r", "open", "close"]
        // All operation pairs, every length 1…12 as a prefix, plus long repeats
        // and reversals. Fixed arithmetic makes failures replayable across seeds.
        for (index, presets) in scenarios.enumerated() {
            for seed in 0..<63 {
                requireCarousel(Scenario.run("coverage scenario=\(index) sequence=\(seed)") { s in
                    // E4 judges settled coverage after every prefix; E16 owns
                    // intermediate frames and the spring at both durations.
                    let f = CarouselFixture(s, presets: presets, duration: 0, minimumFractions: index == 6 ? [1:0.62] : [:])
                    if index == 7 { f.select(f.ids[3]); f.press("alt-shift-j"); f.select(f.ids[4]); f.press("alt-shift-j"); f.press("alt-k") }
                    f.invariants("initial")
                    for depth in 0..<12 {
                        let op: Int
                        if seed >= 56 { op = depth.isMultiple(of:2) ? seed-56 : (seed-55)%7 }
                        else if seed >= 49 { op = seed-49 }
                        else { op = depth == 0 ? seed / 7 : depth == 1 ? seed % 7 : (seed * 17 + depth * depth + depth / 3) % 7 }
                        let command = operations[op]
                        if command == "open" { _ = f.open() }
                        else if command == "close", let id = f.mac.focusedWindow { f.app.close(id); s.settle() }
                        else if command != "close" { f.press(command) }
                        f.invariants("prefix \(depth + 1) after \(command)")
                    }
                })
            }
        }
    }


    @Test("#26 E6: full-width neighbours are never left as a split pair")
    func fullWidthWindowsAlwaysRestWhole() {
        requireCarousel(Scenario.run("whole full-width windows") { s in
            let f = CarouselFixture(s, presets: [1,1]), a = f.ids[0], b = f.ids[1]
            f.expanded(a); f.press("alt-l"); f.expanded(b)
            s.expect("only the second full-width window remains visible at rest", !f.mac.isVisible(a))
            f.press("alt-h"); f.expanded(a)
            s.expect("only the first full-width window remains visible at rest", !f.mac.isVisible(b))
        })
    }
}
