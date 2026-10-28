import CoreGraphics
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct MapRefresh {
    @Test("#18 E9: an external workspace selection clears the previous press's annotations without extending the hold",
          arguments: ["numeral", "wall"], [false, true])
    func externalWorkspaceSelectionClearsAnnotations(_ annotation: String, _ identical: Bool) {
        requireScenario(Scenario.run("map external workspace selection \(annotation) identical=\(identical)") { s in
            let f = MapFixture(s, scene: identical ? .single : .long, enabled: false, animation: 0, selection: [0])
            _ = f.app.open(WindowSpec(frame: MapFixture.area)); s.settle()
            f.key("alt-shift-2")
            if annotation == "numeral" { f.key("alt-1") }
            f.configure(animation: 0); f.mac.clearMapHistory()
            let t0 = f.mac.scheduler.now
            f.tessel.pressKey(annotation == "numeral" ? "alt-2" : "alt-h")
            s.after(milliseconds: 400, "externally select a window in workspace one") {
                f.app.select(f.rails[0][0])
            }
            s.settle()
            f.expectShown(at: t0)
            s.expect("the press annotates workspace two", annotation == "numeral"
                ? f.show(at: t0)?.workspace == 2 : f.show(at: t0)?.wall == .left)
            s.expect("external selection returns to workspace one", f.tessel.status.active == 1)
            let refreshed = f.shows.last { $0.at >= t0 + 400 && $0.at < t0 + 1000 }
            s.expect("the refresh draws workspace one's tiles", refreshed?.picture.rails.first?.spans.count == f.rails[0].count)
            s.expect("another workspace clears the previous press's numeral and wall", refreshed != nil
                && refreshed?.picture.workspace == nil && refreshed?.picture.wall == nil)
            if identical {
                s.expect("workspace identity distinguishes identical rail pictures", refreshed?.picture.rails == f.show(at: t0)?.rails
                    && refreshed?.picture.current == f.show(at: t0)?.current && refreshed?.picture.focus == f.show(at: t0)?.focus)
            }
            f.expectHide(at: t0 + 1000, fade: 0)
        })
    }

    @Test("#18 E9: an external refresh in the same workspace retains the press's numeral or wall and departure",
          arguments: ["numeral", "wall"])
    func sameWorkspaceRefreshKeepsAnnotations(_ annotation: String) {
        requireScenario(Scenario.run("map same workspace refresh \(annotation)") { s in
            let f = MapFixture(s, enabled: false, animation: 0, selection: [0])
            if annotation == "numeral" { f.key("alt-shift-2"); f.key("alt-1") }
            f.configure(animation: 0); f.mac.clearMapHistory()
            let t0 = f.mac.scheduler.now
            f.tessel.pressKey(annotation == "numeral" ? "alt-2" : "alt-h")
            s.after(milliseconds: 400, "a background float arrives in the same workspace") {
                _ = f.app.open(WindowSpec(subrole: "AXFloatingWindow"), background: true)
            }
            s.settle()
            f.expectShown(at: t0)
            let refreshed = f.shows.last { $0.at >= t0 + 400 && $0.at < t0 + 1000 }
            s.expect("the arrival redraws the same workspace with its new float", refreshed?.picture.floats == 1
                && f.tessel.status.active == (annotation == "numeral" ? 2 : 1))
            s.expect("the refresh retains the press's numeral", f.show(at: t0)?.workspace == (annotation == "numeral" ? 2 : nil)
                && refreshed?.picture.workspace == (annotation == "numeral" ? 2 : nil))
            s.expect("the refresh retains the press's wall", f.show(at: t0)?.wall == (annotation == "wall" ? .left : nil)
                && refreshed?.picture.wall == (annotation == "wall" ? .left : nil))
            f.expectHide(at: t0 + 1000, fade: 0)
        })
    }

    @Test("#18 E9: a hidden map skips picture and area work during an external publication")
    func hiddenPublicationAvoidsPictureWork() {
        requireScenario(Scenario.run("map hidden publication avoids screen reads") { s in
            let tessel = s.startTessel(text: "[experiments]\nmap = true\n")
            s.settle()
            let start = s.mac.scheduler.trace.count
            // With no windows there is no layout work. A preference notification
            // still publishes status; evaluating the map refresh would read its area.
            s.mac.setReduceMotion(true); s.settle()
            s.expect("the external notification really publishes the changed motion status", tessel.status.motion == "off: Reduce Motion")
            s.expect("a hidden publication does not evaluate the map's area", !s.mac.scheduler.trace.dropFirst(start).contains {
                $0.contains("ScreenPort.primaryScreen")
            })
            s.expect("the map remains hidden", s.mac.mapEvents.isEmpty)
            let command = s.mac.scheduler.trace.count
            tessel.pressKey("alt-2"); s.settle()
            s.expect("an effective key still reads the area and shows its map", s.mac.scheduler.trace.dropFirst(command).contains {
                $0.contains("ScreenPort.primaryScreen")
            } && s.mac.mapEvents.contains { if case .show = $0.kind { true } else { false } })
        })
    }

    @Test("#18 E9: refreshing an unchanged picture issues no redundant show and keeps the departure")
    func unchangedRefreshAvoidsRedundantShow() {
        requireScenario(Scenario.run("map unchanged refresh avoids show") { s in
            let f = MapFixture(s, animation: 0, selection: [0]), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-h")
            s.after(milliseconds: 400, "publish the same configuration and picture") {
                let publications = f.tessel.windowPublications.count
                f.configure(animation: 0)
                s.expect("the unchanged configuration still publishes its rows", f.tessel.windowPublications.count > publications)
                s.expect("the refresh does not repeat the command's show", f.shows.count == 1)
            }
            s.settle()
            f.expectShown(at: t0)
            s.expect("the unchanged picture was drawn exactly once", f.shows.count == 1 && f.show(at: t0)?.wall == .left)
            f.expectHide(at: t0 + 1000, fade: 0)
        })
    }
}
