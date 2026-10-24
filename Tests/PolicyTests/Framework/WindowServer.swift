import CoreGraphics
import Ports
import Simulator
import Testing

@Suite @MainActor struct WindowServerSimulation {
    @Test("AX acceptance and the served view stay independent until the app commits", arguments: [0, 8, 20])
    func appCommit(_ delay: Int) throws {
        let mac = SimulatedMac(); defer { mac.shutdown() }
        let app = mac.launch(windows: 1), id = app.windows[0]
        app.delayCommits(milliseconds: delay)
        let ax = mac.ax, element = try #require(ax.copy(.windows, of: ax.application(app.pid)).value?.elements?.first)
        let before = try #require(mac.frame(id)), target = before.offsetBy(dx: 70, dy: 0)
        mac.beginPresentationTrace()
        let start = mac.scheduler.trace.count
        #expect(ax.set(.position, of: element, to: .point(target.origin)) == .success)
        #expect(ax.copy(.position, of: element).value?.point == target.origin)
        #expect(mac.windowOrder.listings([id])[id]?.frame == (delay == 0 ? target : before))
        if delay > 0 {
            app.hang()
            #expect(mac.settle() == .settled)
            #expect(mac.servedFrame(id) == before)
            app.resume()
        }
        #expect(mac.settle() == .settled)
        #expect(mac.windowOrder.listings([id])[id] == WindowListing(frame: target, onScreen: true))
        #expect(!mac.scheduler.trace.dropFirst(start).contains { $0.contains("SchedulingPort.after") }, "an app commit is native work, never a tessel timer")
        #expect(mac.presentationStates.contains { $0.uncommitted.contains(id) } == (delay > 0))
        app.close(id)
        #expect(mac.windowOrder.listings([id]).isEmpty)
    }

    @Test("native tab members commit together in the closet and app moves commit immediately")
    func tabsAndNativeMoves() throws {
        let mac = SimulatedMac(); defer { mac.shutdown() }
        let app = mac.launch(windows: 2), a = app.windows[0], b = app.windows[1]
        app.groupTabs([a, b], selected: a)
        let ax = mac.ax, element = try #require(ax.copy(.windows, of: ax.application(app.pid)).value?.elements?.first)
        let closet = mac.closetPort; try closet.start(); closet.hide([a])
        let before = try #require(mac.frame(a)), target = before.offsetBy(dx: 80, dy: 0)
        #expect(ax.set(.position, of: element, to: .point(target.origin)) == .success)
        app.busy(forMilliseconds: 100)
        #expect(mac.windowOrder.listings([a, b]).values.allSatisfy { $0.frame == before && !$0.onScreen })
        #expect(mac.settle() == .settled)
        #expect(mac.windowOrder.listings([a, b]).values.allSatisfy { $0.frame == target && !$0.onScreen })
        #expect(mac.windowServerCommits.last?.windows == [a, b])
        #expect(ax.set(.position, of: element, to: .point(before.origin)) == .success)
        app.moveFromApplication(a, to: CGPoint(x: 90, y: 90))
        #expect(mac.servedFrame(a) == mac.frame(a) && mac.servedFrame(b) == mac.frame(b))
        #expect(mac.settle() == .settled)
    }
}
