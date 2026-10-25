import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselArrivalWidth {
    @Test("#49 E1: a new window fills an empty workspace at rail height with focus")
    func newWindowFillsEmptyWorkspace() {
        requireCarousel(Scenario.run("full-width arrival on an empty workspace") { s in
            let f = CarouselFixture(s, presets: [], duration: 0)
            let id = f.open()
            f.order([id]); f.expanded(id)
        })
    }

    @Test("#49 E2: a full-width arrival after two halves reveals minimally and one left key returns to B")
    func arrivalAfterPairRevealsAndReturnsToNeighbor() {
        requireCarousel(Scenario.run("full-width arrival after a half-width pair") { s in
            let f = CarouselFixture(s, presets: [0.5, 0.5], duration: 0), a = f.ids[0], b = f.ids[1]
            f.press("alt-l"); f.pair(a, b, focused: b)
            let id = f.open()
            f.order([a, b, id]); f.expanded(id)
            s.expect("both older halves leave the viewport", !f.mac.isVisible(a) && !f.mac.isVisible(b))
            f.press("alt-h"); f.focus(b)
            f.near(f.frame(b).minX, f.area.minX, "one left key reveals B with the smallest scroll")
            f.near(f.frame(b).width, f.width(0.5), "B keeps its nominal half width")
        })
    }

    @Test("#49 E3: a full-width arrival inserts immediately right of focus at the start of a rail")
    func arrivalInsertsRightOfFirstTile() {
        requireCarousel(Scenario.run("full-width arrival inside an existing rail") { s in
            let f = CarouselFixture(s, duration: 0), a = f.ids[0]
            f.focus(a)
            let id = f.open()
            f.order([a, id, f.ids[1], f.ids[2]]); f.expanded(id)
        })
    }

    @Test("#49 E4: a new full-width window cycles through third, half, two thirds and full")
    func newWindowCyclesFromFull() {
        requireCarousel(Scenario.run("width cycle starts from a new full-width window") { s in
            let f = CarouselFixture(s, presets: [], duration: 0), id = f.open()
            f.near(f.frame(id).width, f.width(1), "arrival starts at full width")
            for preset in [1.0 / 3, 0.5, 2.0 / 3, 1] {
                f.press("alt-r")
                f.near(f.frame(id).width, f.width(preset), "next preset is \(preset)")
                f.near(f.frame(id).minX, f.area.minX, "the singleton stays left aligned")
                f.focus(id)
            }
        })
    }

    @Test("#49 E5: a 740-point arrival keeps its exact maximum and occupies exactly that rail slot")
    func limitedArrivalUsesExactMaximumAndSlot() {
        requireCarousel(Scenario.run("740-point arrival and its neighboring rail slot") { s in
            let f = CarouselFixture(s, presets: [], duration: 0)
            s.expect("a third of this fixture area is below the app maximum", f.width(1.0 / 3) < 740)
            let id = f.open(maximum: 740)
            f.near(f.frame(id).width, 740, "arrival uses the app maximum instead of a smaller preset")
            f.near(f.frame(id).minX, f.area.minX, "the limited arrival is left aligned")
            // A third-width neighbor fits beside 740, so native positions
            // expose the nominal slot without clipping or closet parking.
            let next = f.open(maximum: f.width(1.0 / 3))
            f.select(id); f.order([id, next]); f.focus(id)
            s.expect("both slots are visible", f.mac.isVisible(id) && f.mac.isVisible(next))
            f.near(f.frame(id).width, 740, "adding a neighbor retains the exact maximum")
            f.near(f.frame(next).minX - f.frame(id).minX - 10, 740, "the nominal rail slot is exactly 740 points")
            f.near(f.frame(next).minX - f.frame(id).maxX, 10, "only the configured gap precedes the next tile")
        })
    }

    @Test("#49 E6: an arrival limited between half and two thirds uses its exact 1000-point maximum")
    func limitedArrivalDoesNotStopAtHalf() {
        requireCarousel(Scenario.run("1000-point maximum exceeds the old arrival preset") { s in
            let f = CarouselFixture(s, presets: [], duration: 0)
            s.expect("the maximum lies between half and two thirds", f.width(0.5) < 1000 && 1000 < f.width(2.0 / 3))
            let id = f.open(maximum: 1000)
            f.near(f.frame(id).width, 1000, "arrival reaches the exact app maximum")
            f.near(f.frame(id).minX, f.area.minX, "the limited singleton is left aligned")
            f.focus(id)
        })
    }

    @Test("#49 E7: cycling a 740-point arrival selects the only fitting third and stays there")
    func limitedArrivalCyclesOnlyFittingPreset() {
        requireCarousel(Scenario.run("cycle from an exact 740-point arrival") { s in
            let f = CarouselFixture(s, presets: [], duration: 0), id = f.open(maximum: 740)
            f.near(f.frame(id).width, 740, "the limited arrival starts at its exact maximum")
            for _ in 0..<4 {
                f.press("alt-r")
                f.near(f.frame(id).width, f.width(1.0 / 3), "only a third fits the learned maximum")
                f.focus(id)
            }
        })
    }

    @Test("#49 E8: an app resizing a placed full-width arrival is returned to full width")
    func applicationResizeCannotReplaceArrivalWidth() {
        requireCarousel(Scenario.run("application redraw after a full-width arrival") { s in
            let f = CarouselFixture(s, presets: [], duration: 0), id = f.open()
            f.near(f.frame(id).width, f.width(1), "the new window has already landed at full width")
            f.mac.clearMotionHistory()
            f.app.resizeFromApplication(id, to: CGSize(width: 600, height: 400)); s.settle()
            f.expanded(id)
            s.expect("tessel corrects the unsolicited app size", f.mac.geometryWrites.contains {
                $0.window == id && $0.attribute == .size && Double($0.requested.size?.width ?? -1) == f.width(1)
            })
        })
    }

    @Test("#49 E9: windows present at startup retain their observed widths")
    func initialWindowsKeepObservedWidths() {
        requireCarousel(Scenario.run("existing windows keep nonpreset widths") { s in
            let widths = [0.4, 0.72]
            let f = CarouselFixture(s, presets: widths, duration: 0)
            f.order(f.ids)
            for (id, fraction) in zip(f.ids, widths) {
                f.select(id); f.focus(id)
                f.near(f.frame(id).width, f.width(fraction), "startup retains the observed nonpreset width")
            }
        })
    }

    @Test("#49 E10: minimized, hidden, closeted and native-fullscreen windows recover their previous width",
          arguments: ["minimized", "hidden", "closet", "fullscreen"])
    func restoredWindowKeepsPreviousWidth(_ path: String) {
        requireCarousel(Scenario.run("restore a nonpreset width from \(path)") { s in
            let f = CarouselFixture(s, presets: [0.43], duration: 0), id = f.ids[0]
            let width = f.frame(id).width
            switch path {
            case "minimized":
                f.app.minimize(id); s.settle()
                s.expect("the window is minimized before restoration", f.tessel.windows.first { $0.id == id }?.state == .minimized)
                f.app.restore(id)
            case "hidden":
                f.app.hide(omitWindows: true); s.settle()
                s.expect("the app is hidden before restoration", f.tessel.windows.first { $0.id == id }?.state == .hidden)
                f.app.unhide(); f.app.select(id)
            case "closet":
                f.press("alt-2")
                s.expect("the window is in the closet before restoration", f.mac.isInCloset(id))
                f.press("alt-1")
            default:
                f.app.enterFullscreen(id); s.settle()
                s.expect("native fullscreen has no rail membership", f.tessel.windows.first { $0.id == id }?.state == .fullscreen
                         && f.tessel.windows.first { $0.id == id }?.rail == nil)
                f.app.leaveFullscreen(id)
            }
            s.settle(); f.order([id]); f.focus(id)
            f.near(f.frame(id).width, width, "restoration preserves the previous nonpreset width")
        })
    }

    @Test("#49 E11: Option-F moves a float into the rail at the preset nearest its observed width",
          arguments: [0, 1, 2, 3])
    func floatTransferChoosesNearestPreset(_ choice: Int) {
        requireCarousel(Scenario.run("float transfer width choice \(choice)") { s in
            let f = CarouselFixture(s, presets: [], duration: 0)
            let fractions = [0.36, 0.54, 0.70, 0.96], presets = [1.0 / 3, 0.5, 2.0 / 3, 1]
            let id = f.app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: f.area.width * fractions[choice], height: 300), subrole: "AXDialog"))
            s.settle()
            s.expect("the window starts in the floating layer", f.tessel.windows.first { $0.id == id }?.state == .floats
                     && f.tessel.windows.first { $0.id == id }?.rail == nil)
            f.press("alt-f"); f.order([id]); f.focus(id)
            f.near(f.frame(id).width, f.width(presets[choice]), "manual transfer chooses the nearest preset")
        })
    }

    @Test("#49 E12: new dialogs, sheets and fixed-size windows remain outside the rail without resizing",
          arguments: ["dialog", "sheet", "fixed"])
    func newFloatKeepsItsSize(_ kind: String) {
        requireCarousel(Scenario.run("new \(kind) stays outside the rail") { s in
            let f = CarouselFixture(s, presets: [0.5], duration: 0)
            let original = CGRect(x: 100, y: 100, width: 451, height: 300)
            f.mac.clearMotionHistory()
            let id = f.app.open(WindowSpec(frame: original, subrole: kind == "fixed" ? "AXStandardWindow" : "AXDialog",
                                           resizable: kind != "fixed", parent: kind == "sheet" ? f.ids[0] : nil))
            s.settle()
            let row = f.tessel.windows.first { $0.id == id }
            s.expect("the new window floats without a rail or slot", row?.state == .floats && row?.rail == nil && row?.slot == nil)
            f.order(f.ids)
            s.expect("the app's original size is unchanged", f.frame(id).size == original.size)
            s.expect("tessel never requests a size for the float", !f.mac.geometryWrites.contains { $0.window == id && $0.attribute == .size })
        })
    }

    @Test("#49 E13: a known window entering its first rail retains its observed width")
    func knownWindowEnteringFirstRailKeepsObservedWidth() {
        requireCarousel(Scenario.run("first rail entry after an earlier minimized observation") { s in
            let f = CarouselFixture(s, presets: [], duration: 0)
            let observed = CGRect(x: 40, y: 60, width: 713, height: 400)
            // First observe the new window while minimized: it is known to
            // tessel but has never had a rail tile or a suspended rail width.
            let id = f.app.open(WindowSpec(frame: observed, positionAcceptance: .screenEdges))
            f.app.minimize(id); s.settle()
            let row = f.tessel.windows.first { $0.id == id }
            s.expect("the first observation is known without rail membership", row?.state == .minimized && row?.rail == nil)
            f.near(f.frame(id).width, observed.width, "the first observation retains the app width")
            f.app.restore(id); s.settle()
            f.order([id]); f.focus(id)
            f.near(f.frame(id).width, observed.width, "first rail entry retains the known nonpreset width")
        })
    }

    @Test("#49 E14: opening preserves every older tile's nominal width and relative order", arguments: [0, 1, 3])
    func arrivalPreservesOlderWidthsAndOrder(_ focused: Int) {
        requireCarousel(Scenario.run("arrival preserves mixed widths after slot \(focused + 1)") { s in
            let presets = [1.0 / 3, 0.5, 2.0 / 3, 1]
            let f = CarouselFixture(s, presets: presets, duration: 0)
            f.select(f.ids[focused])
            let id = f.open()
            let expected = Array(f.ids.prefix(focused + 1)) + [id] + Array(f.ids.dropFirst(focused + 1))
            f.order(expected); f.focus(id)
            for (oldID, preset) in zip(f.ids, presets) {
                // Reveal every older tile so stale frames of parked windows
                // cannot stand in for the rail's retained nominal widths.
                f.select(oldID); f.focus(oldID)
                f.near(f.frame(oldID).width, f.width(preset), "the older tile keeps its nominal width")
                f.order(expected)
            }
        })
    }
}
