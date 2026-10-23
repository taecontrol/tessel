import Carbon
import CoreGraphics
import Foundation
import Testing

extension Acceptance.Journeys {
    private func videoRail(_ widths: [Double] = [0.6, 0.6, 0.6], protected: Bool = true) throws -> [UInt32] {
        let ids = try desktop.railSetup(widths, duration: 0, video: 1)
        try fixture.command("preventsCapture", ["key": "w1", "enabled": protected])
        try requireFinalState("the video frame is ready for display") { try fixture.command("ping").videosReady?["w1"] == true }
        try desktop.configure("[animation]\nduration = 1000\n", layout: "carousel")
        let given = try harness.motionGiven()
        try #require(try harness.status().workspaces?.motion == "on", "the protected-video journeys require motion; \(given)")
        return ids
    }

    private func videoWidths(_ fractions: [Double]) throws -> [Double] {
        let area = try desktop.observe().area
        return fractions.map { ((area[2] - 20) * $0).rounded(.down) }
    }

    /// Expected strip geometry is worked out from the fixture's starting
    /// widths and the smallest scroll that exposes the destination completely.
    private func expectVideoRail(_ ids: [UInt32], widths: [Double], focus: Int) throws {
        let screen = try #require(try harness.observer.command("contract", ["operation": "screen"]).contract?.cgDisplay)
        let bounds = CGRect(x: screen[0], y: screen[1], width: screen[2], height: screen[3])
        try requireFinalState("every video-rail window at its layout rect with the requested focus") {
            let observation = try desktop.observe(), rows = try harness.rows(), area = observation.area
            let starts = widths.indices.map { widths.prefix($0).reduce(0, +) + Double($0) * 10 }
            let offset = max(0, starts[focus] + widths[focus] - (area[2] - 20))
            return desktop.focused(ids[focus], in: observation) && ids.indices.allSatisfy { i in
                let rect = CGRect(x: area[0] + 10 + starts[i] - offset, y: area[1] + 10, width: widths[i], height: area[3] - 20)
                let visible = rect.intersection(bounds).width >= 1
                guard rows.contains(where: { $0.id == ids[i] && $0.state == "tiled" && $0.rail == 1 && $0.slot == i + 1 && $0.visible == visible }) else { return false }
                return observation.windows.contains { window in
                    window.id == ids[i] && window.visible == visible
                        && (!visible || desktop.near(window.frame, [rect.minX, rect.minY, rect.width, rect.height]))
                }
            }
        }
    }

    @Test("#36 E2: protected video keeps tessel alive, motion enabled and every tile placed without showing the stage")
    func protectedVideoMovesInstantly() throws {
        let ids = try videoRail(), widths = try videoWidths([0.6, 0.6, 0.6])
        let pid = try harness.status().pid
        for destination in [1, 2] {
            let shows = try harness.stageMotion().stageShows
            try desktop.post(kVK_ANSI_L)
            try expectVideoRail(ids, widths: widths, focus: destination)
            let status = try harness.status()
            try #require(status.pid == pid, "protected video must not crash or restart tessel")
            try #require(status.workspaces?.motion == "on", "a failed capture does not disable motion")
            try #require(try harness.stageMotion().stageShows == shows, "the failed-capture move shows no stand-ins")
        }
    }

    @Test("#36 E3: three commands survive protected video first captured at the start or by a retarget", arguments: [false, true])
    func protectedVideoRetargets(firstSeenByRetarget: Bool) throws {
        let fractions = Array(repeating: firstSeenByRetarget ? 1.0 : 0.6, count: 3)
        let ids = try videoRail(fractions), widths = try videoWidths(fractions)
        let pid = try harness.status().pid, before = try harness.stageMotion()
        // Full-width tiles put w1 wholly off screen. A left-wall bounce
        // captures only w0; the next right press first requests protected w1
        // while that stage is shown. The narrower rail includes w1 in its
        // first rightward move, with repeats while its captures are pending.
        try desktop.post(firstSeenByRetarget ? kVK_ANSI_H : kVK_ANSI_L)
        try requireFinalState("the first move is shown, or has requested its protected capture") {
            let motion = try harness.stageMotion()
            return firstSeenByRetarget ? motion.stageShows > before.stageShows : motion.stageScreenshots[String(ids[1])] != nil
        }
        let first = try harness.stageMotion()
        if firstSeenByRetarget {
            try #require(first.stageScreenshots[String(ids[1])] == nil, "the protected tile must be first seen by the retarget")
        }
        try desktop.post(firstSeenByRetarget ? kVK_ANSI_L : kVK_ANSI_H)
        try requireFinalState("the protected window is requested in that same move") {
            let motion = try harness.stageMotion()
            return motion.stageMove == first.stageMove && motion.stageScreenshots[String(ids[1])] != nil
        }
        try desktop.post(kVK_ANSI_L)
        try expectVideoRail(ids, widths: widths, focus: firstSeenByRetarget ? 2 : 1)
        try requireFinalState("the failed capture clears the move") { try harness.stageMotion().stageClears > first.stageClears }
        try #require(try harness.stageMotion().stageSettles == first.stageSettles, "the retarget ends instantly, before the motion settles")
        try #require(try harness.status().pid == pid, "retargeting a protected window must keep the same process alive")
    }

    @Test("#36 E4: cycling a protected video's width survives both the first capture and an unreadable resize refresh", arguments: [false, true])
    func protectedVideoWidthCycle(protectOnResize: Bool) throws {
        let ids = try videoRail(protected: false)
        var widths = try videoWidths([0.6, 0.6, 0.6])
        try desktop.post(kVK_ANSI_L)
        try expectVideoRail(ids, widths: widths, focus: 1)
        // Finish setup without inheriting a capture from the focus move.
        try desktop.configure("[animation]\nduration = 0\n", layout: "carousel")
        try desktop.configure("[animation]\nduration = 1000\n", layout: "carousel")
        try fixture.command("preventsCapture", ["key": "w1", "enabled": true, "afterResize": protectOnResize])
        let pid = try harness.status().pid, before = try harness.stageMotion()
        try desktop.post(kVK_ANSI_R)
        let area = try desktop.observe().area
        widths[1] = (area[2] - 10) * (2.0 / 3) - 10
        try expectVideoRail(ids, widths: widths, focus: 1)
        if protectOnResize {
            try requireFinalState("the shown stand-in has requested its resize refresh") {
                try (harness.stageMotion().stageScreenshots[String(ids[1])] ?? 0) >= 2
            }
            try requireFinalState("the protected refresh has completed without a crash") { try harness.stageMotion().stageCapturesPending == 0 }
            try #require(try harness.stageMotion().stageShows == before.stageShows + 1, "the readable initial capture animates before its protected refresh")
            try requireFinalState("the resize motion finishes with its previous capture") { try harness.stageMotion().stageClears > before.stageClears }
            try #require(try harness.stageMotion().stageSettles == before.stageSettles + 1,
                         "an unreadable refresh keeps the previous capture until the motion settles")
        }
        try #require(try harness.status().pid == pid, "an unreadable width capture must not crash tessel")
    }

    @Test("#36 E5: removing capture protection lets the next move animate again")
    func protectedVideoBecomesCapturableAgain() throws {
        let ids = try videoRail(), widths = try videoWidths([0.6, 0.6, 0.6])
        try desktop.post(kVK_ANSI_L)
        try expectVideoRail(ids, widths: widths, focus: 1)
        try fixture.command("preventsCapture", ["key": "w1", "enabled": false])
        try requireFinalState("the unprotected frame is ready for display") { try fixture.command("ping").videosReady?["w1"] == true }
        let before = try harness.stageMotion()
        try desktop.post(kVK_ANSI_L)
        try expectVideoRail(ids, widths: widths, focus: 2)
        try #require(try harness.stageMotion().stageShows > before.stageShows, "protection is not remembered between moves")
    }

    @Test("#36 E6: each move attempts exactly one screenshot of its protected window")
    func protectedVideoIsNeverRetried() throws {
        let ids = try videoRail(), widths = try videoWidths([0.6, 0.6, 0.6])
        var move = try harness.stageMotion().stageMove
        for destination in [1, 2] {
            try desktop.post(kVK_ANSI_L)
            try expectVideoRail(ids, widths: widths, focus: destination)
            let motion = try harness.stageMotion()
            try #require(motion.stageMove > move, "each command starts a new capture attempt")
            try #require(motion.stageScreenshots[String(ids[1])] == 1, "a protected capture is attempted once per move, without a retry")
            move = motion.stageMove
        }
    }

    @Test("#36 E7: a horizontal move in another workspace animates while protected video remains open")
    func protectedVideoDoesNotDisableOtherWorkspaces() throws {
        let ids = try videoRail(), widths = try videoWidths([0.6, 0.6])
        try desktop.configure("[animation]\nduration = 0\n", layout: "carousel")
        try desktop.post(kVK_ANSI_L)
        try desktop.expectFocus(ids[1])
        try desktop.key(2, send: true)
        try desktop.expectFocus(ids[1])
        try desktop.key(1)
        try desktop.activate(key: "w0")
        try expectVideoRail([ids[0], ids[2]], widths: widths, focus: 0)
        try #require(try harness.row(ids[1])?.workspace == 2 && harness.status().workspaces?.active == 1)
        try desktop.configure("[animation]\nduration = 1000\n", layout: "carousel")
        let before = try harness.stageMotion()
        try desktop.post(kVK_ANSI_L)
        try expectVideoRail([ids[0], ids[2]], widths: widths, focus: 1)
        try requireFinalState("the other workspace animates") { try harness.stageMotion().stageShows > before.stageShows }
        try #require(try harness.stageMotion().stageScreenshots[String(ids[1])] == nil, "the protected window is outside this move")
    }

    @Test("Reduce Motion journey")
    func reduceMotionMakesCarouselMovesInstant() throws {
        try step("Reduce Motion makes a configured carousel move instant (wiring)") {
            harness.stopApp()
            // The harness verifies that tessel reports a zero effective duration.
            defer { harness.stopApp(); try? harness.startApp() }
            let ids = try desktop.railSetup([0.6, 0.6], duration: 400, reduceMotion: true)
            let work = try harness.stageWork()
            try desktop.post(kVK_ANSI_L)
            try desktop.expectFocus(ids[1])
            try requireFinalState("the scrolled rail shows its second tile complete") {
                let observation = try desktop.observe(focusedOnly: true), area = observation.area
                return observation.windows.contains { $0.id == ids[1] && $0.frame[0] + $0.frame[2] <= area[0] + area[2] - 9 }
            }
            let given = try harness.motionGiven()
            try #require(try harness.stageWork() == work, "a move under Reduce Motion captures and shows nothing; \(given)")
        }
    }

    @Test("#26 E15: a mixed-app rail change lands focus and both rails without stray activation")
    func carouselCardsKeepCrossAppOrderAndFocus() throws {
        let other = try FixtureSession(directory:harness.directory,number:harness.otherFixtures.count+1)
        harness.otherFixtures.append(other)
        harness.stopApp()
        let visible = try desktop.observe().area
        let fraction = ((visible[2] - 30) / 2) / (visible[2] - 20)
        let a = try fixture.open(kind:"heavyText",key:"topA", ["widthFraction": fraction]), c = try fixture.open(kind:"web",key:"bottomA", ["widthFraction": fraction])
        let b = try other.open(kind:"web",key:"topB", ["widthFraction": fraction]), d = try other.open(kind:"heavyText",key:"bottomB", ["widthFraction": fraction])
        let top = [a,b], bottom = [c,d], ids = top+bottom
        try desktop.activate(key:"topA")
        try desktop.writeConfig("[animation]\nduration = 400\n")
        try harness.startApp(fixtureReady: false)
        try requireFinalState("all mixed-app fixture windows are catalogued") { Set(try harness.rows().map(\.id)) == Set(ids) }
        try desktop.activate(key:"topA")
        try desktop.configure("[experiments]\ncarousel = true\n[animation]\nduration = 400\n",layout:"carousel")
        try step("rail wiring: transfer one window from each app into the second rail") {
            // Same-app selection: the app is already frontmost, so wait for
            // its focus before the command.
            try desktop.activate(key:"bottomA"); try desktop.expectFocus(c); try desktop.post(kVK_ANSI_J,shift:true)
            try requireFinalState("the first bottom fixture is in rail two") { try harness.row(c)?.rail == 2 }
            if try !finalState({ try desktop.focused(c, in: desktop.observe()) }) {
                let state = try desktop.observe()
                throw HarnessError("first card: focus \(state.windows.filter(\.focused).map(\.id)), frames \(state.windows.map { "\($0.id):\($0.frame) visible=\($0.visible)" }), area \(state.area)")
            }
            try requireFinalState("the first transfer has hidden the source rail") {
                let visible = try desktop.observe().visibleIDs
                return [a,b,d].allSatisfy { !visible.contains($0) }
            }
            // Navigate to the destination while visible; an external AX
            // activation of a closeted window cannot establish native focus.
            try desktop.post(kVK_ANSI_K); try desktop.expectFocus(a)
            try desktop.post(kVK_ANSI_L); try desktop.expectFocus(b)
            try desktop.post(kVK_ANSI_L); try desktop.expectFocus(d)
            try requireFinalState("navigation has revealed the source rail before the next transfer") {
                let observation = try desktop.observe()
                return try harness.status().workspaces?.rail == 1 && !observation.visibleIDs.contains(c)
                    && observation.windows.contains { $0.id == d && $0.visible && abs($0.frame[1] - observation.area[1] - 10) <= 1 }
            }
            try desktop.post(kVK_ANSI_J,shift:true)
            let established = try finalState {
                let rows = try harness.rows()
                return top.allSatisfy { id in rows.contains { $0.id == id && $0.rail == 1 } }
                    && bottom.allSatisfy { id in rows.contains { $0.id == id && $0.rail == 2 } }
            }
            if !established {
                let actual = try harness.rows().map { "id=\($0.id) rail=\($0.rail ?? 0)" }
                throw HarnessError("mixed rails: top \(top), bottom \(bottom), actual \(actual)")
            }
            try requireFinalState("the second transfer has finished before returning up") {
                let observation = try desktop.observe()
                return bottom.allSatisfy { id in observation.windows.contains { $0.id == id && $0.visible && abs($0.frame[1] - observation.area[1] - 10) <= 1 } }
                    && top.allSatisfy { !observation.visibleIDs.contains($0) }
            }
            // Opposite focus apps exercise both activation handoffs: focus
            // moves to the entering rail's app while both rails slide. tessel's
            // own key selects bottomA, so the rail remembers it before K; an
            // external activation is reported after a key posted right away.
            let cSlot = try #require(try harness.row(c)?.slot), dSlot = try #require(try harness.row(d)?.slot)
            try desktop.post(cSlot < dSlot ? kVK_ANSI_H : kVK_ANSI_L); try desktop.expectFocus(c)
            try desktop.post(kVK_ANSI_K)
            try requireFinalState("the return has finished before arranging its focus") {
                let observation = try desktop.observe()
                return top.allSatisfy { observation.visibleIDs.contains($0) } && bottom.allSatisfy { !observation.visibleIDs.contains($0) }
            }
            try desktop.activate(key:"topA"); try desktop.post(kVK_ANSI_H)
            try desktop.expectFocus(a)
            try desktop.post(kVK_ANSI_L)
            try desktop.expectFocus(b)
            if try !finalState({
                let observation = try desktop.observe(), area = observation.area, half = (area[2] - 30) / 2
                return desktop.focused(b, in: observation)
                    && observation.windows.contains { $0.id == a && $0.visible && desktop.near($0.frame, [area[0]+10,area[1]+10,half,area[3]-20]) }
                    && observation.windows.contains { $0.id == b && $0.visible && desktop.near($0.frame, [area[0]+20+half,area[1]+10,half,area[3]-20]) }
            }) {
                let observation = try desktop.observe()
                throw HarnessError("mixed-app source pair: expected \(top), area \(observation.area), frames \(observation.windows.map { "\($0.id):\($0.frame) visible=\($0.visible) focus=\($0.focused)" })")
            }
        }
        for (key,_,destination,destinationPID) in [(kVK_ANSI_J,bottom,c,fixture.pid),(kVK_ANSI_K,bottom,b,other.pid)] {
            try step("stage wiring: the rails swap under the stage and only the two fixture apps activate") {
                let sourcePID = try desktop.observe().frontmostFixturePID
                let work = try harness.stageWork()
                // The observer samples the frontmost app on its own display link.
                guard finalValue({
                    try? harness.observer.command("contract",["operation":"motionStart","pid":fixture.pid,
                        "targets":[["pid":fixture.pid,"ids":[a,c]],["pid":other.pid,"ids":[b,d]]]]).contract
                }) != nil else { throw HarnessError("motion observer did not start") }
                defer { _ = try? harness.observer.command("contract",["operation":"motionStop","pid":fixture.pid]) }
                var samples: [NativeContractReply.MotionSample] = []
                @MainActor func drain(_ operation: String = "motionSamples") throws -> NativeContractReply {
                    let reply = try #require(try harness.observer.command("contract",["operation":operation,"pid":fixture.pid,"drain":true]).contract)
                    samples += reply.motionSamples ?? []
                    return reply
                }
                try desktop.post(key)
                // A timeout names the last observation so a CI-only failure is diagnosable.
                var last = "no observation"
                do {
                    try requireFinalState("fixture \(destination) visible, main and focused") {
                        _ = try drain()
                        let observation = try desktop.observe(focusedOnly: true)
                        last = "front \(observation.frontmostFixturePID), active \(observation.activeFixturePID), "
                            + observation.windows.map { "\($0.id): visible \($0.visible) main \($0.main) focused \($0.focused)" }.joined(separator: "; ")
                        return desktop.focused(destination, in: observation)
                    }
                } catch { throw HarnessError("\(error); last observation: \(last); fixture \(fixture.pid), other \(other.pid)") }
                try requireFinalState("the rail lands at the area top and its old rail is hidden") {
                    _ = try drain()
                    let observation = try desktop.observe(), area = observation.area
                    let shown = key == kVK_ANSI_J ? bottom : top, hidden = key == kVK_ANSI_J ? top : bottom
                    return shown.allSatisfy { id in observation.windows.contains { $0.id == id && $0.visible && abs($0.frame[1] - area[1] - 10) <= 1 } }
                        && hidden.allSatisfy { !observation.visibleIDs.contains($0) }
                }
                // The stage places the real windows at once, so focus can land
                // before the sampler answers twice; keep sampling after it.
                try requireFinalState("the observer has native focused-application answers") {
                    _ = try drain()
                    return samples.filter { $0.frontmost != 0 }.count >= 2
                }
                _ = try drain("motionStop")
                let given = try harness.motionGiven()
                if try harness.status().workspaces?.motion == "on" {
                    try #require(try harness.stageWork() > work, "an animated rail change captures and shows its rails; \(given)")
                }
                var reachedDestination = false
                let activationSamples = samples.filter { $0.frontmost != 0 }
                try #require(activationSamples.count >= 2,"the observer must receive native focused-application answers")
                for sample in activationSamples {
                    try #require([sourcePID,destinationPID].contains(sample.frontmost),"AXRaise must not activate an unrelated app")
                    if reachedDestination { try #require(sample.frontmost == destinationPID,"activation must not bounce between fixture apps") }
                    if sample.frontmost == destinationPID { reachedDestination = true }
                }
                try #require(reachedDestination,"the destination focus app must become active")
            }
        }
    }
}
