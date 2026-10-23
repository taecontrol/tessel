import CoreGraphics
import Foundation
import Simulator
import Testing
@testable import Policy

enum LayerMode: String, CaseIterable {
    case hidden, single, shown
}

/// Only app/user actions and published observations; no layer policy lives here.
@MainActor struct LayerFixture {
    static let config = "[experiments]\nlayer = true\n"
    let s: Scenario
    let app: SimulatedApp
    let tessel: Tessel
    let tiles: [UInt32]
    let floats: [UInt32]
    let area: CGRect
    var mac: SimulatedMac { s.mac }

    init(_ s: Scenario, tileCount: Int = 3,
         floatSpecs: [WindowSpec] = [WindowSpec(subrole: "AXFloatingWindow"), WindowSpec(subrole: "AXDialog")],
         startup: Bool = false, focusedFloat: Bool = false, duration: Int = 0) {
        self.s = s
        let screen = s.mac.screens.primaryScreen!
        area = CGRect(x: screen.visibleFrame.minX + 10, y: screen.frame.maxY - screen.visibleFrame.maxY + 10,
                      width: screen.visibleFrame.width - 20, height: screen.visibleFrame.height - 20)
        let app = s.mac.launch()
        self.app = app
        tiles = (0..<tileCount).map { _ in app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: (screen.visibleFrame.width - 30) / 2, height: 400))) }
        floats = floatSpecs.map { app.open($0, background: true) }
        if let id = focusedFloat ? floats.first : tiles.first { app.select(id) }
        let text = Self.config + "[animation]\nduration = \(duration)\n"
        tessel = s.startTessel(text: startup ? text : nil)
        s.settle()
        if !startup { tessel.changeConfig(text); s.settle() }
        s.expect("layer configuration is accepted (actual: \(tessel.configuration.error?.message ?? tessel.configuration.state))",
                 tessel.configuration.error == nil)
        s.expect("layer enables the carousel", tessel.status.enabled && tessel.status.layout == "carousel")
        s.expect("every invented window reaches the catalog", Set(tessel.windows.map(\.id)) == Set(tiles + floats))
    }

    func press(_ command: String) {
        s.step(command) { tessel.press(command) }; s.settle()
    }
    func key(_ chord: String) {
        s.step(chord) { tessel.pressKey(chord) }; s.settle()
    }
    func select(_ id: UInt32) { s.step("external focus \(id)") { app.select(id) }; s.settle() }
    @discardableResult func open(_ spec: WindowSpec = WindowSpec(subrole: "AXDialog"), background: Bool = false) -> UInt32 {
        let id = app.open(spec, background: background); s.settle(); return id
    }
    func close(_ id: UInt32) { app.close(id); s.settle() }
    func row(_ id: UInt32) -> WindowRecord? { tessel.windows.first { $0.id == id } }
    func frame(_ id: UInt32) -> CGRect { mac.frame(id)! }
    func frames(_ ids: [UInt32]) -> [UInt32: CGRect] { Dictionary(uniqueKeysWithValues: ids.map { ($0, frame($0)) }) }
    func unchanged(_ before: [UInt32: CGRect]) {
        for id in before.keys.sorted() { s.expect("window \(id) keeps its frame", mac.frame(id) == before[id]) }
    }
    func focus(_ id: UInt32) {
        s.expect("window \(id) has keyboard focus, got \(String(describing: mac.focusedWindow))", mac.focusedWindow == id)
        s.expect("focused window \(id) is outside the closet", !mac.isInCloset(id) && mac.isVisible(id))
    }
    func visible(_ ids: [UInt32], _ expected: Bool) {
        for id in ids {
            s.expect("window \(id) published visible=\(expected)", row(id)?.visible == expected)
            s.expect("window \(id) native visible=\(expected)", mac.isVisible(id) == expected)
            s.expect("window \(id) closet membership is inverse visibility", mac.isInCloset(id) == !expected)
        }
    }
    func state(_ state: String, focused: Bool) {
        let json = encodedObject(tessel.status), layer = json["layer"] as? [String: Any]
        s.expect("workspaces.layer.state=\(state), got \(String(describing: layer))", layer?["state"] as? String == state)
        s.expect("workspaces.layer.focused=\(focused)", layer?["focused"] as? Bool == focused)
    }
    func classification(_ id: UInt32, _ state: String, _ reason: String) {
        s.expect("window \(id) is \(state): \(reason)", row(id)?.state.rawValue == state && row(id)?.reason == reason)
    }
    func order(_ ids: [UInt32], rail: Int = 1, workspace: Int = 1) {
        let rows = tessel.windows.filter { $0.workspace == workspace && $0.rail == rail }.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }
        s.expect("workspace \(workspace) rail \(rail) order=\(ids), got \(rows.map(\.id))", rows.map(\.id) == ids)
        s.expect("rail slots stay contiguous", rows.enumerated().allSatisfy { $0.element.slot == $0.offset + 1 })
    }
    func near(_ actual: Double, _ expected: Double, _ message: String) {
        s.expect("\(message): expected \(expected), got \(actual)", abs(actual - expected) <= 1)
    }
    var captureRequests: [SimulatedMac.StageCaptureRequest] { mac.stageCaptureRequests }
    var captures: [UInt32] { captureRequests.filter { !$0.refreshing }.flatMap { $0.windows.sorted() } }
    func closetMoves(showing: Bool) -> [UInt32] { mac.visibilityChanges.filter { $0.showing == showing }.flatMap(\.windows) }
    var axWrites: [String] { Self.axWrites(in: mac.scheduler.trace) }
    static func axWrites(in trace: [String]) -> [String] {
        trace.filter { ($0.contains("AccessibilityPort.set ") || $0.contains("AccessibilityPort.perform ")) && !$0.contains(" reply ") }
    }
    /// Exercise each row of the accepted state table through ordinary commands.
    @discardableResult func enter(_ mode: LayerMode) -> UInt32? {
        switch mode {
        case .hidden: state("hidden", focused: false); return nil
        case .single:
            let id = open(); state("single", focused: true); return id
        case .shown: press("toggle layer"); state("shown", focused: true)
        }
        return mac.focusedWindow
    }
}

func requireLayer(_ result: ScenarioResult, sourceLocation: SourceLocation = #_sourceLocation) {
    requireCarousel(result, sourceLocation: sourceLocation)
}
