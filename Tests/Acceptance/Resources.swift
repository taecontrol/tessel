import Carbon
import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct Resources {
        let desktop = Desktop()
        var harness: Harness { desktop.harness }
        var fixture: FixtureSession { desktop.fixture }

        init() throws { try Harness.shared.reset() }

        struct Budget: Decodable {
            let windowSeconds: Double
            let interruptWakeups: UInt64
            let cpuNanoseconds: UInt64
            let footprintBytes: UInt64
        }

        private func verifyIdleResources(_ example: String, stageWorkBefore: UInt64? = nil, mapShowsBefore: UInt64? = nil) throws {
            let budget = try JSONDecoder().decode(Budget.self, from: Data(contentsOf: root.appending(path: "Tests/Acceptance/resource-budget.json")))
            let stageAtStart = try harness.stageWork()
            let before = try resources(harness.appPID)
            print(String(format: "%@: start footprint %.2f MB (limit < %.2f MB)", example,
                         Double(before.footprintBytes) / 1e6, Double(budget.footprintBytes) / 1e6))
            fflush(nil)
            try #require(before.footprintBytes < budget.footprintBytes, "Start footprint must be below the footprint limit")
            let idleStart = Date()
            sleep(seconds: budget.windowSeconds)
            let after = try resources(harness.appPID)
            let idleEnd = Date()
            let wakeups = after.interruptWakeups - before.interruptWakeups
            let cpu = after.cpuNanoseconds - before.cpuNanoseconds
            print(String(format: "%@: %.0f s idle: wakeups %llu (limit <= %llu), CPU %.3f ms (limit <= %.3f ms), footprint start/end %.2f/%.2f MB (limit < %.2f MB)",
                         example, budget.windowSeconds, wakeups, budget.interruptWakeups,
                         Double(cpu) / 1e6, Double(budget.cpuNanoseconds) / 1e6,
                         Double(before.footprintBytes) / 1e6, Double(after.footprintBytes) / 1e6, Double(budget.footprintBytes) / 1e6))
            print("\(example): stage work during measured idle window \(try harness.stageWork() - stageAtStart)")
            fflush(nil)
            try #require(wakeups <= budget.interruptWakeups, "Interrupt wakeups exceeded the wakeup limit")
            try #require(cpu <= budget.cpuNanoseconds, "CPU time exceeded the CPU limit")
            try #require(after.footprintBytes < budget.footprintBytes, "End footprint must be below the footprint limit")
            let entries = try diagnosticEntryCount(subsystem: "com.taecontrol.tessel.dev", pid: harness.appPID, from: idleStart, through: idleEnd)
            try #require(entries == 0, "the measured instance must record no diagnostic during the idle window")
            if let stageWorkBefore {
                try #require(try harness.stageWork() == stageWorkBefore, "The app must capture and show nothing while idle")
            }
            if let mapShowsBefore {
                try #require(try harness.mapState().shows == mapShowsBefore && harness.mapWindows().isEmpty,
                             "the map stays off screen and does no work during the measured idle window")
            }
        }

        @Test("#1 E22; #59 E5; #62 E16; #63 E6: idle resource budget and no diagnostic entries") func e22TwentyIdleWindowsStayWithinWakeupCPUAndFootprintLimits() throws {
            // Discover an existing desktop in one snapshot. Opening twenty
            // windows under a live manager leaves arrival animations in flight.
            harness.stopApp()
            for index in 0..<20 { _ = try fixture.open(key: "idle\(index)") }
            try desktop.activate(key: "idle19")
            try harness.startApp(fixtureReady: false)
            try requireFinalState("twenty idle fixture windows listed") { try harness.rows().count == 20 }
            try desktop.expectFocus(try #require(try fixture.command("ping").windows["idle19"]))
            sleep(seconds: 1)  // Let startup placement settle.
            try verifyIdleResources("E22", stageWorkBefore: harness.stageWork())
        }

        @Test("#2 E36; #63 E6: resources across ten workspaces") func e36TwentyWindowsAcrossTenWorkspacesKeepTheFoundationBudget() throws {
            try harness.reset()
            try desktop.configure(desktop.carousel, layout: "carousel")
            for index in 0..<20 {
                print("E36 preparing fixture window \(index + 1)/20")
                fflush(nil)
                let workspace = try #require(try harness.status().workspaces).active
                let window = try fixture.open(key: "idle\(index)")
                // The fixture app stays frontmost, so AppKit keys each later
                // window as it opens; activating it again would re-observe them all.
                if index == 0 { try desktop.activate(key: "idle\(index)") }
                try desktop.expectFocus(window)
                try requireFinalState("the idle fixture assigned before its next command") { try harness.row(window)?.workspace == workspace }
                if index.isMultiple(of: 2), index > 0 {
                    let destination = index / 2 + 1
                    try desktop.key(destination, send: true)
                    try desktop.expectFocus(window)
                    try requireFinalState("the idle fixture sent before opening the next one") {
                        try harness.row(window)?.workspace == destination && harness.status().workspaces?.active == destination
                    }
                }
            }
            try expectMembership("twenty fixtures across ten workspaces") { rows in
                return rows.count == 20 && Set(rows.compactMap(\.workspace)) == Set(1...10)
            }
            sleep(seconds: 1)
            try verifyIdleResources("E36")
        }
        @Test("#26 E24; #19 E28; #18 E26; #63 E6: carousel, a hidden layer and the enabled map keep the idle resource budget") func carouselAcrossWorkspacesKeepsTheIdleResourceBudget() throws {
            try harness.reset()
            // Thirty setup changes run instantly: each animated one costs a
            // capture. One animated
            // change at the default duration loads the stage before the idle
            // window.
            try desktop.configure("[experiments]\nlayer = true\nmap = true\n[animation]\nduration = 0\n", layout: "carousel")
            var last: UInt32 = 0
            for index in 0..<20 {
                let id = try fixture.open(kind: index.isMultiple(of: 2) ? "heavyText" : "web", key: "idle\(index)", ["widthFraction": 0.4])
                if index == 0 { try desktop.activate(key: "idle\(index)") }
                try desktop.expectFocus(id)
                last = id
                // Native focus can precede the catalog's new-window arrival.
                // Finish each setup command before opening the next fixture.
                try requireFinalState("the resource fixture assigned to the active workspace") {
                    try harness.row(id)?.workspace == harness.status().workspaces?.active
                }
                if index.isMultiple(of: 2) {
                    let rail = try #require(try harness.row(id)?.rail)
                    try desktop.post(38, shift: true)
                    try desktop.expectFocus(id)
                    try requireFinalState("the resource fixture moved down a rail") { try harness.row(id)?.rail == (index == 0 ? rail : rail + 1) }
                }
                if index.isMultiple(of: 4), index > 0 {
                    let workspace = index / 4 + 1
                    try desktop.key(workspace, send: true)
                    try desktop.expectFocus(id)
                    try requireFinalState("the resource fixture sent to its workspace") {
                        try harness.row(id)?.workspace == workspace && harness.status().workspaces?.active == workspace
                    }
                }
            }
            try expectMembership("twenty rail fixtures across five workspaces") { rows in
                return rows.count == 20 && Set(rows.compactMap(\.workspace)).count == 5 && rows.contains { ($0.rail ?? 0) > 1 }
            }
            let hiddenFloat = try fixture.open(kind: "normalPanel", key: "hiddenFloat", ["background": true])
            try requireFinalState("the idle layer fixture is catalogued") { try harness.row(hiddenFloat)?.state == "floats" }
            // A new float enters its single-window layer under #19 E12. Finish
            // that arrival before establishing the hidden-layer idle scene.
            try requireFinalState("the new idle float has native focus") {
                try desktop.observe().windows.contains { $0.id == hiddenFloat && $0.visible && $0.focused }
            }
            try desktop.post(kVK_ANSI_Z)
            try desktop.expectFocus(last)
            try requireFinalState("the idle float is hidden natively and in the CLI") {
                try harness.row(hiddenFloat)?.visible == false && !desktop.observe().visibleIDs.contains(hiddenFloat)
            }
            try desktop.configure("[experiments]\nlayer = true\nmap = true\n", layout: "carousel")
            let setupWorkStart = try harness.stageWork()
            let rail = try #require(try harness.row(last)?.rail)
            try desktop.post(38, shift: true)
            try desktop.expectFocus(last)
            try requireFinalState("the animated change moved the last fixture down a rail") { try harness.row(last)?.rail == rail + 1 }
            sleep(seconds: 1)
            let work = try harness.stageWork()
            let given = try harness.motionGiven()
            // The counter proves idle zero work only once it has counted the animated change.
            if try harness.status().workspaces?.motion == "on" {
                try #require(work > setupWorkStart, "The stage counter must increase during the animated change before it can prove idle zero work; \(given)")
            }
            let shows = try harness.mapState().shows
            try #require(shows > 0, "the real map adapter must have shown before idle absence can prove anything")
            try requireFinalState("the map orders out before the idle resource window") { try harness.mapWindows().isEmpty }
            try verifyIdleResources("Carousel E24 / Layer E28 / Map E26", stageWorkBefore: work, mapShowsBefore: shows)
        }

        private func expectMembership(_ expectation: String, _ predicate: ([Row]) -> Bool) throws {
            var last: [Row] = []
            do {
                try requireFinalState(expectation) { last = try harness.rows(); return predicate(last) }
            } catch {
                throw HarnessError("\(error); fixture membership: \(last.map { "\($0.id): \($0.state), workspace=\(String(describing: $0.workspace)), rail=\(String(describing: $0.rail))" })")
            }
        }
    }
}
