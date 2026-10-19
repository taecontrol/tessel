import CoreGraphics
import Foundation
import Ports
import Simulator
import Testing
@testable import Policy

/// Exercise the real catalog and presenter, including AX acceptance and readback.
@MainActor struct CarouselFixture {
    let s: Scenario
    let app: SimulatedApp
    let tessel: Tessel
    let ids: [UInt32]
    let area: CGRect
    var mac: SimulatedMac { s.mac }
    static let config = "[experiments]\ncarousel = true\n"

    init(_ s: Scenario, presets: [Double] = [0.5, 0.5, 0.5], duration: Int = 80, reduced: Bool = false, minimumFractions: [Int:Double] = [:]) {
        self.s = s
        s.mac.setScreen(ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                       visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084)))
        area = CGRect(x: 10, y: 43, width: 1708, height: 1064)
        s.mac.setReduceMotion(reduced)
        let app = s.mac.launch()
        self.app = app
        ids = presets.enumerated().map { index, p in
            var spec = WindowSpec(frame: CGRect(x: 40, y: 60, width: p * 1718 - 10, height: 1064), minimumSize: CGSize(width: max(1,(minimumFractions[index] ?? 0) * 1708), height: 1), positionAcceptance: .screenEdges)
            spec.closetHeightLoss = 312
            return app.open(spec)
        }
        if let id = ids.first { app.select(id) }
        tessel = s.startTessel()
        s.settle()
        configure(duration: duration)
        s.settle()
        #expect(tessel.windows.map(\.id) == ids, "Setup must enumerate every fixture window")
        #expect(s.mac.scheduler.failure == nil, "Setup must reach the real policy without unmodeled calls")
        s.expect("carousel is the active layout", tessel.status.layout == "carousel")
    }
    func configure(duration: Int) {
        let text = Self.config + "[animation]\nduration = \(duration)\n"
        tessel.changeConfig(text)
    }
    func press(_ key: String) { s.step(key) { tessel.pressKey(key) }; s.settle() }
    func select(_ id: UInt32) { app.select(id); s.settle() }
    func open(minimum: Double = 1, maximum: Double = 100_000) -> UInt32 {
        var spec = WindowSpec(frame: CGRect(x: 40, y: 60, width: 451, height: 400),
                              minimumSize: CGSize(width: minimum, height: 1),
                              maximumSize: CGSize(width: maximum, height: 100_000), positionAcceptance: .screenEdges)
        spec.closetHeightLoss = 312
        let id = app.open(spec); s.settle(); return id
    }
    func frame(_ id: UInt32) -> CGRect { mac.frame(id)! }
    func width(_ p: Double) -> Double { p * (area.width + 10) - 10 }
    func near(_ actual: Double, _ expected: Double, _ label: String) {
        s.expect("\(label): expected \(expected), got \(actual)", abs(actual - expected) <= 1)
    }
    func focus(_ id: UInt32) {
        s.expect("focus is window \(id), got \(String(describing: mac.focusedWindow))", mac.focusedWindow == id)
        s.expect("focused window \(id) is complete in the area", mac.isVisible(id) && contains(frame(id)))
    }
    func contains(_ r: CGRect) -> Bool {
        r.minX >= area.minX - 1 && r.maxX <= area.maxX + 1 && r.minY >= area.minY - 1 && r.maxY <= area.maxY + 1
    }
    func pair(_ a: UInt32, _ b: UInt32, focused: UInt32) {
        focus(focused)
        near(frame(a).minX, area.minX, "left half starts at the area")
        near(frame(b).maxX, area.maxX, "right half ends at the area")
        near(frame(a).width, width(0.5), "left half width uses p·(area+gap)−gap")
        near(frame(b).width, width(0.5), "right half width uses p·(area+gap)−gap")
        near(frame(b).minX - frame(a).maxX, 10, "pair gap")
        for id in [a,b] {
            near(frame(id).minY, area.minY, "tile is at the area top")
            near(frame(id).height, area.height, "unconstrained tile fills the area height")
        }
    }
    func expanded(_ id: UInt32) {
        focus(id); near(frame(id).minX, area.minX, "expanded left")
        near(frame(id).width, area.width, "expanded width")
        near(frame(id).minY, area.minY, "expanded top")
        near(frame(id).height, area.height, "expanded height")
    }
    func order(_ ids: [UInt32], rail: Int = 1, workspace: Int = 1) {
        let actual = tessel.windows.filter { $0.workspace == workspace && $0.rail == rail }.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }
        s.expect("rail \(rail) order is \(ids), got \(actual.map(\.id))", actual.map(\.id) == ids)
    }
    func unchanged(_ before: [UInt32: CGRect]) {
        for id in before.keys.sorted() { s.expect("window \(id) returns to its exact frame", mac.frame(id) == before[id]) }
    }
    func snapshot(_ ids: [UInt32]? = nil) -> [UInt32: CGRect] {
        Dictionary(uniqueKeysWithValues: (ids ?? self.ids).map { ($0, frame($0)) })
    }
    func invariants(_ context: String) {
        let rows = tessel.windows.filter { $0.workspace == tessel.status.active && $0.rail == tessel.status.rail && $0.state == .tiled }
        guard !rows.isEmpty else { return } // Closing the final tile intentionally leaves an empty workspace.
        let frames = rows.filter { mac.isVisible($0.id) }.map { frame($0.id) }
        s.expect("\(context): a populated rail is never empty on screen", frames.contains { $0.intersects(area) })
        for uncovered in uncoveredWidths(in: area, coveredBy: frames) {
            s.expect("\(context): no uncovered span exceeds the gap (\(uncovered))", uncovered <= 11)
        }
        s.expect("\(context): focus belongs to a complete visible tile", rows.contains { $0.id == mac.focusedWindow && mac.isVisible($0.id) && contains(frame($0.id)) })
    }
}

func requireCarousel(_ result: ScenarioResult, sourceLocation: SourceLocation = #_sourceLocation) {
    if !result.failures.isEmpty {
        Issue.record(Comment(rawValue: result.failures.prefix(40).joined(separator: "\n")
            + "\nSchedule: " + result.schedule.joined(separator: " → ")
            + "\nTrace tail:\n" + result.trace.suffix(20).joined(separator: "\n")), sourceLocation: sourceLocation)
    }
}

/// Independent coverage oracle; even an empty sample must report the whole hole.
func uncoveredWidths(in area: CGRect, coveredBy frames: [CGRect]) -> [Double] {
    let spans = frames.map { $0.intersection(area) }.filter { !$0.isNull && $0.width > 0 }.sorted { $0.minX < $1.minX }
    var edge = area.minX, holes: [Double] = []
    for span in spans { holes.append(Double(max(0,span.minX-edge))); edge = max(edge,span.maxX) }
    holes.append(Double(max(0,area.maxX-edge)))
    return holes
}
