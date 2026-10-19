import Foundation
import Testing

extension Acceptance.Contracts {
    @Test("ax-resize-anchoring: moving left before growing avoids a false width maximum", contract(.axResizeAnchoring))
    func resizeUsesTheCurrentScreenPosition() throws {
        let id = try fixture.open(); _ = try window(id)
        let screen = try native("screen"), full = try #require(screen.screen), area = try #require(screen.axVisibleFrame)
        let size = [full[2] - 20, 300.0], y = area[1] + 10
        try #require(try write(id, "AXPosition", [200, y]) == 0)
        try #require(try write(id, "AXSize", size) == 0)
        try requireFinalState("the old positive x constrains the requested width") {
            let frame = try native("retained", ["id": id]).window?.frame ?? []
            return frame.count == 4 && abs(frame[2] - (full[2] - 200)) <= 1
        }
        try #require(try write(id, "AXPosition", [10, y]) == 0)
        try #require(try write(id, "AXSize", size) == 0)
        try requireFinalState("moving first accepts the full requested width") {
            let frame = try native("retained", ["id": id]).window?.frame ?? []
            return frame.count == 4 && abs(frame[0] - 10) <= 1 && abs(frame[2] - size[0]) <= 1
        }
    }

    @Test("pointer-press-notifications: a global monitor receives a press in another fixture app", contract(.pointerPressNotifications))
    func pointerPressInterruptsBeforeDragging() throws {
        let id = try fixture.open(); _ = try window(id)
        try desktop.activate()
        try native("pointerStart")
        try native("pointerPress", ["id": id])
        try requireFinalState("the independent mouse-down monitor receives the fixture press") {
            let facts = try native("pointerSamples")
            return facts.pointerPresses == 1 && facts.pointerEvents == ["press", "drag"]
        }
    }
    @Test("ax-vertical-clamping: AX keeps the top below the menu bar and 32 points visible at the bottom", contract(.axVerticalClamping))
    func axVerticalClamping() throws {
        let id = try fixture.open(); let original = try window(id)
        let screen = try native("screen"), full = try #require(screen.screen), visible = try #require(screen.axVisibleFrame)
        for (requested, expected) in [(-200.0, visible[1]), (full[3] + 200, full[3] - 32)] {
            try #require(try write(id,"AXPosition",[original.frame[0],requested]) == 0)
            try requireFinalState("the native vertical clamp") {
                let frame = try native("retained",["id":id]).window?.frame ?? []
                return frame.count == 4 && abs(frame[1] - expected) <= 1
            }
        }
    }

    @Test("ax-horizontal-sliver: one point is accepted and wholly off-screen writes snap to forty points", contract(.axHorizontalSliver))
    func axHorizontalSliver() throws {
        let id = try fixture.open(); let original = try window(id)
        let full = try #require(try native("screen").screen), right = full[0] + full[2], width = original.frame[2]
        for (requested, expected) in [(right-1,right-1), (right,right-40), (full[0]-width+1,full[0]-width+1), (full[0]-width,full[0]-width+40)] {
            try #require(try write(id,"AXPosition",[requested,original.frame[1]]) == 0)
            try requireFinalState("the native horizontal sliver rule") {
                let x = try native("retained",["id":id]).window?.frame.first
                return x.map { abs($0 - expected) <= 1 } == true
            }
        }
    }

    @Test("ax-raise-across-applications: background windows reorder without activation while the active app retains its window order", contract(.axRaiseAcrossApplications))
    func raiseAcrossApplicationsWithoutActivation() throws {
        let a = try fixture.open(key:"a"), second = try other(), b = try second.open(key:"b")
        _ = try window(a); _ = try window(b,session:second)
        try desktop.activate(second,key:"b")
        try expectFocus(b,session:second)
        try #require(try write(a,"AXRaise") == 0)
        try requireFinalState("a frontmost regular app keeps its window above the raised background window") {
            let observation = try desktop.observe()
            return observation.frontmostFixturePID == second.pid && observation.visibleIDs.filter { [a,b].contains($0) } == [b,a]
        }
        let anchor = try other()
        _ = try anchor.open(key:"anchor")
        try desktop.activate(anchor,key:"anchor")
        try #require(try write(a,"AXRaise") == 0)
        var frontWasDestination = false, order: [UInt32] = []
        let raised = try finalState {
            let observation = try desktop.observe()
            frontWasDestination = observation.frontmostFixturePID == anchor.pid
            order = observation.visibleIDs.filter { [a,b].contains($0) }
            return frontWasDestination && order == [a,b]
        }
        try #require(raised,"AXRaise must order background then active window without activation; actual order \(order), expected \([a,b]), destination remained active: \(frontWasDestination)")
        try native("closetStart"); defer { _ = try? native("closetStop") }
        try native("closetHide",["ids":[a]]); try native("closetShow",["ids":[a]])
        try requireFinalState("closet return restores visibility without activating its owner") {
            let state = try desktop.observe()
            return state.visibleIDs.contains(a) && state.frontmostFixturePID == anchor.pid
        }
        let sibling = try fixture.open(key: "sibling"); _ = try window(sibling)
        try desktop.activate(key: "sibling")
        try native("closetHide", ["ids": [a]]); try native("closetShow", ["ids": [a]])
        try #require(try write(sibling, "AXRaise") == 0)
        try requireFinalState("raising the active card key restores its order after a sibling returns") {
            let state = try desktop.observe()
            return state.frontmostFixturePID == fixture.pid && state.visibleIDs.filter { [a,sibling].contains($0) }.first == sibling
        }
        let background = try second.open(key: "backgroundCard"); _ = try window(background, session: second)
        try desktop.activate(key: "sibling")
        try native("closetHide", ["ids": [a]]); try native("closetHide", session: second, ["ids": [b]])
        try native("closetShow", ["ids": [a]]); try native("closetShow", session: second, ["ids": [b]])
        try #require(try native("write", session: second, ["id": background, "attribute": "AXMain"]).result == 0)
        try #require(try native("write", session: second, ["id": background, "attribute": "AXRaise"]).result == 0)
        try #require(try write(sibling, "AXRaise") == 0)
        try requireFinalState("selecting the background card main window preserves activation and raises the complete mixed-app card") {
            let state = try desktop.observe(), order = state.visibleIDs.filter { [a,b,sibling,background].contains($0) }
            guard let firstStatic = order.firstIndex(where: { [a,b].contains($0) }) else { return false }
            return state.frontmostFixturePID == fixture.pid && [sibling,background].allSatisfy { id in
                order.firstIndex(of: id).map { $0 < firstStatic } == true
            }
        }
        try desktop.activate(key: "a")
        try #require(try write(sibling, "AXMain") == 0)
        try expectFocus(sibling)
    }

    @Test("closet-ax-identity: retained AX handles and hidden position writes survive a round trip", contract(.closetAXIdentity))
    func closetAXIdentityAndPosition() throws {
        let id = try fixture.open(); let original = try window(id)
        try native("closetStart"); defer { _ = try? native("closetStop") }
        try native("closetHide",["ids":[id]])
        let position = [original.frame[0]+30,original.frame[1]+20]
        try #require(try write(id,"AXPosition",position) == 0)
        try native("closetShow",["ids":[id]])
        try requireFinalState("the same retained AX handle returns at its hidden requested position") {
            let reply = try native("reacquire",["id":id]), frame = reply.window?.frame ?? []
            return reply.equal == true && frame.count == 4 && desktop.near(Array(frame.prefix(2)),position)
        }
    }

    @Test("closet-size-loss: hidden size writes may return short and an on-screen write restores full height", contract(.closetSizeLoss))
    func closetedSizeWritesMayReturnShort() throws {
        let id = try fixture.open(); _ = try window(id)
        let screen = try native("screen"), area = try #require(screen.axVisibleFrame)
        let requested = [area[2]-20,area[3]-20]
        try native("closetStart"); defer { _ = try? native("closetStop") }
        for y in [area[1]+10, (try #require(screen.screen))[3]-32] {
            try native("closetHide",["ids":[id]])
            try #require(try write(id,"AXPosition",[10,y]) == 0)
            try #require(try write(id,"AXSize",requested) == 0)
            try native("closetShow",["ids":[id]])
            try requireFinalState("a hidden write returns a valid frame no taller than requested") {
                let frame = try native("retained",["id":id]).window?.frame ?? []
                return frame.count == 4 && frame[3] > 0 && frame[3] <= requested[1]+1
            }
            try #require(try write(id,"AXPosition",[10,area[1]+10]) == 0)
            try #require(try write(id,"AXSize",requested) == 0)
            try requireFinalState("on-screen size write restores the requested height") {
                let frame = try native("retained",["id":id]).window?.frame ?? []
                return frame.count == 4 && desktop.near(Array(frame.suffix(2)),requested)
            }
        }
    }

    @Test("display-frame-demand: native display frames arrive on request and stop completely after invalidation", contract(.displayFrameDemand))
    func displayFramesStopWithoutDemand() throws {
        try native("motionStart"); defer { _ = try? native("motionStop") }
        try requireFinalState("the native display link delivers several screen frames") { try (native("motionSamples").motionFrameCount ?? 0) >= 4 }
        let stopped = try #require(try native("motionStop").motionFrameCount)
        // Observe over multiple refresh periods; this is a negative observation,
        // not a latency assertion. The standard final-state margin still applies.
        sleep(seconds:0.1)
        try #require(try native("motionSamples").motionFrameCount == stopped)
    }

    @Test("reduce-motion-notifications: NSWorkspace reads the preference and publishes a native change", contract(.reduceMotionNotifications))
    func reduceMotionNotifies() throws {
        let original = try #require(try native("motionPreferences").reduceMotion)
        // Change the native setting through the signed test driver; macOS
        // protects this preference against a direct defaults write.
        defer { _ = try? native("motionSetPreference",["enabled":original]) }
        try native("motionSetPreference",["enabled":!original])
        var lastValue: Bool?, changes: [Bool] = []
        let changed = try finalState {
            let facts = try native("motionPreferences")
            lastValue = facts.reduceMotion; changes = facts.motionChanges ?? []
            return lastValue == !original && changes.last == !original
        }
        try #require(changed,"Native Reduce Motion must change and notify: original \(original), observed \(String(describing:lastValue)), notifications \(changes)")
    }
}
