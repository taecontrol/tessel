import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

/// Compile scaffolding for #18's red acceptance tests; behavior follows later.
@MainActor final class RailsMap {
    init(port: (any RailsMapPort)?, scheduler: any SchedulingPort) {}
    func configure(enabled: Bool, duration: Int, motion: Bool) {}
    func command(_ picture: MapPicture, in area: CGRect) {}
    func refresh(_ picture: MapPicture, in area: CGRect) {}
    func dismiss() {}
}
