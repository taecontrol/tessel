import Foundation
import Testing

@Suite struct LayerPinRemovalChecks {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let retiredIdentifiers = #"\b(?:pinned|togglePin|pinLayer|pinnedFrames|orderStage|pinnedRails|pinnedLayer|activationOrderDelay|delayNextActivationOrder|willReveal)\b"#

    @Test("#38 E7: retired layer state, commands and stage ordering have no implementation or scenarios")
    func retiredLayerImplementationIsAbsent() throws {
        for directory in ["Sources", "Tests"] {
            let files = try FileManager.default.subpathsOfDirectory(atPath: root.appending(path: directory).path)
                .filter { $0.hasSuffix(".swift") && $0 != "CheckTests/LayerPinRemovalChecks.swift" }.sorted()
            for file in files {
                let path = directory + "/" + file
                let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
                #expect(source.range(of: Self.retiredIdentifiers, options: .regularExpression) == nil, "retired layer implementation in \(path)")
                if directory == "Sources" { #expect(!source.contains("pin layer"), "retired command in \(path)") }
                if ["Sources/Ports/Stage.swift", "Sources/App/SystemMotionStage.swift", "Tests/Simulator/Simulator+Stage.swift"].contains(path) {
                    #expect(source.range(of: #"\b(?:func|case)\s+order\s*\("#, options: .regularExpression) == nil, "retired stage ordering in \(path)")
                    #expect(!source.contains("zPosition") && !source.contains("stacking"), "retired stand-in stacking in \(path)")
                }
            }
        }
        let captures = try String(contentsOf: root.appending(path: "Tests/Acceptance/CapturesLayer.swift"), encoding: .utf8)
        #expect(!captures.contains("#19 E11"), "the retired capture has no test")
        let fidelity = try String(contentsOf: root.appending(path: "Tests/Acceptance/LayerFidelity.swift"), encoding: .utf8)
        #expect(!fidelity.contains("kVK_ANSI_Z, shift: true"), "the fidelity walkthrough contains no pin steps")
    }

    @Test("the retired-layer absence guard rejects every removed identifier")
    func absenceGuardCanFail() {
        for identifier in ["pinned", "togglePin", "pinLayer", "pinnedFrames", "orderStage", "pinnedRails", "pinnedLayer", "activationOrderDelay", "delayNextActivationOrder", "willReveal"] {
            #expect("var \(identifier) = false".range(of: Self.retiredIdentifiers, options: .regularExpression) != nil)
        }
        #expect("var entry = Entry.rails".range(of: Self.retiredIdentifiers, options: .regularExpression) == nil)
    }
}
