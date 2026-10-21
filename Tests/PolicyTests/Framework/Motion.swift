import CoreGraphics
import Ports
import Simulator
import Testing

@Suite @MainActor struct MotionSimulation {
    @Test("the stage captures serially, shows a frame after its captures, settles early, and a clear drops late work")
    func stageSimulation() {
        let mac = SimulatedMac(); defer { mac.shutdown() }
        let app = mac.launch(); let a = app.open(), b = app.open()
        let stage = mac.stage
        #expect(stage.available)
        var shown: [Bool] = [], settled = 0
        stage.capture([a, b], background: [a, b], foreground: [])
        stage.show([a: .zero, b: .zero]) { shown.append($0) }
        mac.settle()
        // Two windows then the background, 14 ms each; the overlay draws a frame later.
        #expect(mac.stageEvents.map(\.at) == [14, 28, 70, 86])
        #expect(shown == [true])
        stage.move([a: CGRect(x: 10, y: 0, width: 1, height: 1)], entering: [:], duration: 0.25) { settled += 1 }
        mac.settle()
        #expect(settled == 1 && mac.stageEvents.last?.kind == .settled && mac.stageEvents.last?.at == 86 + 175)
        stage.capture([b], background: nil, foreground: [])
        stage.capture([b], background: [b], foreground: [])
        stage.refresh(a)
        stage.clear()
        mac.settle()
        #expect(mac.stageEvents.last?.kind == .clear)
        // Requests survive deduplication and cancellation, including a second
        // background request and a refresh that never completes.
        #expect(mac.stageCaptureRequests.map(\.windows) == [Set([a, b]), [b], [b], [a]])
        #expect(mac.stageCaptureRequests.compactMap(\.backgroundExcluding) == [Set([a, b]), [b]])
        #expect(mac.stageCaptureRequests.map(\.refreshing) == [false, false, false, true])
        mac.failCapture(of: a)
        stage.capture([a], background: nil, foreground: [])
        stage.show([a: .zero]) { shown.append($0) }
        mac.settle()
        #expect(shown == [true, false])
        mac.setScreenRecording(false)
        #expect(!stage.available)
    }
    @Test("Reduce Motion reads native state and change notifications stop with token lifetime")
    func motionPreferenceNotifications() {
        let mac = SimulatedMac(); defer { mac.shutdown() }
        let preferences = mac.motionPreferences
        var values: [Bool] = []
        var token: (any MotionPreferenceObservation)? = preferences.observe { values.append($0) }
        #expect(!preferences.reduceMotion)
        mac.setReduceMotion(true); mac.settle()
        #expect(values == [true] && preferences.reduceMotion)
        withExtendedLifetime(token) {}
        token = nil
        mac.setReduceMotion(false); mac.settle()
        #expect(values == [true] && !preferences.reduceMotion)
    }
    @Test("native AX clamps screen edges, preserves closet identity and exposes short hidden size writes")
    func nativeGeometryAndClosetHazards() throws {
        let mac = SimulatedMac(); defer { mac.shutdown() }
        let a = mac.launch(), b = mac.launch()
        var spec = WindowSpec(positionAcceptance: .screenEdges); spec.closetHeightLoss = 100
        let id = a.open(spec), front = b.open()
        let ax = mac.ax, root = ax.copy(.windows, of: ax.application(a.pid)).value!.elements!.first!
        for (point, accepted) in [(CGPoint(x:1023,y:-100),CGPoint(x:1023,y:31)),
                                  (CGPoint(x:1024,y:1000),CGPoint(x:984,y:736)),
                                  (CGPoint(x:-450,y:60),CGPoint(x:-450,y:60)),
                                  (CGPoint(x:-451,y:60),CGPoint(x:-411,y:60))] {
            #expect(ax.set(.position, of: root, to: .point(point)) == .success)
            #expect(mac.frame(id)?.origin == accepted)
        }
        #expect(ax.perform(.raise, on: root) == .success)
        #expect(mac.frontmostApp == b.pid && mac.focusedWindow == front)
        #expect(mac.windowOrder.onScreenOrder().prefix(2) == [front,id])
        let anchor = mac.launch(); _ = anchor.open()
        #expect(ax.perform(.raise, on: root) == .success)
        #expect(mac.frontmostApp == anchor.pid)
        #expect(mac.windowOrder.onScreenOrder().filter { [id,front].contains($0) } == [id,front])
        let closet = mac.closetPort; try closet.start(); closet.hide([id])
        #expect(ax.set(.position, of: root, to: .point(CGPoint(x:50,y:60))) == .success)
        #expect(ax.set(.size, of: root, to: .size(CGSize(width:500,height:600))) == .success)
        closet.show([id])
        let next = ax.copy(.windows, of: ax.application(a.pid)).value!.elements!.first!
        #expect(root == next && mac.frame(id)?.origin == CGPoint(x:50,y:60))
        #expect(mac.frame(id)?.height == 500)
        closet.stop(returning: [id]); mac.settle()
    }
}

@Suite struct CarouselOracleIntegrity {
    @Test("the coverage oracle rejects no windows, an interior hole, and an uncovered screen edge")
    func coverageHasNegativeControls() {
        let area = CGRect(x:10,y:43,width:1708,height:1064)
        #expect(uncoveredWidths(in:area,coveredBy:[]).max() == 1708)
        let left = CGRect(x:10,y:43,width:849,height:1064)
        let right = CGRect(x:869,y:43,width:849,height:1064)
        #expect(uncoveredWidths(in:area,coveredBy:[left,right]).allSatisfy { $0 <= 10 })
        #expect(uncoveredWidths(in:area,coveredBy:[left]).contains { $0 > 10 })
        #expect(uncoveredWidths(in:area,coveredBy:[left,right.offsetBy(dx:50,dy:0)]).contains { $0 > 10 })
    }
}
