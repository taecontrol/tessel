import Foundation
import Testing
@testable import Policy

@MainActor enum FoundationProof {
    static func row(_ id: UInt32, in tessel: Tessel, state: WindowState, reason: String, tabs: Int = 1,
                    scenario: Scenario) {
        let row = tessel.windows.first { $0.id == id }
        scenario.expect("window \(id) is \(state.rawValue), reason '\(reason)', tabs=\(tabs) (actual \(row?.state.rawValue ?? "absent"), '\(row?.reason ?? "")', \(row?.tabs ?? 0))",
                        row?.state == state && row?.reason == reason && row?.tabs == tabs)
    }

    static func snapshot(_ rows: [WindowRecord]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(rows)
    }

    static func publication(_ tessel: Tessel, pid: Int32, since start: Int, within milliseconds: Int,
                            scenario: Scenario, matching: ([WindowRecord]) -> Bool) {
        let publication = tessel.windowPublications.first { $0.pid == pid && $0.at >= start && matching($0.windows ?? []) }
        scenario.expect("matching rows published before \(start + milliseconds)ms (actual \(publication.map { "\($0.at)ms" } ?? "never"))",
                        publication.map { $0.at - start < milliseconds } == true)
    }
}
