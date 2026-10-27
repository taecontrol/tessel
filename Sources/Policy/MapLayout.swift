import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

/// Compile scaffolding. Marks describe drawing primitives in card coordinates.
struct MapLayout {
    struct Mark: Equatable {
        enum Kind: Equatable {
            case track(Int), viewport(Int), tile(rail: Int, slot: Int)
            case seen(rail: Int, slot: Int), float(Int), wall(MapPicture.Wall), workspace(Int)
        }
        enum Ink: Equatable { case track, viewport, mark, seen, remembered, accent, wall }
        let kind: Kind
        let rect: CGRect
        let fill: Ink?
        let stroke: Ink?
        let lineWidth: Double
    }
    let size: CGSize
    let marks: [Mark]

    init(_ picture: MapPicture, in area: CGRect) { size = .zero; marks = [] }
}
