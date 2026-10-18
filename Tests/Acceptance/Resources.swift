import Foundation
import Testing

extension Acceptance {
    @Suite(AppSession())
    @MainActor
    struct Resources: AppSessionTest {
        init() throws { try Harness.shared.reset() }

        struct Budget: Decodable {
            let windowSeconds: Double
            let interruptWakeups: UInt64
            let cpuNanoseconds: UInt64
            let footprintBytes: UInt64
        }

        private func verifyIdleResources(_ example: String) throws {
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
        }

        @Test("#1 E22: idle resource budget") func e22TwentyIdleWindowsStayWithinWakeupCPUAndFootprintLimits() throws {
            for index in 0..<20 { _ = try fixture.open(key: "idle\(index)") }
            try #require(try converges(within: 2) { $0.count == 20 })
            sleep(seconds: 1)  // Let the bounded new-window settling work finish.
            try verifyIdleResources("E22")
        }

        @Test("#2 E36: resources across ten workspaces") func e36TwentyWindowsAcrossTenWorkspacesKeepTheFoundationBudget() throws {
            let flow = try Acceptance.FunctionalWorkspaces()
            try flow.enable()
            for index in 0..<20 {
                print("E36 preparing fixture window \(index + 1)/20")
                fflush(nil)
                let window = try fixture.open(key: "idle\(index)")
                try flow.activate(key: "idle\(index)")
                try flow.expectShown(window)
                if index.isMultiple(of: 2), index > 0 {
                    try flow.expectShown(window, since: flow.key(index / 2 + 1, send: true))
                }
            }
            try #require(try converges { rows in
                rows.count == 20 && Set(rows.compactMap(\.workspace)) == Set(1...10)
            })
            sleep(seconds: 1)
            try verifyIdleResources("E36")
        }
        @Test("#17 E29: rails idle resource budget") func e29RailsAcrossWorkspacesKeepTheIdleResourceBudget() throws {
            let flow = try Acceptance.FunctionalRails()
            try flow.enable()
            for index in 0..<20 {
                let id = try flow.open("idle\(index)", width: 0.4)
                try flow.flow.activate(key: "idle\(index)")
                try flow.focus(id)
                // Native focus can precede the catalog's new-window arrival.
                // Finish each setup command before opening the next fixture.
                try #require(try eventually { try harness.row(id)?.workspace == harness.status().workspaces?.active })
                if index.isMultiple(of: 2) {
                    let rail = try #require(try harness.row(id)?.rail)
                    try flow.focus(id, since: flow.flow.post(38, shift: true))
                    try #require(try eventually { try harness.row(id)?.rail == (index == 0 ? rail : rail + 1) })
                }
                if index.isMultiple(of: 4), index > 0 {
                    let workspace = index / 4 + 1
                    try flow.focus(id, since: flow.flow.key(workspace, send: true))
                    try #require(try eventually {
                        try harness.row(id)?.workspace == workspace && harness.status().workspaces?.active == workspace
                    })
                }
            }
            try #require(try converges { $0.count == 20 && Set($0.compactMap(\.workspace)).count == 5 && $0.contains { ($0.rail ?? 0) > 1 } })
            sleep(seconds: 1)
            try verifyIdleResources("Rails E29")
        }
    }
}
