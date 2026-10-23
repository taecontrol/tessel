import Foundation
import Testing

@Suite struct LayerPinRemovalChecks {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let retiredCode: [String: [String]] = [
        "Sources/Shared/KeyChord.swift": [#"\bcase\s+(?:\w+\s*,\s*)*pinLayer\b"#, #""pin layer""#],
        "Sources/Policy/FloatingLayer.swift": [#"\b(?:var|let)\s+pinned\b"#, #"\bfunc\s+togglePin\s*\("#],
        "Sources/Policy/Workspaces.swift": [#"\b(?:func|var|let)\s+(?:orderStage|pinnedFrames)\b"#],
        "Sources/Ports/Stage.swift": [#"\bfunc\s+order\s*\("#],
        "Sources/App/SystemMotionStage.swift": [#"\bfunc\s+order\s*\("#],
        "Tests/Simulator/Simulator+Stage.swift": [#"\b(?:func|case)\s+order\s*\("#],
        "Tests/PolicyTests/Scenarios/Layer/LayerFixture.swift": [#"\bcase\s+(?:\w+\s*,\s*)*(?:pinnedRails|pinnedLayer)\b"#],
        "Tests/Acceptance/CapturesLayer.swift": [#"\bfunc\s+capturePinnedFloatsAboveMovingRails\s*\("#, ##"@Test\s*\(\s*"#19 E11\b"##],
        "Tests/Acceptance/LayerFidelity.swift": [#"\bpost\s*\(\s*kVK_ANSI_Z\s*,\s*shift\s*:\s*true\b"#],
    ]

    private static func violations(in source: String, at path: String) -> [String] {
        let code = source.replacingOccurrences(of: #"(?s)/\*.*?\*/|//[^\r\n]*"#, with: " ", options: .regularExpression)
        return (retiredCode[path] ?? []).filter { code.range(of: $0, options: .regularExpression) != nil }
    }

    @Test("#38 E7: retired layer state, commands and stage ordering have no implementation or scenarios")
    func retiredLayerImplementationIsAbsent() throws {
        for path in Self.retiredCode.keys.sorted() {
            let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            #expect(Self.violations(in: source, at: path).isEmpty, "retired layer declaration or wiring in \(path)")
        }
    }

    @Test("the retired-layer guard rejects declarations and wiring in their owning files, and accepts comments")
    func absenceGuardCanFail() {
        let retired = [
            ("Sources/Shared/KeyChord.swift", "enum Command { case toggleLayer, pinLayer, toggleFloat }"),
            ("Sources/Shared/KeyChord.swift", #"case "pin layer": self = .pinLayer"#),
            ("Sources/Policy/FloatingLayer.swift", "var pinned = false"),
            ("Sources/Policy/FloatingLayer.swift", "mutating func togglePin() {}"),
            ("Sources/Policy/Workspaces.swift", "private func orderStage() {}"),
            ("Sources/Policy/Workspaces.swift", "private var pinnedFrames: [UInt32: CGRect] = [:]"),
            ("Sources/Ports/Stage.swift", "func order(_ windows: [UInt32])"),
            ("Sources/App/SystemMotionStage.swift", "func order(_ windows: [UInt32]) {}"),
            ("Tests/Simulator/Simulator+Stage.swift", "func order(_ windows: [UInt32]) {}"),
            ("Tests/Simulator/Simulator+Stage.swift", "case order([UInt32])"),
            ("Tests/PolicyTests/Scenarios/Layer/LayerFixture.swift", "enum LayerMode { case hidden, pinnedRails, pinnedLayer }"),
            ("Tests/PolicyTests/Scenarios/Layer/LayerFixture.swift", "enum LayerMode { case shown, pinnedLayer }"),
            ("Tests/Acceptance/CapturesLayer.swift", "func capturePinnedFloatsAboveMovingRails() {}"),
            ("Tests/Acceptance/CapturesLayer.swift", ##"@Test("#19 E11: retired capture") func capture() {}"##),
            ("Tests/Acceptance/LayerFidelity.swift", "try desktop.post(kVK_ANSI_Z, shift: true)"),
        ]
        for (path, source) in retired {
            #expect(!Self.violations(in: source, at: path).isEmpty, "the guard must reject \(source) in \(path)")
            #expect(Self.violations(in: "// " + source, at: path).isEmpty)
            #expect(Self.violations(in: "/*\n" + source + "\n*/", at: path).isEmpty)
        }
        for path in Self.retiredCode.keys {
            #expect(Self.violations(in: "// This assumption is pinned by its native contract.", at: path).isEmpty)
            #expect(Self.violations(in: "var zPosition = 0; var stacking = 0; var activationOrderDelay = 0; func delayNextActivationOrder() {}; func willReveal() {}", at: path).isEmpty)
        }
        #expect(Self.violations(in: "var pinned = false", at: "Sources/Shared/KeyChord.swift").isEmpty)
    }
}
