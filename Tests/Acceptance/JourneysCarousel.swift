import Carbon
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("Reduce Motion journey")
    func reduceMotionMakesCarouselMovesInstant() throws {
        try step("Reduce Motion makes a configured carousel move instant (wiring)") {
            harness.stopApp()
            // The harness verifies that tessel reports a zero effective duration.
            try harness.startApp(reduceMotion: true)
            defer { harness.stopApp(); try? harness.startApp() }
            let ids = try desktop.railSetup([0.6, 0.6], duration: 400)
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
        let a = try fixture.open(kind:"heavyText",key:"topA"), c = try fixture.open(kind:"web",key:"bottomA")
        let b = try other.open(kind:"web",key:"topB"), d = try other.open(kind:"heavyText",key:"bottomB")
        let top = [a,b], bottom = [c,d], ids = top+bottom
        try requireFinalState("all mixed-app fixture windows are catalogued") { Set(try harness.rows().map(\.id)) == Set(ids) }
        try desktop.activate(key:"topA")
        try desktop.configure("[experiments]\ncarousel = true\n[animation]\nduration = 400\n",layout:"carousel")
        try step("rail wiring: transfer one window from each app into the second rail") {
            // Same-app selection: the app is already frontmost, so wait for
            // its focus before the command.
            try desktop.activate(key:"bottomA"); try desktop.expectFocus(c); try desktop.post(kVK_ANSI_J,shift:true)
            try requireFinalState("the first bottom fixture is in rail two") { try harness.row(c)?.rail == 2 }
            if try !finalState({ try desktop.shown(c, in: desktop.observe()) }) {
                let state = try desktop.observe()
                throw HarnessError("first card: focus \(state.windows.filter(\.focused).map(\.id)), frames \(state.windows.map { "\($0.id):\($0.frame) visible=\($0.visible)" }), area \(state.area)")
            }
            try requireFinalState("the first transfer has hidden the source rail") {
                let visible = try desktop.observe().visibleIDs
                return [a,b,d].allSatisfy { !visible.contains($0) }
            }
            try desktop.activate(other,key:"bottomB")
            try requireFinalState("external selection has revealed the source rail before the next transfer") {
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
            // moves to the entering rail's app while both rails slide.
            try desktop.activate(key:"bottomA"); try desktop.expectFocus(c)
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
                try requireFinalState("fixture \(destination) visible, main and focused") {
                    _ = try drain()
                    return try desktop.focused(destination, in: desktop.observe(focusedOnly: true))
                }
                try requireFinalState("the rail lands at the area top and its old rail is hidden") {
                    _ = try drain()
                    let observation = try desktop.observe(), area = observation.area
                    let shown = key == kVK_ANSI_J ? bottom : top, hidden = key == kVK_ANSI_J ? top : bottom
                    return shown.allSatisfy { id in observation.windows.contains { $0.id == id && $0.visible && abs($0.frame[1] - area[1] - 10) <= 1 } }
                        && hidden.allSatisfy { !observation.visibleIDs.contains($0) }
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
