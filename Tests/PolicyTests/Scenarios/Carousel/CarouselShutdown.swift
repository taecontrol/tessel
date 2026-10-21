import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselShutdown {
    @Test("#19 U-quit-capture-drain: quit clears the stage immediately and waits for every capture before returning windows",
          arguments: ["success", "failure", "disabled"], WriteOrder.allCases)
    func quitWaitsForInFlightCaptures(_ outcome: String, _ order: WriteOrder) {
        requireScenario(Scenario.run("quit with pending captures \(outcome)", writes: order) { s in
            let f = LayerFixture(s, duration: 250)
            f.select(f.tiles[1])
            f.mac.clearMotionHistory()
            if outcome == "failure" { f.mac.failCapture(of: f.tiles[2]) }
            let started = f.mac.scheduler.now
            f.tessel.press("focus right")
            s.expect("motion submits captures", !f.mac.stageCaptureRequests.isEmpty && f.mac.stage.capturesPending)
            s.after(milliseconds: 1, "quit while native capture replies are outstanding") {
                if outcome == "disabled" {
                    f.tessel.configure(.off)
                    s.expect("disable returns windows while the process stays alive", !f.tessel.status.enabled
                             && (f.tiles + f.floats).allSatisfy { !f.mac.isInCloset($0) })
                }
                f.tessel.quit()
                s.expect("quit waits even after a clear", f.tessel.quitCompletions == 0 && f.mac.stage.capturesPending)
                s.expect("the stage is already clear", f.mac.stageEvents.last?.kind == .clear)
                if outcome != "disabled" {
                    s.expect("quit has not finished closet cleanup", f.tessel.status.enabled && f.floats.allSatisfy { f.mac.isInCloset($0) })
                }
            }
            s.after(milliseconds: 15, "one window's reply cannot finish quit") {
                f.tessel.quit()
                s.expect("later window and backdrop replies still keep quit pending", f.mac.stage.capturesPending && f.tessel.quitCompletions == 0)
            }
            let windows = f.mac.stageCaptureRequests.flatMap { $0.windows }.count
            s.after(milliseconds: windows * 14 + 1, "the backdrop is still outstanding") {
                s.expect("quit also waits for the backdrop", f.mac.stage.capturesPending && f.tessel.quitCompletions == 0)
            }
            s.settle()
            s.expect("completion callbacks finish quit before its deadline", f.tessel.quitCompletions == 1
                     && (f.tessel.quitReadyAt ?? .max) < started + 501 && !f.mac.stage.capturesPending)
            s.expect("no late capture puts the stage back", f.mac.stageEvents.last?.kind == .clear)
            s.expect("cleanup disables management", !f.tessel.status.enabled)
            for id in f.tiles + f.floats {
                s.expect("window \(id) returns from the closet onto the desktop", !f.mac.isInCloset(id) && f.mac.isVisible(id) && f.mac.isFullyOnScreen(id))
            }
            f.tessel.quit()
            s.settle()
            s.expect("a request after captures settle cannot repeat cleanup", f.tessel.quitCompletions == 1)
        })
    }

    @Test("quit waits at most 500 ms, repeated requests do not extend it, and late captures cannot finish it twice",
          arguments: WriteOrder.allCases)
    func quitBoundsUnsettledCaptures(_ order: WriteOrder) {
        requireScenario(Scenario.run("quit deadline with pending capture", writes: order) { s in
            let f = LayerFixture(s, duration: 250)
            f.select(f.tiles[1])
            f.mac.clearMotionHistory()
            f.mac.setStageCaptureCost(milliseconds: 1_000)
            f.tessel.press("focus right")
            let began = f.mac.scheduler.now
            f.tessel.quit()
            s.expect("quit does not finish on submission", f.tessel.quitCompletions == 0)
            s.after(milliseconds: 250, "repeat quit and attempt to reload during shutdown") {
                f.tessel.quit()
                f.tessel.configure(.off)
                s.expect("a reload does not run cleanup during the wait", f.tessel.status.enabled)
            }
            s.after(milliseconds: 499, "the bound has not expired") {
                s.expect("outstanding work keeps quit pending for the full bound", f.tessel.quitCompletions == 0 && f.mac.stage.capturesPending)
            }
            s.after(milliseconds: 501, "the bound expired without a native reply") {
                s.expect("quit proceeds to cleanup at the original deadline", f.tessel.quitCompletions == 1 && f.tessel.quitReadyAt == began + 500)
                s.expect("the native request is still outstanding", f.mac.stage.capturesPending)
                s.expect("the deadline still returns every window", (f.tiles + f.floats).allSatisfy { !f.mac.isInCloset($0) && f.mac.isVisible($0) })
                f.tessel.quit()
                s.expect("repeating quit while captures remain cannot repeat cleanup", f.tessel.quitCompletions == 1 && f.tessel.quitReadyAt == began + 500)
            }
            s.settle()
            s.expect("late replies do not repeat termination", f.tessel.quitCompletions == 1 && !f.mac.stage.capturesPending)
            s.expect("late replies never restore the overlay", f.mac.stageEvents.last?.kind == .clear)
            f.tessel.quit()
            s.settle()
            s.expect("a request after the deadline cannot repeat cleanup", f.tessel.quitCompletions == 1)
        })
    }

    @Test("quit without pending capture work finishes immediately")
    func idleQuitDoesNotWait() {
        requireScenario(Scenario.run("quit without captures") { s in
            let f = LayerFixture(s, duration: 250)
            let began = f.mac.scheduler.now
            f.tessel.quit()
            s.expect("an idle quit needs no deadline", f.tessel.quitCompletions == 1 && f.tessel.quitReadyAt == began)
            f.tessel.quit()
            s.settle()
            s.expect("repeated idle quit completes only once", f.tessel.quitCompletions == 1 && f.tessel.quitReadyAt == began)
            s.expect("every managed window returns", (f.tiles + f.floats).allSatisfy { !f.mac.isInCloset($0) && f.mac.isVisible($0) })
        })
    }

    @Test("quit also waits for a resized window's refresh capture", arguments: WriteOrder.allCases)
    func quitWaitsForARefresh(_ order: WriteOrder) {
        requireScenario(Scenario.run("quit with a pending refresh", writes: order) { s in
            let f = CarouselFixture(s)
            f.mac.clearMotionHistory()
            let began = f.mac.scheduler.now
            f.tessel.pressKey("alt-r")
            // Initial captures are already submitted at the ordinary cost.
            // Only the later refresh gets this delayed async reply.
            s.after(milliseconds: 1, "delay the resized window's next capture") {
                f.mac.setStageCaptureCost(milliseconds: 200)
            }
            s.after(milliseconds: 250, "quit during the outstanding refresh") {
                s.expect("the real presenter requested one refresh", f.mac.stageCaptureRequests.filter(\.refreshing).count == 1)
                s.expect("its native reply has not arrived", f.mac.stage.capturesPending
                         && !f.mac.stageEvents.contains { if case .refresh = $0.kind { true } else { false } })
                f.tessel.quit()
                s.expect("quit leaves the refresh pending after clearing", f.tessel.quitCompletions == 0 && f.mac.stageEvents.last?.kind == .clear)
            }
            s.settle()
            s.expect("the refresh completion releases quit before the bound", f.tessel.quitCompletions == 1
                     && (f.tessel.quitReadyAt ?? 0) > began + 250 && (f.tessel.quitReadyAt ?? .max) < began + 750)
            s.expect("the late image stays discarded and all tiles return", f.mac.stageEvents.last?.kind == .clear
                     && f.ids.allSatisfy { !f.mac.isInCloset($0) && f.mac.isFullyOnScreen($0) })
        })
    }
}
