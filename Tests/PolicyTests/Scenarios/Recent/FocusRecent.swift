import CoreGraphics
import Foundation
import Simulator
import Testing
@testable import Policy

/// `focus recent` goes back to the most recently selected available window
/// other than tessel's current selection, across workspaces and floats.
@MainActor enum Recent {
    static func press(_ f: CarouselFixture) {
        f.s.step("focus recent") { f.tessel.press("focus recent") }
        f.s.settle()
    }
    static func press(_ f: LayerFixture) {
        f.s.step("focus recent") { f.tessel.press("focus recent") }
        f.s.settle()
    }
    /// The chosen window has keyboard focus, is shown and is not left in the closet.
    static func lands(_ f: CarouselFixture, _ id: UInt32) {
        f.focus(id)
        f.s.expect("window \(id) is not left in the closet", !f.mac.isInCloset(id))
    }
}

@Suite @MainActor struct FocusRecent {
    @Test("#57 E1: focus recent alternates between the last two windows of one rail", arguments: WriteOrder.allCases)
    func sameRail(writes: WriteOrder) {
        requireCarousel(Scenario.run("recent on one rail / \(writes)", writes: writes) { s in
            let f = CarouselFixture(s, presets: [0.6, 0.6, 0.6], duration: 0), a = f.ids[0], b = f.ids[1]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            Recent.press(f); Recent.lands(f, a)
            Recent.press(f); Recent.lands(f, b)
            Recent.press(f); Recent.lands(f, a)
        })
    }

    @Test("#57 E2: focus recent changes rail with the same directed slide as focus up")
    func otherRail() {
        requireCarousel(Scenario.run("recent across rails") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 250), a = f.ids[0], b = f.ids[1]
            f.focus(a)
            f.select(b); f.press("move down"); f.focus(b)
            s.expect("setup: b is alone on rail 2", f.tessel.status.rail == 2)
            let shift = f.area.height + 10
            f.mac.clearMotionHistory()
            Recent.press(f); Recent.lands(f, a)
            s.expect("rail 1 is current", f.tessel.status.rail == 1)
            let shows = f.mac.stageEvents.compactMap { if case .show(let rects) = $0.kind { rects } else { nil } }
            let moves = f.mac.stageEvents.compactMap { if case .move(let rects, _) = $0.kind { rects } else { nil } }
            s.expect("the rail change runs on the stage", shows.count == 1 && !moves.isEmpty)
            if let leaving = moves.first?[b] {
                f.near(leaving.minY, f.area.minY + shift, "going up, the leaving rail goes down")
            } else { s.expect("the leaving rail moves on the stage", false) }
            if let start = shows.first?[a], let end = moves.first?[a] {
                f.near(start.minY, end.minY - shift, "the entering rail starts one rail above")
            } else { s.expect("the entering rail moves on the stage", false) }
            Recent.press(f); Recent.lands(f, b)
            s.expect("rail 2 is current again", f.tessel.status.rail == 2)
        })
    }

    @Test("#57 E3: focus recent switches workspace instantly and closets the window it leaves")
    func otherWorkspace() {
        requireCarousel(Scenario.run("recent across workspaces") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 250), a = f.ids[0], b = f.ids[1]
            f.focus(a)
            f.press("send 2"); f.focus(a)
            f.press("workspace 1"); f.focus(b)
            f.mac.clearMotionHistory()
            Recent.press(f); Recent.lands(f, a)
            s.expect("workspace 2 is active", f.tessel.status.active == 2)
            s.expect("b waits in the closet", f.mac.isInCloset(b) && !f.mac.isVisible(b))
            s.expect("the workspace switch does not animate", !f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            Recent.press(f); Recent.lands(f, b)
            s.expect("workspace 1 is active again", f.tessel.status.active == 1)
            s.expect("a waits in the closet", f.mac.isInCloset(a) && !f.mac.isVisible(a))
        })
    }

    @Test("#57 E4: a click or Cmd-Tab counts as a selection in the history", arguments: ["click", "cmd-tab"])
    func externalSelectionCounts(how: String) {
        requireCarousel(Scenario.run("recent after \(how)") { s in
            let f = CarouselFixture(s, presets: [0.3, 0.3, 0.3], duration: 0, appCount: 3)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            s.step(how == "click" ? "click c" : "Cmd-Tab to c's app") {
                if how == "click" { f.apps[2].select(c) } else { f.apps[2].activate() }
            }
            s.settle(); f.focus(c)
            Recent.press(f); Recent.lands(f, b)
            Recent.press(f); Recent.lands(f, c)
        })
    }

    @Test("#57 E5: a new window tessel focuses enters the history")
    func newWindow() {
        requireCarousel(Scenario.run("recent after an arrival") { s in
            let f = CarouselFixture(s, presets: [0.5], duration: 0), b = f.ids[0]
            f.focus(b)
            let n = f.open(); f.focus(n)
            Recent.press(f); Recent.lands(f, b)
            Recent.press(f); Recent.lands(f, n)
        })
    }

    @Test("#57 E6: focus recent enters and leaves the floating layer")
    func floats() {
        requireLayer(Scenario.run("recent between a float and a tile") { s in
            let f = LayerFixture(s), t = f.tiles[0], float = f.floats[0]
            f.focus(t)
            f.press("toggle layer"); f.focus(float)
            f.press("toggle layer"); f.focus(t)
            f.state("hidden", focused: false)
            Recent.press(f); f.focus(float)
            f.visible([float], true)
            f.state("shown", focused: true)
            Recent.press(f); f.focus(t)
            f.state("hidden", focused: false)
        })
    }

    @Test("#57 E7: a closed window is skipped for the next one in the history")
    func closedSkipped() {
        requireCarousel(Scenario.run("recent past a closed window") { s in
            let f = CarouselFixture(s, presets: [0.3, 0.3, 0.3], duration: 0), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            f.press("focus right"); f.focus(c)
            s.step("close b") { f.app.close(b) }
            s.settle(); f.focus(c)
            Recent.press(f); Recent.lands(f, a)
            Recent.press(f); Recent.lands(f, c)
        })
    }

    @Test("#57 E8: a minimized, hidden or fullscreen window is skipped", arguments: ["minimized", "hidden", "fullscreen"])
    func unavailableSkipped(state: String) {
        requireCarousel(Scenario.run("recent past a \(state) window") { s in
            // b belongs to its own app, so hiding it leaves a and c alone.
            let f = CarouselFixture(s, presets: [0.3, 0.3, 0.3], duration: 0, appCount: 2)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2], other = f.apps[1]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            if state == "fullscreen" {
                s.step("b enters native fullscreen") { other.enterFullscreen(b) }
                s.settle()
                s.step("click c") { f.app.select(c) }
                s.settle()
            } else {
                f.press("focus right")
                s.step("b becomes \(state)") {
                    if state == "minimized" { other.minimize(b) } else { other.hide(omitWindows: true) }
                }
                s.settle()
            }
            f.focus(c)
            s.expect("setup: b is \(state)", f.tessel.windows.first { $0.id == b }?.state.rawValue == state)
            Recent.press(f); Recent.lands(f, a)
            s.expect("b keeps its \(state) state", f.tessel.windows.first { $0.id == b }?.state.rawValue == state)
        })
    }

    @Test("#57 E9: with no other available window in the history, focus recent does nothing", arguments: ["startup", "unavailable"])
    func nothingToReturnTo(history: String) {
        requireCarousel(Scenario.run("recent without history / \(history)") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 0), a = f.ids[0], b = f.ids[1]
            f.tessel.changeConfig(CarouselFixture.config + "map = true\n[animation]\nduration = 0\n"); s.settle()
            s.expect("the map experiment loads", f.tessel.configuration.error == nil)
            f.focus(a)
            var current = a
            if history == "unavailable" {
                f.press("focus right"); f.focus(b)
                s.step("minimize a") { f.app.minimize(a) }
                s.settle(); f.focus(b)
                current = b
            }
            let status = f.tessel.status, frames = f.snapshot([current])
            f.mac.clearMapHistory(); f.mac.clearMotionHistory()
            let start = f.mac.scheduler.trace.count, effects = f.mac.focusEffects.count
            Recent.press(f)
            let trace = Array(f.mac.scheduler.trace.dropFirst(start))
            s.expect("no focus or geometry write", LayerFixture.axWrites(in: trace).isEmpty)
            s.expect("no focus effect", f.mac.focusEffects.count == effects)
            s.expect("no map is shown", f.mac.mapEvents.isEmpty)
            s.expect("the selection does not change", f.tessel.status == status)
            f.focus(current); f.unchanged(frames)
        })
    }

    @Test("#57 E10: from an empty workspace, focus recent goes to the last used window")
    func emptyWorkspace() {
        requireCarousel(Scenario.run("recent from an empty workspace") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 0), a = f.ids[0], b = f.ids[1]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            f.press("send 3"); f.focus(b)
            f.press("workspace 2")
            s.expect("setup: workspace 2 is empty", f.tessel.status.active == 2 && f.mac.visibleOrder.isEmpty)
            Recent.press(f); Recent.lands(f, b)
            s.expect("b's workspace is active", f.tessel.status.active == 3)
        })
    }

    @Test("#57 E11: a window's sheet stands for its window in the history")
    func sheet() {
        requireCarousel(Scenario.run("recent with a sheet") { s in
            let f = CarouselFixture(s, presets: [0.3, 0.3], duration: 0), a = f.ids[0], b = f.ids[1]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            f.select(a)
            let sheet = f.app.open(WindowSpec(subrole: "AXDialog", parent: a))
            s.settle()
            @MainActor func onA() {
                s.expect("a's sheet has focus (actual \(f.mac.focusedWindow.map(String.init) ?? "none"))", f.mac.focusedWindow == sheet)
                s.expect("a and its sheet are visible", f.mac.isVisible(a) && f.mac.isVisible(sheet))
                s.expect("a is not left in the closet", !f.mac.isInCloset(a))
            }
            onA()
            Recent.press(f); Recent.lands(f, b)
            Recent.press(f); onA()
            Recent.press(f); Recent.lands(f, b)
        })
    }

    @Test("#57 E12: two presses during the first animation land back on the current window")
    func doublePressDuringMotion() {
        requireCarousel(Scenario.run("recent twice during motion") { s in
            let f = CarouselFixture(s, presets: [0.6, 0.6], duration: 250), a = f.ids[0], b = f.ids[1]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            let place = f.snapshot([b])
            f.mac.clearMotionHistory()
            s.step("focus recent") { f.tessel.press("focus recent") }
            s.after(milliseconds: 100, "focus recent again during the motion") { f.tessel.press("focus recent") }
            s.settle()
            Recent.lands(f, b)
            f.unchanged(place)
            s.expect("the motion ran on the stage", f.mac.stageEvents.contains { if case .show = $0.kind { true } else { false } })
            s.expect("the last focus effect is b, got \(String(describing: f.mac.focusEffects.last?.window))", f.mac.focusEffects.last?.window == b)
            s.expect("the stage clears", f.mac.stageEvents.last?.kind == .clear)
            s.expect("no timer remains", f.mac.scheduler.pendingMainDelays.isEmpty)
        })
    }

    @Test("#57 E13: focus recent acts from a just-clicked window while its focus decision is pending")
    func pendingExternalDecision() {
        requireCarousel(Scenario.run("recent during an external focus decision", writes: .readsFirst) { s in
            let f = CarouselFixture(s, presets: [0.3, 0.3, 0.3], duration: 0), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            f.app.select(c)
            let captured = f.mac.pause(after: .read(f.app))
            if case .paused = captured {} else { s.expect("the click's focus read is captured: \(captured)", false) }
            let delivered = f.mac.deliver(f.app)
            if case .paused = delivered {} else { s.expect("the click's focus read is published: \(delivered)", false) }
            s.step("focus recent before the decision") { f.tessel.press("focus recent") }
            s.settle()
            Recent.lands(f, b)
            Recent.press(f); Recent.lands(f, c)
        })
    }

    @Test("#57 E15: focus recent is ignored while a mouse button is held")
    func pointerHeld() {
        requireCarousel(Scenario.run("recent with the pointer held") { s in
            let f = CarouselFixture(s, presets: [0.3, 0.3], duration: 0), a = f.ids[0], b = f.ids[1]
            f.focus(a)
            f.press("focus right"); f.focus(b)
            f.mac.pointerDown()
            Recent.press(f)
            f.focus(b)
            f.mac.pointerUp()
            s.settle()
            f.focus(b)
            Recent.press(f); Recent.lands(f, a)
        })
    }

    @Test("#57 E17: focus recent never selects an ignored, minimized, hidden or fullscreen window, and repeats its trace")
    func neverUnavailable() {
        func run() -> ScenarioResult {
            Scenario.run("recent never selects an unavailable window") { s in
                // m, h and z each have their own app; a and c share the first.
                let f = CarouselFixture(s, presets: [0.3, 0.3, 0.3, 0.3, 0.3], duration: 0, appCount: 4)
                let a = f.ids[0], m = f.ids[1], h = f.ids[2], z = f.ids[3], c = f.ids[4]
                let ignored = f.app.open(WindowSpec(frame: CGRect(x: 60, y: 80, width: 300, height: 200), cgLayer: 25))
                s.settle()
                s.expect("setup: the level-25 window is ignored", f.tessel.windows.first { $0.id == ignored }?.state == .ignored)
                for (app, id) in [(0, c), (3, z), (2, h), (1, m), (0, a)] {
                    s.step("select \(id)") { f.apps[app].select(id) }
                    s.settle(); f.focus(id)
                }
                // History, newest first: a, m, h, z, c. Make the three after a
                // unavailable and give the ignored window keyboard focus.
                s.step("minimize m, hide h's app, z enters fullscreen") {
                    f.apps[1].minimize(m); f.apps[2].hide(omitWindows: true); f.apps[3].enterFullscreen(z)
                }
                s.settle()
                s.step("focus the ignored window") { f.app.select(ignored) }
                s.settle()
                let unavailable: Set<UInt32> = [ignored, m, h, z]
                f.mac.clearMotionHistory()
                for (press, expected) in [(1, c), (2, a), (3, c)] {
                    Recent.press(f)
                    let focused = f.mac.focusedWindow
                    s.expect("press \(press) focuses no unavailable window (got \(String(describing: focused)))",
                             focused.map { !unavailable.contains($0) } ?? true)
                    s.expect("press \(press) leaves no focus effect on an unavailable window",
                             !f.mac.focusEffects.contains { $0.window.map(unavailable.contains) ?? false })
                    Recent.lands(f, expected)
                }
            }
        }
        let first = run(), second = run()
        requireCarousel(first)
        #expect(first.digest == second.digest, "the same history chooses the same windows with the same trace")
    }
}
