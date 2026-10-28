import CoreGraphics
import Ports
import Testing
@testable import Policy

@Suite struct MapGeometry {
    private let area = CGRect(x: 10, y: 43, width: 1708, height: 1064)

    @Test("#18 E21: prototype scenes retain their measured card sizes, scale, gaps, pitch and padding", arguments: MapScene.allCases)
    func prototypeCardSizes(_ scene: MapScene) throws {
        let picture = scene.picture(), layout = MapLayout(picture, in: area)
        #expect(abs(layout.size.width - scene.cardSize.width) <= 2, "\(scene): card width from the accepted prototype")
        #expect(abs(layout.size.height - scene.cardSize.height) <= 2, "\(scene): card height from the accepted prototype")
        let first = try mark(.tile(rail: 0, slot: 0), in: layout)
        #expect(abs(first.rect.width - picture.rails[0].spans[0].width * 26) < 0.001, "26 points per area width")
        #expect(abs(first.rect.minX - 8) < 0.001, "six-point drawing padding inside the two-point card border/padding")
        for r in picture.rails.indices {
            for i in picture.rails[r].spans.indices.dropFirst() {
                let previous = try mark(.tile(rail: r, slot: i - 1), in: layout)
                let next = try mark(.tile(rail: r, slot: i), in: layout)
                #expect(abs(next.rect.minX - previous.rect.maxX - 2) < 0.001, "two-point gaps keep every tile countable")
            }
            if r > 0 {
                let previous = try mark(.track(r - 1), in: layout), next = try mark(.track(r), in: layout)
                #expect(abs(next.rect.midY - previous.rect.midY - 14) < 0.001, "fourteen-point rail pitch")
            }
        }
        #expect(layout.marks.allSatisfy { $0.rect.minX >= 0 && $0.rect.minY >= 0
            && $0.rect.maxX <= layout.size.width && $0.rect.maxY <= layout.size.height })
    }

    @Test("#18 E21; #18 E23: Carousel exports normalized spans, independent offsets and remembered indices for every prototype rail", arguments: MapScene.allCases)
    func carouselMapRails(_ scene: MapScene) {
        let expected = scene.picture()
        var carousel = Carousel(width: 1708, gap: 10)
        var nextID: UInt32 = 1
        let rails = scene.presets.enumerated().map { r, presets in
            let tiles = presets.map { p -> Carousel.Tile in
                defer { nextID += 1 }
                return Carousel.Tile(id: nextID, size: CGSize(width: p * 1718 - 10, height: 1064), preset: p)
            }
            return Carousel.Rail(identity: UInt64(r + 1), tiles: tiles, offset: expected.rails[r].offset * 1708,
                                 focused: tiles[scene.remembered[r]].id)
        }
        carousel.workspaces[1] = Carousel.Workspace(rails: rails, current: scene.current)
        let actual = carousel.mapRails(1)
        #expect(actual.current == scene.current)
        #expect(actual.rails.count == expected.rails.count)
        for (actual, expected) in zip(actual.rails, expected.rails) {
            #expect(actual.remembered == expected.remembered)
            #expect(abs(actual.offset - expected.offset) < 0.000001)
            #expect(actual.spans.count == expected.spans.count)
            for (a, e) in zip(actual.spans, expected.spans) {
                #expect(abs(a.start - e.start) < 0.000001 && abs(a.width - e.width) < 0.000001)
            }
        }
        #expect(carousel.mapRails(10).rails.isEmpty && carousel.mapRails(10).current == nil)
    }

    @Test("#18 E22: an enormous workspace reduces scale and fits both one-third-area bounds", arguments: [CGSize(width: 1708, height: 1064), CGSize(width: 600, height: 300)])
    func hugeWorkspaceFitsTheAreaCap(_ size: CGSize) throws {
        let spans = (0..<64).map { MapPicture.Span(start: Double($0) * 1.01, width: 1) }
        let rail = MapPicture.Rail(spans: spans, offset: 0, remembered: 0)
        let picture = MapPicture(rails: Array(repeating: rail, count: 40), current: 0, floats: 2,
                                 layerShown: false, focus: .tile(0), wall: nil, workspace: nil)
        let layout = MapLayout(picture, in: CGRect(origin: .zero, size: size))
        #expect(layout.size.width > 0 && layout.size.height > 0, "the cap must produce a card")
        #expect(layout.size.width <= size.width / 3 && layout.size.height <= size.height / 3,
                "the full card, including its padding and floats, fits one third of the actual area")
        let first = try mark(.tile(rail: 0, slot: 0), in: layout)
        #expect(first.rect.width > 0 && first.rect.width < 26, "reduce the scale rather than cropping long rails")
        let tiles = layout.marks.filter { if case .tile = $0.kind { true } else { false } }
        #expect(tiles.count == 64 * 40, "all rails and tiles remain represented")
        #expect(layout.marks.allSatisfy { $0.rect.minX >= 0 && $0.rect.minY >= 0
            && $0.rect.maxX <= size.width / 3 && $0.rect.maxY <= size.height / 3 })
    }

    @Test("#18 E22: a tall narrow workspace reaches the height cap before the width cap")
    func tallWorkspaceHitsHeightCapFirst() throws {
        let rail = MapPicture.Rail(spans: [MapPicture.Span(start: 0, width: 1)], offset: 0, remembered: 0)
        let picture = MapPicture(rails: Array(repeating: rail, count: 80), current: 0, floats: 0,
                                 layerShown: false, focus: .tile(0), wall: nil, workspace: nil)
        let layout = MapLayout(picture, in: area)
        // Eighty 14-point rows plus 16 points of card padding: 42 by 1136
        // before reduction. Only the height exceeds one third of this area.
        let reduction = (1064.0 / 3) / 1136
        #expect(abs(layout.size.height - 1064.0 / 3) < 0.001)
        #expect(abs(layout.size.width - 42 * reduction) < 0.001)
        let first = try mark(.tile(rail: 0, slot: 0), in: layout)
        #expect(abs(first.rect.width - 26 * reduction) < 0.001, "the height cap reduces scale without cropping")
        #expect(layout.marks.filter { if case .tile = $0.kind { true } else { false } }.count == 80)
        #expect(layout.marks.allSatisfy { $0.rect.minX >= 0 && $0.rect.minY >= 0
            && $0.rect.maxX <= area.width / 3 && $0.rect.maxY <= area.height / 3 })
    }

    @Test("#18 E23: viewport edges inside desktop gaps interpolate within the expanded two-point gaps")
    func viewportEdgesInterpolateDesktopGaps() throws {
        let rail = MapPicture.Rail(spans: [MapPicture.Span(start: 0, width: 0.4),
                                          MapPicture.Span(start: 0.6, width: 0.8),
                                          MapPicture.Span(start: 1.6, width: 0.4)], offset: 0.5, remembered: 1)
        let picture = MapPicture(rails: [rail], current: 0, floats: 0,
                                 layerShown: false, focus: .tile(1), wall: nil, workspace: nil)
        let viewport = try mark(.viewport(0), in: MapLayout(picture, in: area))
        // Edges at 0.5 and 1.5 bisect [0.4, 0.6] and [1.4, 1.6]. Each
        // midpoint adds one point after the preceding tile's scaled end.
        let left = 8 + 0.4 * 26 + 1
        let right = 8 + 0.4 * 26 + 2 + 0.8 * 26 + 1
        #expect(abs(viewport.rect.minX + 2 - left) < 0.001, "the leading edge lies one point into its gap")
        #expect(abs(viewport.rect.maxX - 2 - right) < 0.001, "the trailing edge lies one point into its gap")
    }

    @Test("#18 E23: tile marks encode focus, remembered height and clipped visible fill")
    func tileMarksAndViewportClipping() throws {
        let g = 10.0 / 1708, half = 0.5 * (1 + g) - g
        let spans = (0..<3).map { MapPicture.Span(start: Double($0) * (half + g), width: half) }
        let picture = MapPicture(rails: [MapPicture.Rail(spans: spans, offset: 0.25, remembered: 1),
                                        MapPicture.Rail(spans: Array(spans.prefix(2)), offset: 0, remembered: 1)],
                                 current: 0, floats: 0, layerShown: false, focus: .tile(1), wall: nil, workspace: nil)
        let layout = MapLayout(picture, in: area)
        let first = try mark(.tile(rail: 0, slot: 0), in: layout)
        let focused = try mark(.tile(rail: 0, slot: 1), in: layout)
        let last = try mark(.tile(rail: 0, slot: 2), in: layout)
        let viewport = try mark(.viewport(0), in: layout)
        #expect([first, focused, last].allSatisfy { $0.rect.height == 8 }, "current-rail marks are eight points tall")
        let ordinary = try mark(.tile(rail: 1, slot: 0), in: layout), remembered = try mark(.tile(rail: 1, slot: 1), in: layout)
        #expect(ordinary.rect.height == 4 && remembered.rect.height == 7)
        let whollySeen = try mark(.seen(rail: 1, slot: 0), in: layout)
        #expect(whollySeen.rect == ordinary.rect && whollySeen.fill == .seen, "a complete ordinary tile is filled across its whole mark")
        #expect(remembered.fill == .remembered, "the remembered tile uses the stronger neutral ink")
        #expect(focused.fill == .accent)
        #expect(layout.marks.filter { $0.fill == .accent || $0.stroke == .accent }.count == 1, "focus is the sole accent mark")
        #expect(first.fill == nil && first.stroke == .mark && first.lineWidth == 1)
        #expect(last.fill == nil && last.stroke == .mark, "the full mark remains hollow beneath the visible portion")
        let firstSeen = try mark(.seen(rail: 0, slot: 0), in: layout)
        let lastSeen = try mark(.seen(rail: 0, slot: 2), in: layout)
        // The visor has a two-point surround. These expectations use the
        // prototype's piecewise gap mapping, independently of MapLayout.
        let leftEdge = first.rect.minX + 0.25 * 26
        let rightEdge = last.rect.minX + (1.25 - spans[2].start) * 26
        #expect(abs(viewport.rect.minX - (leftEdge - 2)) < 0.001 && viewport.rect.height == 12)
        #expect(abs(viewport.rect.maxX - (rightEdge + 2)) < 0.001)
        #expect(abs(firstSeen.rect.minX - leftEdge) < 0.001 && abs(firstSeen.rect.maxX - first.rect.maxX) < 0.001)
        #expect(abs(lastSeen.rect.minX - last.rect.minX) < 0.001 && abs(lastSeen.rect.maxX - rightEdge) < 0.001)
        #expect(firstSeen.fill == .seen && lastSeen.fill == .seen)
        #expect(firstSeen.rect.width > 0 && firstSeen.rect.width < first.rect.width
            && lastSeen.rect.width > 0 && lastSeen.rect.width < last.rect.width)
        #expect(!layout.marks.contains { $0.kind == .seen(rail: 0, slot: 1) }, "focus is filled by its accent, not a neutral overlay")

        var offscreen = picture
        offscreen.rails[0].offset = 0
        offscreen.focus = .tile(0)
        let atStart = MapLayout(offscreen, in: area)
        let unseen = try mark(.tile(rail: 0, slot: 2), in: atStart)
        #expect(unseen.fill == nil && unseen.stroke == .mark)
        #expect(!atStart.marks.contains { $0.kind == .seen(rail: 0, slot: 2) }, "a wholly offscreen tile stays hollow")
    }

    @Test("#18 E23: floats use a right-hand column of seven-point hollow, filled or focused squares", arguments: [false, true])
    func floatMarkStates(_ shown: Bool) throws {
        var picture = MapScene.floats.picture()
        picture.layerShown = shown
        picture.focus = shown ? .float(2) : .tile(1)
        let layout = MapLayout(picture, in: area)
        let floats = try (0..<3).map { try mark(.float($0), in: layout) }
        #expect(floats.allSatisfy { $0.rect.size == CGSize(width: 7, height: 7) })
        #expect(Set(floats.map { $0.rect.minX }).count == 1)
        #expect(abs(floats[1].rect.minY - floats[0].rect.minY - 11) < 0.001)
        let railEnd = try mark(.track(0), in: layout).rect.maxX
        #expect(floats[0].rect.minX > railEnd, "float squares occupy a column to the right of the rails")
        for i in 0..<3 {
            let expected: MapLayout.Mark.Ink? = shown ? (i == 2 ? .accent : .seen) : nil
            #expect(floats[i].fill == expected)
            #expect(floats[i].stroke == (shown ? nil : .remembered))
            if !shown { #expect(floats[i].lineWidth == 1.5) }
        }
        #expect(layout.marks.filter { $0.fill == .accent || $0.stroke == .accent }.count == 1)
    }

    @Test("#18 E23: wall caps are two points at the rail ends or above and below the current viewport", arguments: [MapPicture.Wall.left, .right, .up, .down])
    func wallMarkGeometry(_ wall: MapPicture.Wall) throws {
        var picture = MapScene.long.picture()
        picture.wall = wall
        let layout = MapLayout(picture, in: area)
        let cap = try mark(.wall(wall), in: layout)
        let track = try mark(.track(0), in: layout), viewport = try mark(.viewport(0), in: layout)
        #expect(cap.fill == .wall)
        switch wall {
        case .left:
            #expect(cap.rect.width == 2 && cap.rect.height == 12)
            #expect(abs(cap.rect.minX - (track.rect.minX - 6)) < 0.001)
        case .right:
            #expect(cap.rect.width == 2 && cap.rect.height == 12)
            #expect(abs(cap.rect.minX - (track.rect.maxX + 3)) < 0.001)
        case .up, .down:
            #expect(cap.rect.height == 2 && cap.rect.width == viewport.rect.width)
            #expect(cap.rect.minX == viewport.rect.minX)
            #expect(abs(cap.rect.minY - (wall == .up ? viewport.rect.minY - 3 : viewport.rect.maxY + 1)) < 0.001)
        }
        picture.wall = nil
        #expect(!MapLayout(picture, in: area).marks.contains { if case .wall = $0.kind { true } else { false } })
    }

    @Test("#18 E23: workspace labels exist only for a picture that carries a number")
    func workspaceLabelIsOptional() throws {
        var picture = MapScene.single.picture()
        let ordinary = MapLayout(picture, in: area)
        #expect(!ordinary.marks.contains { if case .workspace = $0.kind { true } else { false } })
        picture.workspace = 3
        let labeled = MapLayout(picture, in: area)
        _ = try mark(.workspace(3), in: labeled)
        #expect(labeled.size.width > ordinary.size.width, "the workspace label adds its own space")
    }

    private func mark(_ kind: MapLayout.Mark.Kind, in layout: MapLayout) throws -> MapLayout.Mark {
        let marks = layout.marks.filter { $0.kind == kind }
        #expect(marks.count == 1, "exactly one \(kind) drawing primitive")
        return try #require(marks.first, "missing \(kind) drawing primitive")
    }
}
