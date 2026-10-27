import CoreGraphics
import Foundation
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct MapLifetime {
    @Test("#18 E4: a command shows immediately and starts the default one-second hold")
    func commandShowsImmediately() {
        requireCarousel(Scenario.run("map default hold") { s in
            let f = MapFixture(s), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l"); s.settle()
            f.expectShown(at: t0); f.expectHide(at: t0 + 1000)
        })
    }

    @Test("#18 E5: a second command redraws and replaces the earlier departure")
    func repeatedCommandRestartsHold() {
        requireCarousel(Scenario.run("map repeated command") { s in
            let f = MapFixture(s), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 600, "another key during the hold") { f.tessel.pressKey("alt-l") }
            s.settle()
            f.expectShown(at: t0); f.expectShown(at: t0 + 600)
            f.expectHide(at: t0 + 1600)
        })
    }

    @Test("#18 E6: a command during the fade replaces the leaving picture and starts a fresh hold")
    func commandInterruptsFade() {
        requireCarousel(Scenario.run("map fade interrupted") { s in
            let f = MapFixture(s), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 1050, "another key inside the 120 ms fade") { f.tessel.pressKey("alt-l") }
            s.settle()
            f.expectShown(at: t0); f.expectShown(at: t0 + 1050)
            s.expect("both departures use the full hold and fade", f.hides == [
                SimulatedMac.MapEvent(at: t0 + 1000, kind: .hide(fade: 0.12)),
                SimulatedMac.MapEvent(at: t0 + 2050, kind: .hide(fade: 0.12))])
            s.expect("reappearing replaces the fade with a normal show", f.shows.contains { $0.at == t0 + 1050 && $0.transition == 0.25 })
        })
    }

    @Test("#18 E7: duration reload affects the next key and leaves the current hold unchanged")
    func durationReloadDoesNotMoveTheCurrentDeadline() {
        requireCarousel(Scenario.run("map duration captured at command") { s in
            let f = MapFixture(s, duration: 2500), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 400, "save a 300 ms hold") { f.tessel.changeConfig("[experiments]\nmap = true\n[map]\nduration = 300\n") }
            s.after(milliseconds: 2600, "the next key takes the new duration") { f.tessel.pressKey("alt-l") }
            s.settle()
            s.expect("reload accepts the new duration", f.tessel.configuration.error == nil && f.tessel.configuration.effective.map.duration == 300)
            f.expectShown(at: t0); f.expectShown(at: t0 + 2600)
            s.expect("the first departure stays at 2500 and the next uses 300", f.hides == [
                SimulatedMac.MapEvent(at: t0 + 2500, kind: .hide(fade: 0.12)),
                SimulatedMac.MapEvent(at: t0 + 2900, kind: .hide(fade: 0.12))])
        })
    }

    @Test("#18 E8: no-effect keys neither show a hidden map nor extend a visible map", arguments: ["empty-layer", "float-width", "same-workspace", "same-send", "no-focus"], [false, true])
    func noEffectKeysLeaveTheHoldAlone(_ operation: String, _ visible: Bool) {
        requireCarousel(Scenario.run("map no effect \(operation) visible=\(visible)") { s in
            let f = MapFixture(s, scene: operation == "float-width" ? .floats : .long, enabled: false)
            let noop: String, prime: String
            switch operation {
            case "float-width": f.key("alt-z"); noop = "alt-r"; prime = "alt-l"
            case "same-workspace":
                if !visible { f.key("alt-2") }
                noop = "alt-2"; prime = visible ? "alt-2" : "alt-1"
            case "same-send": f.key("alt-shift-2"); noop = "alt-shift-2"; prime = "alt-r"
            case "no-focus":
                if !visible { f.key("alt-2") }
                noop = "alt-shift-l"; prime = visible ? "alt-2" : "alt-1"
            default: noop = "alt-z"; prime = "alt-l"
            }
            f.configure(); f.mac.clearMapHistory()
            let t0 = f.mac.scheduler.now
            if visible {
                f.tessel.pressKey(prime)
                s.after(milliseconds: 600, "press a key without an effect") { f.tessel.pressKey(noop) }
                s.settle()
                f.expectShown(at: t0); f.expectHide(at: t0 + 1000)
                s.expect("a no-effect command does not redraw", !f.shows.contains { $0.at == t0 + 600 })
            } else {
                f.key(noop)
                s.expect("a no-effect command keeps the map hidden", f.mac.mapEvents.isEmpty)
                let commandAt = f.mac.scheduler.now
                f.tessel.pressKey(prime); s.settle()
                // Positive control: the recording path must be live to prove absence.
                f.expectShown(at: commandAt)
            }
        })
    }

    @Test("#18 E9: external changes stay silent while hidden and refresh a shown map without extending its hold")
    func externalChangesOnlyRefreshAnAlreadyShownMap() {
        requireCarousel(Scenario.run("map external changes") { s in
            let f = MapFixture(s, selection: [0])
            f.app.close(f.rails[0][1]); s.settle()
            let arrival = f.app.open(); s.settle()
            let other = f.mac.launch(windows: 1); s.settle()
            other.select(other.windows[0]); s.settle()
            f.app.select(arrival); s.settle()
            f.app.drag(arrival, to: CGPoint(x: 90, y: 70)); s.settle()
            s.expect("close, open, native app focus and pointer drag never show a hidden map", f.mac.mapEvents.isEmpty)
            let t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-r")
            let count = f.tessel.windows.filter { $0.state == .tiled }.count
            s.after(milliseconds: 400, "close a tile while the map is shown") { f.app.close(arrival) }
            s.settle()
            f.expectShown(at: t0); f.expectHide(at: t0 + 1000)
            s.expect("a close redraws the picture without the retired tile", f.shows.contains {
                $0.at >= t0 + 400 && $0.at < t0 + 1000 && $0.picture.rails.flatMap(\.spans).count == count - 1
            })
        })
    }

    @Test("#18 E19: removing the experiment hides immediately on reload and disables later shows")
    func flagReloadDismissesTheMap() {
        requireCarousel(Scenario.run("map flag removed") { s in
            let f = MapFixture(s), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 400, "remove the experiment flag") { f.tessel.changeConfig("") }
            s.after(milliseconds: 600, "a later key cannot bring it back") { f.tessel.pressKey("alt-l") }
            s.settle()
            f.expectShown(at: t0)
            f.expectHide(at: t0 + 430, fade: 0)
            s.expect("no map show follows flag removal", f.shows.allSatisfy { $0.at < t0 + 430 })
            s.expect("no departure timer survives", f.mac.scheduler.pendingMainDelays.isEmpty)
        })
    }

    @Test("#18 E20: losing Accessibility or quitting dismisses immediately and cancels the departure", arguments: [false, true])
    func managementEndsDismissTheMap(_ quit: Bool) {
        requireCarousel(Scenario.run("map management ends quit=\(quit)") { s in
            let f = MapFixture(s, animation: 0), t0 = f.mac.scheduler.now
            f.tessel.pressKey("alt-l")
            s.after(milliseconds: 400, "end management while the map is shown") {
                if quit { f.tessel.quit() }
                else { f.tessel.workspaces.disable(reason: "Accessibility permission needed") }
                s.expect("dismissal cancels the one-shot departure immediately", !f.mac.scheduler.pendingMainDelays.contains(1000))
            }
            s.settle()
            f.expectShown(at: t0); f.expectHide(at: t0 + 400, fade: 0)
            s.expect("no departure remains pending at rest", f.mac.scheduler.pendingMainDelays.isEmpty)
        })
    }
}
