import CoreGraphics
import Foundation
import Ports
import Simulator
import Testing
@testable import Policy

/// Generic window widths and selections from the accepted #18 prototype.
enum MapScene: String, CaseIterable {
    case single, short, floats, three, long, crowded
    var presets: [[Double]] {
        switch self {
        case .single: [[1]]
        case .short: [[1.0 / 3, 0.5], [1.0 / 3]]
        case .floats: [[2.0 / 3, 0.5, 1.0 / 3], [1]]
        case .three: [[0.5, 0.5, 2.0 / 3], [1.0 / 3, 1.0 / 3, 1.0 / 3, 0.5, 0.5], [1]]
        case .long: [[0.5, 2.0 / 3, 1.0 / 3, 0.5, 2.0 / 3, 1.0 / 3]]
        case .crowded: [[0.5, 0.5, 2.0 / 3, 1.0 / 3],
                       [1.0 / 3, 1.0 / 3, 1.0 / 3, 0.5, 0.5, 1.0 / 3, 2.0 / 3],
                       [1.0 / 3, 1.0 / 3, 2.0 / 3, 0.5, 0.5, 1.0 / 3, 0.5, 1.0 / 3, 2.0 / 3],
                       [1], [0.5, 0.5, 1.0 / 3]]
        }
    }
    var remembered: [Int] {
        switch self {
        case .single: [0]
        case .short: [0, 0]
        case .floats: [1, 0]
        case .three: [1, 2, 0]
        case .long: [3]
        case .crowded: [0, 4, 5, 0, 1]
        }
    }
    var current: Int { self == .three ? 1 : self == .crowded ? 2 : 0 }
    var floats: Int { self == .floats ? 3 : self == .crowded ? 2 : 0 }
    var cardSize: CGSize {
        switch self {
        case .single: CGSize(width: 42, height: 30)
        case .short: CGSize(width: 44, height: 44)
        case .floats: CGSize(width: 75, height: 45)
        case .three: CGSize(width: 76, height: 58)
        case .long: CGSize(width: 104, height: 30)
        case .crowded: CGSize(width: 156, height: 86)
        }
    }
    /// Independent input geometry: p*(1+g)-g, then the smallest initial reveal.
    func picture() -> MapPicture {
        let g = 10.0 / 1708
        let rails = presets.enumerated().map { r, values in
            var start = 0.0
            let spans = values.map { p -> MapPicture.Span in
                let width = p * (1 + g) - g
                defer { start += width + g }
                return MapPicture.Span(start: start, width: width)
            }
            let selected = spans[remembered[r]]
            return MapPicture.Rail(spans: spans, offset: max(0, selected.start + selected.width - 1), remembered: remembered[r])
        }
        return MapPicture(rails: rails, current: current, floats: floats, layerShown: false,
                          focus: .tile(remembered[current]), wall: nil, workspace: nil)
    }
}

@MainActor final class MapFixture {
    let s: Scenario
    let app: SimulatedApp
    let tessel: Tessel
    let rails: [[UInt32]]
    let floats: [UInt32]
    static let area = CGRect(x: 10, y: 43, width: 1708, height: 1064)
    var mac: SimulatedMac { s.mac }
    var shows: [(at: Int, picture: MapPicture, area: CGRect, transition: TimeInterval)] {
        mac.mapEvents.compactMap { event in
            if case .show(let picture, let area, let transition) = event.kind { (event.at, picture, area, transition) } else { nil }
        }
    }
    var hides: [SimulatedMac.MapEvent] {
        mac.mapEvents.filter { if case .hide = $0.kind { true } else { false } }
    }

    init(_ s: Scenario, scene: MapScene = .long, enabled: Bool = true, duration: Int = 1000,
         animation: Int = 250, reduced: Bool = false, recording: Bool = true,
         selection: [Int]? = nil, current: Int? = nil) {
        self.s = s
        s.mac.setScreen(ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                       visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084)))
        let app = s.mac.launch()
        self.app = app
        rails = scene.presets.map { rail in rail.map { p in
            app.open(WindowSpec(frame: CGRect(x: 40, y: 60, width: p * 1718 - 10, height: 1064), positionAcceptance: .screenEdges))
        } }
        floats = (0..<scene.floats).map { _ in app.open(WindowSpec(subrole: "AXFloatingWindow"), background: true) }
        app.select(rails[0][0])
        tessel = s.startTessel(text: "[animation]\nduration = 0\n")
        s.settle()
        // Establish rails through the real commands; never publish policy rows.
        for r in rails.indices.dropFirst() {
            for id in rails[r] {
                reachRail(0)
                reach(id, on: 0)
                for _ in 0..<r { key("alt-shift-j") }
            }
        }
        let remembered = selection ?? scene.remembered
        for r in rails.indices {
            reachRail(r)
            // Reset the stop before establishing the prototype's remembered tile.
            for _ in 0..<(rails[r].count * 3) { key("alt-h") }
            reach(rails[r][remembered[r]], on: r)
        }
        let target = current ?? scene.current
        reachRail(target)
        s.expect("setup has every prototype tile and float", Set(tessel.windows.map(\.id)) == Set(rails.flatMap { $0 } + floats))
        for r in rails.indices {
            s.expect("setup preserves prototype rail \(r + 1)", tessel.windows.filter { $0.rail == r + 1 }.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }.map(\.id) == rails[r])
        }
        s.expect("setup selects the prototype's remembered tile", mac.focusedWindow == rails[target][remembered[target]])
        s.expect("setup has no unmodeled platform calls", mac.scheduler.failure == nil)
        mac.setScreenRecording(recording)
        mac.setReduceMotion(reduced)
        s.settle()
        // Parser examples use changeConfig. Behavioral examples install the real
        // Configuration value so a parser failure cannot mask a missing map call.
        configure(enabled: enabled, duration: duration, animation: animation)
        s.settle()
        mac.clearMapHistory()
    }

    func configure(enabled: Bool = true, duration: Int = 1000, animation: Int = 250) {
        var configuration = Configuration()
        configuration.experiments["map"] = enabled
        configuration.map.duration = duration
        configuration.animation.duration = animation
        tessel.workspaces.configure(configuration)
    }
    func key(_ chord: String) { tessel.pressKey(chord); s.settle() }
    private func reachRail(_ rail: Int) {
        for _ in 0..<10 {
            if tessel.status.rail == rail + 1 { return }
            if mac.scheduler.failure != nil { break }
            key((tessel.status.rail ?? 1) > rail + 1 ? "alt-k" : "alt-j")
        }
        s.expect("setup reaches rail \(rail + 1)", false)
    }
    private func reach(_ id: UInt32, on rail: Int) {
        for _ in 0..<(rails.flatMap { $0 }.count * 4) {
            if mac.focusedWindow == id { return }
            if mac.scheduler.failure != nil { break }
            key("alt-l")
        }
        s.expect("setup reaches tile \(id) on rail \(rail + 1)", false)
    }
    func show(at time: Int) -> MapPicture? { shows.first { $0.at == time }?.picture }
    func expectHide(at time: Int, fade: TimeInterval = 0.12) {
        s.expect("one hide at \(time) with fade \(fade), got \(hides)", hides == [SimulatedMac.MapEvent(at: time, kind: .hide(fade: fade))])
    }
    func expectShown(at time: Int) {
        s.expect("the command shows a map at \(time), got \(shows.map(\.at))", show(at: time) != nil)
        s.expect("the port receives the primary inset area", shows.contains { $0.at == time && $0.area == Self.area })
    }
}

func mapSpansMatch(_ actual: [MapPicture.Span]?, _ expected: [MapPicture.Span]) -> Bool {
    guard let actual, actual.count == expected.count else { return false }
    return zip(actual, expected).allSatisfy { abs($0.start - $1.start) < 0.000001 && abs($0.width - $1.width) < 0.000001 }
}

func mapRailsMatch(_ actual: [MapPicture.Rail]?, _ expected: [MapPicture.Rail]) -> Bool {
    guard let actual, actual.count == expected.count else { return false }
    return zip(actual, expected).allSatisfy {
        $0.remembered == $1.remembered && abs($0.offset - $1.offset) < 0.000001 && mapSpansMatch($0.spans, $1.spans)
    }
}
