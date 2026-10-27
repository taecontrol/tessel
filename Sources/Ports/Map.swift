import CoreGraphics
import Foundation

package struct MapPicture: Equatable, Sendable {
    package struct Span: Equatable, Sendable {
        package var start: Double
        package var width: Double
        package init(start: Double, width: Double) { self.start = start; self.width = width }
    }
    package struct Rail: Equatable, Sendable {
        package var spans: [Span]
        package var offset: Double
        package var remembered: Int
        package init(spans: [Span], offset: Double, remembered: Int) {
            self.spans = spans; self.offset = offset; self.remembered = remembered
        }
    }
    package enum Focus: Equatable, Sendable { case tile(Int), float(Int) }
    package enum Wall: Equatable, Sendable { case left, right, up, down }
    package var rails: [Rail]
    package var current: Int?
    package var floats: Int
    package var layerShown: Bool
    package var focus: Focus?
    package var wall: Wall?
    package var workspace: Int?
    package init(rails: [Rail], current: Int?, floats: Int, layerShown: Bool,
                 focus: Focus?, wall: Wall?, workspace: Int?) {
        self.rails = rails; self.current = current; self.floats = floats
        self.layerShown = layerShown; self.focus = focus; self.wall = wall; self.workspace = workspace
    }
}

@MainActor package protocol RailsMapPort: AnyObject {
    /// Replaces the shown or fading picture, bottom right of the area.
    func show(_ picture: MapPicture, in area: CGRect, transition: TimeInterval)
    /// Orders the window out after the fade; zero hides immediately.
    func hide(fade: TimeInterval)
}
