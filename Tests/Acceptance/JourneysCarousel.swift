import Carbon
import Foundation
import Testing

extension Acceptance.Journeys {
    @Test("#26 E15: mixed-app cards keep the moving rail above the other without stray activation")
    func carouselCardsKeepCrossAppOrderAndFocus() throws {
        let other = try FixtureSession(directory:harness.directory,number:harness.otherFixtures.count+1)
        harness.otherFixtures.append(other)
        let a = try fixture.open(kind:"heavyText",key:"topA"), c = try fixture.open(kind:"web",key:"bottomA")
        let b = try other.open(kind:"web",key:"topB"), d = try other.open(kind:"heavyText",key:"bottomB")
        let top = [a,b], bottom = [c,d], ids = top+bottom
        try requireFinalState("all mixed-app fixture windows are catalogued") { Set(try harness.rows().map(\.id)) == Set(ids) }
        try desktop.activate(key:"topA")
        try desktop.configure("[experiments]\ncarousel = true\n[animation]\nduration = 400\n",layout:"carousel")
        try step("card wiring: transfer one window from each app into the second rail") {
            try desktop.activate(key:"bottomA"); try desktop.post(kVK_ANSI_J,shift:true)
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
            try desktop.post(kVK_ANSI_K)
            try requireFinalState("the return card has finished before arranging its focus") {
                let observation = try desktop.observe()
                return top.allSatisfy { observation.visibleIDs.contains($0) } && bottom.allSatisfy { !observation.visibleIDs.contains($0) }
            }
            try desktop.activate(key:"topA"); try desktop.post(kVK_ANSI_H)
            try desktop.expectFocus(a)
            try desktop.post(kVK_ANSI_L)
            try desktop.expectFocus(b)
            try requireFinalState("the mixed-app top pair is settled before sampling cards") {
                let observation = try desktop.observe(), area = observation.area
                return top.allSatisfy { id in observation.windows.contains { $0.id == id && $0.visible && abs($0.frame[1] - area[1] - 10) <= 1 } }
                    && observation.windows.contains { $0.id == a && abs($0.frame[0] - area[0] - 10) <= 1 }
                    && observation.windows.contains { $0.id == b && abs($0.frame[0] + $0.frame[2] - area[0] - area[2] + 10) <= 1 }
            }
        }
        for (key,moving,destination) in [(kVK_ANSI_J,bottom,d),(kVK_ANSI_K,bottom,b)] {
            try step("display-frame and card wiring: sample intermediate positions and native order") {
                let sourcePID = try desktop.observe().frontmostFixturePID
                guard let started = try finalValue({
                    try? harness.observer.command("contract",["operation":"motionStart","pid":fixture.pid,
                        "targets":[["pid":fixture.pid,"ids":[a,c]],["pid":other.pid,"ids":[b,d]]]]).contract
                }) else {
                    throw HarnessError("motion observer did not start")
                }
                _ = started
                defer { _ = try? harness.observer.command("contract",["operation":"motionStop","pid":fixture.pid]) }
                try desktop.post(key)
                try desktop.expectFocus(destination)
                try requireFinalState("the card lands at the area top and its old rail is hidden") {
                    let observation = try desktop.observe(), area = observation.area
                    let shown = key == kVK_ANSI_J ? bottom : top, hidden = key == kVK_ANSI_J ? top : bottom
                    return shown.allSatisfy { id in observation.windows.contains { $0.id == id && $0.visible && abs($0.frame[1] - area[1] - 10) <= 1 } }
                        && hidden.allSatisfy { !observation.visibleIDs.contains($0) }
                }
                let reply = try #require(try harness.observer.command("contract",["operation":"motionStop","pid":fixture.pid]).contract)
                let samples = try #require(reply.motionSamples)
                let area = try desktop.observe().area
                let overlap = samples.filter { sample in
                    top.contains { sample.order.contains($0) } && bottom.contains { sample.order.contains($0) }
                }
                try #require(overlap.count >= 2,"the independent observer must see overlapping cards, not just their final state")
                let intermediates = overlap.flatMap(\.windows).filter { moving.contains($0.id) && $0.valid && $0.frame.count == 4 && $0.frame[1] > area[1]+11 && $0.frame[1] < area[1]+area[3]-33 }
                try #require(!intermediates.isEmpty,"real AX samples must include an intermediate moving-card position")
                for sample in overlap {
                    try #require(sample.windows.allSatisfy { $0.valid },"a sampling failure must not count as occlusion")
                    let movingIndices = moving.compactMap { sample.order.firstIndex(of:$0) }
                    let staticIndices = top.compactMap { sample.order.firstIndex(of:$0) }
                    try #require(!movingIndices.isEmpty && !staticIndices.isEmpty && movingIndices.max()! < staticIndices.min()!,"every moving-card window must be above every other-card window")
                }
                let destinationPID = other.pid
                var reachedDestination = false
                for sample in samples {
                    try #require([sourcePID,destinationPID].contains(sample.frontmost),"AXRaise must not activate an unrelated app")
                    if reachedDestination { try #require(sample.frontmost == destinationPID,"activation must not bounce between fixture apps") }
                    if sample.frontmost == destinationPID { reachedDestination = true }
                }
                try #require(reachedDestination,"the destination focus app must become active")
            }
        }
    }
}
