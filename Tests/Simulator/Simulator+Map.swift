import CoreGraphics
import Foundation
import Ports

extension SimulatedMac {
    package enum MapEventKind: Equatable, Sendable {
        case show(MapPicture, area: CGRect, transition: TimeInterval)
        case hide(fade: TimeInterval)
    }
    package struct MapEvent: Equatable, Sendable {
        package let at: Int
        package let kind: MapEventKind
        package init(at: Int, kind: MapEventKind) { self.at = at; self.kind = kind }
    }
    @MainActor package var map: any RailsMapPort { Map(mac: self) }
    @MainActor package var mapEvents: [MapEvent] { mapHistory }
    @MainActor package func clearMapHistory() { mapHistory.removeAll() }

    @MainActor private final class Map: RailsMapPort {
        let mac: SimulatedMac
        init(mac: SimulatedMac) { self.mac = mac }
        func show(_ picture: MapPicture, in area: CGRect, transition: TimeInterval) {
            mac.assume(.mapOverlay)
            mac.scheduler.call("RailsMapPort.show")
            mac.mapHistory.append(MapEvent(at: mac.scheduler.now, kind: .show(picture, area: area, transition: transition)))
            mac.scheduler.note("map show \(picture) in \(area) transition=\(transition)")
        }
        func hide(fade: TimeInterval) {
            mac.scheduler.call("RailsMapPort.hide")
            mac.mapHistory.append(MapEvent(at: mac.scheduler.now, kind: .hide(fade: fade)))
            mac.scheduler.note("map hide fade=\(fade)")
        }
    }
}
