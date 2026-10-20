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

        private func verifyIdleResources(_ example: String, stageWorkBefore: UInt64? = nil) throws {
            let budget = try JSONDecoder().decode(Budget.self, from: Data(contentsOf: root.appending(path: "Tests/Acceptance/resource-budget.json")))
            let before = try resources(harness.appPID)
            print(String(format: "%@: start footprint %.2f MB (limit < %.2f MB)", example,
                         Double(before.footprintBytes) / 1e6, Double(budget.footprintBytes) / 1e6))
            fflush(nil)
            try #require(before.footprintBytes < budget.footprintBytes, "Start footprint must be below the footprint limit")
            sleep(seconds: budget.windowSeconds)
            let after = try resources(harness.appPID)
            let wakeups = after.interruptWakeups - before.interruptWakeups
            let cpu = after.cpuNanoseconds - before.cpuNanoseconds
            print(String(format: "%@: %.0f s idle: wakeups %llu (limit <= %llu), CPU %.3f ms (limit <= %.3f ms), footprint start/end %.2f/%.2f MB (limit < %.2f MB)",
                         example, budget.windowSeconds, wakeups, budget.interruptWakeups,
                         Double(cpu) / 1e6, Double(budget.cpuNanoseconds) / 1e6,
                         Double(before.footprintBytes) / 1e6, Double(after.footprintBytes) / 1e6, Double(budget.footprintBytes) / 1e6))
            fflush(nil)
            try #require(wakeups <= budget.interruptWakeups, "Interrupt wakeups exceeded the wakeup limit")
            try #require(cpu <= budget.cpuNanoseconds, "CPU time exceeded the CPU limit")
            try #require(after.footprintBytes < budget.footprintBytes, "End footprint must be below the footprint limit")
            if let stageWorkBefore {
                try #require(try harness.stageWork() == stageWorkBefore, "The app must capture and show nothing while idle")
            }
        }

        @Test("#1 E22: idle resource budget") func e22TwentyIdleWindowsStayWithinWakeupCPUAndFootprintLimits() throws {
            for index in 0..<20 { _ = try fixture.open(key: "idle\(index)") }
            try requireFinalState("twenty idle fixture windows listed") { try harness.rows().count == 20 }
            sleep(seconds: 1)  // Let the bounded new-window settling work finish.
            try verifyIdleResources("E22")
        }

        @Test("#2 E36: resources across ten workspaces") func e36TwentyWindowsAcrossTenWorkspacesKeepTheFoundationBudget() throws {
            try harness.reset()
            try desktop.configure(desktop.stack, layout: "stack")
            for index in 0..<20 {
                print("E36 preparing fixture window \(index + 1)/20")
                fflush(nil)
                let window = try fixture.open(key: "idle\(index)")
                // The fixture app stays frontmost, so AppKit keys each later
                // window as it opens; activating it again would re-observe them all.
                if index == 0 { try desktop.activate(key: "idle\(index)") }
                try desktop.expectShown(window)
                if index.isMultiple(of: 2), index > 0 {
                    try desktop.key(index / 2 + 1, send: true)
                    try desktop.expectShown(window)
                }
            }
            try requireFinalState("twenty fixtures across ten workspaces") {
                let rows = try harness.rows()
                return rows.count == 20 && Set(rows.compactMap(\.workspace)) == Set(1...10)
            }
            sleep(seconds: 1)
            try verifyIdleResources("E36")
        }
        @Test("#26 E24: carousel does no stage work at rest and keeps the resource budget") func carouselAcrossWorkspacesKeepsTheIdleResourceBudget() throws {
            try harness.reset()
            // Thirty animated setup changes still run on the stage; a short
            // duration keeps the suite inside its CI budget.
            try desktop.configure("[experiments]\ncarousel = true\n[animation]\nduration = 80\n", layout: "carousel")
            let setupWorkStart = try harness.stageWork()
            for index in 0..<20 {
                let id = try fixture.open(kind: index.isMultiple(of: 2) ? "heavyText" : "web", key: "idle\(index)", ["widthFraction": 0.4])
                if index == 0 { try desktop.activate(key: "idle\(index)") }
                try desktop.expectFocus(id)
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
            try requireFinalState("twenty rail fixtures across five workspaces") {
                let rows = try harness.rows()
                return rows.count == 20 && Set(rows.compactMap(\.workspace)).count == 5 && rows.contains { ($0.rail ?? 0) > 1 }
            }
            sleep(seconds: 1)
            let work = try harness.stageWork()
            let given = try harness.motionGiven()
            // The counter proves idle zero work only once it has counted setup motion.
            if try harness.status().workspaces?.motion == "on" {
                try #require(work > setupWorkStart, "The stage counter must increase during setup motion before it can prove idle zero work; \(given)")
            }
            try verifyIdleResources("Carousel E24", stageWorkBefore: work)
        }
    }
}
