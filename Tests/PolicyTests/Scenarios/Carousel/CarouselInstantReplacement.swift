import CoreGraphics
import Ports
import Simulator
import Testing
@testable import Policy

@Suite @MainActor struct CarouselInstantReplacement {
    @Test("#33 E18: show the replacement before hiding the departure without an overlapping port state",
          arguments: WriteOrder.allCases)
    func workspaceReplacementHasNoOverlappingPortState(_ writes: WriteOrder) {
        requireCarousel(Scenario.run("instant singleton workspace replacement", writes: writes) { s in
            let mac = s.mac
            // The target Retina display is 3456 x 2234 pixels, 1728 x 1117 points.
            mac.setScreen(ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084)))
            let area = WorkspaceScenarios.area(mac)
            let firstApp = mac.launch(), secondApp = mac.launch()
            let spec = WindowSpec(frame: area, positionAcceptance: .screenEdges)
            let departing = firstApp.open(spec), returning = secondApp.open(spec)
            let closet = ObservedCloset(mac: mac, tiles: [departing, returning])
            let tessel = s.startTessel(text: "[experiments]\nlayer = true\n[animation]\nduration = 0\n",
                                      makeCloset: { closet })
            s.settle()
            tessel.press("send 2"); s.settle()
            tessel.press("workspace 1"); s.settle()
            s.expect("the two workspaces each own one tile",
                     tessel.windows.first { $0.id == departing }?.workspace == 1
                        && tessel.windows.first { $0.id == returning }?.workspace == 2)
            s.expect("the departing tile is visible and the replacement is in the closet",
                     mac.isVisible(departing) && mac.isInCloset(returning))
            s.expect("both tiles already have their final full-area frame",
                     mac.frame(departing) == area && mac.frame(returning) == area)
            closet.states.removeAll()
            mac.clearMotionHistory()

            s.step("switch to the replacement's workspace") { tessel.press("workspace 2") }
            s.settle()

            s.expect("the replacement is visible and the departure is hidden after the switch",
                     tessel.status.active == 2 && mac.isVisible(returning) && mac.isInCloset(departing))
            let showing = closet.states.firstIndex { $0.showing && $0.windows.contains(returning) }
            let hiding = closet.states.firstIndex { !$0.showing && $0.windows.contains(departing) }
            s.expect("the replacement is shown before the departure is hidden",
                     showing != nil && hiding != nil && showing! < hiding!)
            for state in closet.states {
                for (index, a) in state.frames.enumerated() {
                    for b in state.frames.dropFirst(index + 1) {
                        let overlap = a.frame.intersection(b.frame)
                        s.expect("after ClosetPort.\(state.showing ? "show" : "hide") \(state.windows), visible tiles \(a.id) and \(b.id) must not overlap; overlap=\(overlap)",
                                 overlap.isNull || overlap.width <= 1 || overlap.height <= 1)
                    }
                }
            }
        })
    }
}

/// Observe the existing simulated closet after each operation without changing
/// its native semantics. CG membership includes a tile covered by another tile.
@MainActor private final class ObservedCloset: ClosetPort {
    struct State {
        let showing: Bool
        let windows: [UInt32]
        let frames: [(id: UInt32, frame: CGRect)]
    }
    private let mac: SimulatedMac
    private let tiles: Set<UInt32>
    private let base: any ClosetPort
    var states: [State] = []

    init(mac: SimulatedMac, tiles: Set<UInt32>) {
        self.mac = mac
        self.tiles = tiles
        base = mac.closetPort
    }
    func start() throws { try base.start() }
    func hide(_ windows: [UInt32]) { base.hide(windows); record(windows, showing: false) }
    func show(_ windows: [UInt32]) { base.show(windows); record(windows, showing: true) }
    func stop(returning windows: [UInt32]) { base.stop(returning: windows) }
    func memberships(_ window: UInt32, scope: SpaceScope) -> [SpaceToken] { base.memberships(window, scope: scope) }
    func activeSpace() -> SpaceToken { base.activeSpace() }
    var closetSpace: SpaceToken { base.closetSpace }

    private func record(_ windows: [UInt32], showing: Bool) {
        guard !windows.isEmpty else { return }
        let frames = tiles.sorted().compactMap { id -> (id: UInt32, frame: CGRect)? in
            guard mac.isVisible(id), let frame = mac.frame(id) else { return nil }
            return (id, frame)
        }
        states.append(State(showing: showing, windows: windows, frames: frames))
    }
}
