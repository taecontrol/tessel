import CoreGraphics
import Foundation
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct ResizeInstantAcceptance {
    @Test("#33 E1: the absent configuration manages rails and the floating layer with layer shortcuts")
    func defaultsManageWindows() {
        requireCarousel(Scenario.run("default installation") { s in
            let app = s.mac.launch()
            let tile = app.open(), float = app.open(WindowSpec(subrole: "AXDialog"))
            app.select(tile)
            let t = s.startTessel(); s.settle()
            s.expect("default rails and layer are active", t.status.enabled && t.status.layout == "carousel" && t.status.layer?.state == "hidden")
            s.expect("default key map is the layer map", t.status.keys == KeyChord.layerDefaults)
            s.expect("tiles have membership and floats start hidden", t.windows.first { $0.id == tile }?.rail == 1 && s.mac.isInCloset(float))
            let json = encodedObject(t.status)
            s.expect("status never reports the retired layout or disabled mode", json["layout"] as? String == "carousel" && json["reason"] as? String != "experiment off")
        })
    }

    @Test("#33 E2: every legacy flag combination has the same behavior as an empty config")
    func legacyFlagsAreInert() throws {
        for bits in 0..<8 {
            let text = "[experiments]\nworkspaces = \(bits & 1 != 0)\ncarousel = \(bits & 2 != 0)\nlayer = \(bits & 4 != 0)\n"
            let config = try ConfigParser.parse(Data(text.utf8))
            #expect(config == (try ConfigParser.parse(Data())))
            requireCarousel(Scenario.run("legacy flags \(bits)") { s in
                let app = s.mac.launch(windows: 1), t = s.startTessel(text: text); s.settle()
                s.expect("legacy flags retain rails and hidden layer", t.status.enabled && t.status.layout == "carousel" && t.status.layer?.state == "hidden")
                s.expect("a managed rail exists", t.windows.first { $0.id == app.windows.first }?.rail == 1)
            })
        }
    }

    @Test("#33 E3: an unknown experiment remains a line-numbered error")
    func unknownExperimentHasALineNumber() {
        #expect(throws: ConfigError.self) { try ConfigParser.parse(Data("[experiments]\nunknown = true\n".utf8)) }
        do { _ = try ConfigParser.parse(Data("[experiments]\nunknown = true\n".utf8)) }
        catch let error as ConfigError { #expect(error.line == 2 && error.message == "Unknown configuration key") }
        catch { Issue.record("unexpected error: \(error)") }
    }

    @Test("#33 E5: a singleton cycles exact third, half, two-thirds and full without stretching")
    func singletonPresetsLeaveSpace() {
        requireCarousel(Scenario.run("short singleton widths") { s in
            let f = CarouselFixture(s, presets: [1], duration: 0), id = f.ids[0]
            for preset in [1.0 / 3, 0.5, 2.0 / 3, 1] {
                f.press("alt-r")
                f.near(f.frame(id).width, f.width(preset), "exact nominal width")
                f.near(f.frame(id).minX, f.area.minX, "left aligned")
            }
        })
    }

    @Test("#33 E6: a short mixed rail retains its nominal widths and a trailing empty area")
    func shortMixedRailDoesNotStretch() {
        requireCarousel(Scenario.run("third plus half") { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 0.5], duration: 0)
            f.near(f.frame(f.ids[0]).width, f.width(1.0 / 3), "third stays a third")
            f.near(f.frame(f.ids[1]).width, f.width(0.5), "half stays a half")
            f.near(f.frame(f.ids[1]).minX, f.area.minX + f.width(1.0 / 3) + 10, "nominal adjacency")
            s.expect("trailing space remains", f.frame(f.ids[1]).maxX < f.area.maxX - 100)
        })
    }

    @Test("#33 E7: enhanced UI cannot lose a preset or poison width learning")
    func enhancedUIReachesEveryPreset() {
        requireCarousel(Scenario.run("enhanced UI measured size loss") { s in
            let f = CarouselFixture(s, presets: [1], duration: 0), id = f.ids[0]
            _ = f.mac.ax.set(.enhancedUserInterface, of: f.mac.ax.application(f.app.pid), to: .bool(true))
            for preset in [1.0 / 3, 0.5, 2.0 / 3, 1, 1.0 / 3, 0.5, 2.0 / 3, 1] {
                f.press("alt-r")
                f.near(f.frame(id).width, f.width(preset), "enhanced UI requested preset lands")
                s.expect("the application preference is restored", f.mac.ax.copy(.enhancedUserInterface, of: f.mac.ax.application(f.app.pid)).value?.bool == true)
            }
        })
    }

    @Test("#33 E7: a late application resize cannot become an adopted mouse width")
    func lateApplicationResizeDoesNotBecomeMouseInput() {
        requireCarousel(Scenario.run("late enhanced-UI redraw") { s in
            let f = CarouselFixture(s, presets: [0.5], duration: 0), id = f.ids[0]
            f.press("alt-r")
            f.app.resizeFromApplication(id, to: CGSize(width: f.width(0.5), height: f.area.height)); s.settle()
            f.near(f.frame(id).width, f.width(2.0 / 3), "an unprompted app redraw preserves the selected preset")
            f.press("alt-r"); f.near(f.frame(id).width, f.area.width, "the late redraw does not poison width learning")
        })
    }

    @Test("#33 E9: a larger accepted mouse width releases an obsolete learned maximum")
    func mouseWidthReleasesLearnedMaximum() {
        requireCarousel(Scenario.run("forget a contradicted maximum") { s in
            let f = CarouselFixture(s, presets: [0.5], duration: 0), id = f.ids[0]
            f.app.limitSize(id, maximum: CGSize(width: 1000, height: 100_000))
            f.press("alt-r") // Learns 1000; the next accepted preset is a third.
            f.app.limitSize(id, maximum: CGSize(width: 100_000, height: 100_000))
            f.app.resize(id, to: CGSize(width: 1200, height: f.area.height)); s.settle()
            f.near(f.frame(id).width, 1200, "the accepted user width survives")
            f.press("alt-r")
            f.near(f.frame(id).width, f.area.width, "the full preset is available again")
        })
    }

    @Test("#33 E10: a 500-point minimum skips a smaller third")
    func minimumSkipsTheThird() {
        requireCarousel(Scenario.run("Chrome-sized minimum on a narrow display") { s in
            s.mac.setScreen(ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1200, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 870)))
            let app = s.mac.launch(), area = WorkspaceScenarios.area(s.mac)
            let id = app.open(WindowSpec(frame: area, minimumSize: CGSize(width: 500, height: 1)))
            let t = s.startTessel(text: "[experiments]\nlayer = true\n[animation]\nduration = 0\n"); s.settle()
            t.press("cycle width"); s.settle()
            s.expect("the rejected third advances to the next accepted half", abs((s.mac.frame(id)?.width ?? 0) - ((area.width + 10) / 2 - 10)) <= 1)
            s.mac.clearMotionHistory()
            for _ in 0..<4 { t.press("cycle width"); s.settle() }
            s.expect("a known rejected third is not retried", s.mac.geometryWrites.filter { $0.attribute == .size }.allSatisfy { ($0.requested.size?.width ?? 0) >= 500 })
        })
    }

    @Test("#33 E11; #33 E12; #33 E13; #33 E14: a held drag owns geometry, then reconciles once", arguments: ["right", "left", "height", "first-left"], [0, 250])
    func dragOwnsGeometryUntilRelease(_ edge: String, _ duration: Int) {
        requireCarousel(Scenario.run("twenty-step \(edge) drag") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5, 0.5], duration: duration), id = f.ids[edge == "first-left" ? 0 : 1]
            if edge != "first-left" { f.press("alt-l") }
            let start = f.frame(id)
            f.mac.clearMotionHistory(); f.mac.pointerDown()
            for step in 1...20 {
                let dx = Double(step) * 5
                if edge == "left" { f.app.drag(id, to: CGPoint(x: start.minX - dx, y: start.minY)) }
                if edge == "first-left" { f.app.drag(id, to: CGPoint(x: start.minX + dx, y: start.minY)) }
                f.app.resize(id, to: CGSize(width: start.width + (edge == "height" ? 0 : edge == "first-left" ? -dx : dx), height: start.height - Double(step) * 2))
                s.settle()
                s.expect("no geometry, main, focus, raise, capture or stage during held step \(step)", f.mac.geometryWrites.isEmpty && f.mac.focusRequests.isEmpty && f.mac.focusEffects.isEmpty && f.mac.stageEvents.isEmpty)
            }
            let released = f.frame(id)
            f.mac.clearMotionHistory(); f.mac.pointerUp(); s.settle()
            f.near(f.frame(id).width, released.width, "accepted width survives release")
            f.near(f.frame(id).minX, edge == "first-left" ? f.area.minX : released.minX, "released left edge survives unless first-tile left alignment wins")
            f.near(f.frame(id).height, f.area.height, "height returns to rail")
            let sizes = f.mac.geometryWrites.filter { $0.window == id && $0.attribute == .size }
            s.expect("height is restored with exactly one size write", sizes.count == 1)
            for tile in f.ids {
                for attribute in [AXAttribute.size, .position] {
                    s.expect("one placement per window and attribute", f.mac.geometryWrites.filter { $0.window == tile && $0.attribute == attribute }.count <= 1)
                }
            }
            let visible = f.ids.filter { f.mac.isVisible($0) }.map { f.frame($0) }.sorted { $0.minX < $1.minX }
            s.expect("neighbors no longer overlap", zip(visible, visible.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 1 })
        })
    }

    @Test("#33 E11; #33 E12; #33 E13; #33 E14: a delayed drag notification and failed release read retain mouse geometry", arguments: ["right", "left", "height", "first-left"])
    func failedReleaseReadRetainsMouseGeometry(_ edge: String) {
        requireCarousel(Scenario.run("failed first release read after \(edge) drag") { s in
            let f = CarouselFixture(s, duration: 0), id = f.ids[edge == "first-left" ? 0 : 1]
            if edge != "first-left" { f.press("alt-l") }
            let start = f.frame(id)
            f.mac.pointerDown()
            if edge == "left" { f.app.drag(id, to: CGPoint(x: start.minX - 100, y: start.minY)) }
            if edge == "first-left" { f.app.drag(id, to: CGPoint(x: start.minX + 100, y: start.minY)) }
            f.app.resize(id, to: CGSize(width: start.width + (edge == "height" ? 0 : edge == "first-left" ? -100 : 100), height: start.height - 40))
            let released = f.frame(id)
            // Mouse-up precedes the debounced final publication. The first
            // fresh read times out; only a later retry can know this width.
            f.app.busy(forMilliseconds: 100)
            f.mac.clearMotionHistory(); f.mac.pointerUp(); s.settle()
            f.near(f.frame(id).width, released.width, "a fresh successful snapshot adopts the accepted mouse width")
            f.near(f.frame(id).minX, edge == "first-left" ? f.area.minX : released.minX, "the released left edge survives")
            f.near(f.frame(id).height, f.area.height, "release restores rail height")
            for tile in f.ids {
                for attribute in [AXAttribute.size, .position] {
                    s.expect("release reconciles each attribute once", f.mac.geometryWrites.filter { $0.window == tile && $0.attribute == attribute }.count <= 1)
                }
            }
        })
    }

    @Test("#33 E12: release follows the tile selected by the drag before the first key")
    func dragSelectionOwnsTheNextKey() {
        requireCarousel(Scenario.run("drag selects a previously unfocused tile") { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3], duration: 0), a = f.ids[0], b = f.ids[1]
            let original = f.frame(a)
            f.mac.pointerDown(); f.app.select(b)
            f.app.resize(b, to: CGSize(width: 600, height: f.area.height - 30)); s.settle()
            f.mac.pointerUp(); s.settle()
            f.near(f.frame(b).width, 600, "the newly selected tile keeps the mouse width")
            f.press("alt-r"); f.focus(b)
            f.near(f.frame(b).width, f.width(0.5), "the first key cycles the native selection")
            f.near(f.frame(a).width, original.width, "the previously selected tile keeps its width")
        })
    }

    @Test("#33 E11; #33 E12: closing a nonfocused tile during a hold defers one layout until release")
    func pointerReleaseRendersDeferredClosure() {
        requireCarousel(Scenario.run("close a nonfocused tile while pointer held") { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 0)
            let a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.mac.clearMotionHistory(); f.mac.pointerDown()
            f.app.close(b, selecting: a); s.settle()
            s.expect("closure never writes geometry during the hold", f.mac.geometryWrites.isEmpty)
            f.mac.pointerUp(); s.settle()
            f.near(f.frame(c).minX, f.frame(a).maxX + 10, "the remaining neighbor fills the closed tile's slot")
            f.focus(a)
            s.expect("the deferred neighbor is placed exactly once", f.mac.geometryWrites.filter { $0.window == c && $0.attribute == .position }.count == 1)
        })
    }

    @Test("#2 E15: a close during a held pointer retains the current workspace at release")
    func pointerReleaseReconcilesAClosedSelection() {
        requireCarousel(Scenario.run("close a tile before mouse-up") { s in
            let f = CarouselFixture(s, presets: [1.0 / 3, 1.0 / 3, 1.0 / 3], duration: 0), a = f.ids[0], b = f.ids[1], c = f.ids[2]
            f.select(c); f.press("send 2"); f.press("workspace 1"); f.select(a)
            f.mac.pointerDown(); f.app.close(a, selecting: c); s.settle()
            f.mac.pointerUp(); s.settle()
            f.focus(b)
            s.expect("native promotion cannot follow the hidden workspace", f.tessel.status.active == 1)
        })
    }

    @Test("#33 E16: duration zero never consults Screen Recording or creates a stage")
    func instantPathNeverAsksForCapture() {
        requireCarousel(Scenario.run("instant has no capture permission dependency") { s in
            let f = CarouselFixture(s, duration: 0)
            f.mac.clearMotionHistory()
            let from = f.mac.scheduler.trace.count
            f.press("alt-r"); f.press("alt-l")
            s.expect("no screen recording preflight", !f.mac.scheduler.trace.dropFirst(from).contains { $0.contains("MotionStagePort.available") || $0.contains("MotionStagePort.requestAccess") })
            s.expect("no stage operation", f.mac.stageEvents.isEmpty)
        })
    }

    @Test("#33 E17: disabling motion clears an in-flight stage immediately", arguments: [false, true])
    func motionOffInterruptsTheCurrentStage(_ reduced: Bool) {
        requireCarousel(Scenario.run("interrupt motion with \(reduced ? "Reduce Motion" : "duration zero")") { s in
            let f = CarouselFixture(s, duration: 1000)
            f.tessel.press("cycle width")
            s.after(milliseconds: 200, "turn motion off") {
                if reduced { f.mac.setReduceMotion(true) }
                else { f.tessel.changeConfig(CarouselFixture.config + "[animation]\nduration = 0\n") }
            }
            s.after(milliseconds: 260, "observe immediate clearing after preference delivery or reload debounce") {
                s.expect("the stage cleared before the old animation could settle", f.mac.stageEvents.contains { if case .clear = $0.kind { true } else { false } })
                f.near(f.frame(f.ids[0]).width, f.width(2.0 / 3), "final native frame is already placed")
            }
            s.settle()
        })
    }
}
