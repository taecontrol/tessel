import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

/// Drawing primitives in top-left card coordinates, independent of AppKit.
struct MapLayout {
    struct Mark: Equatable {
        enum Kind: Equatable {
            case track(Int), viewport(Int), tile(rail: Int, slot: Int)
            case seen(rail: Int, slot: Int), float(Int), wall(MapPicture.Wall), workspace(Int)
        }
        enum Ink: Equatable { case track, viewport, frame, mark, seen, remembered, accent, wall }
        let kind: Kind
        let rect: CGRect
        let fill: Ink?
        let stroke: Ink?
        let lineWidth: Double
    }
    let size: CGSize
    let marks: [Mark]

    init(_ picture: MapPicture, in area: CGRect) {
        let scale = 26.0, gap = 2.0, pitch = 14.0, padding = 8.0
        let geometry = picture.rails.map { Geometry($0, scale: scale, gap: gap) }
        let railWidth = zip(picture.rails, geometry).map { rail, geometry in
            max(geometry.x(rail.spans.last.map { $0.start + $0.width } ?? 0), geometry.x(rail.offset + 1))
        }.max() ?? 0
        let railHeight = Double(picture.rails.count) * pitch
        let floatHeight = picture.floats > 0 ? Double(picture.floats) * 11 - 4 : 0
        let height = max(14, railHeight, floatHeight)
        let labelWidth = picture.workspace.map { Double(String($0).count) * 9 } ?? 0
        let labelSpace = picture.workspace == nil ? 0 : labelWidth + 9
        let originX = padding + labelSpace
        var marks: [Mark] = []
        func append(_ kind: Mark.Kind, _ rect: CGRect, fill: Mark.Ink? = nil,
                    stroke: Mark.Ink? = nil, lineWidth: Double = 0) {
            marks.append(Mark(kind: kind, rect: rect, fill: fill, stroke: stroke, lineWidth: lineWidth))
        }
        if let workspace = picture.workspace {
            append(.workspace(workspace), CGRect(x: 6, y: padding + (height - 14) / 2, width: labelWidth, height: 14), fill: .wall)
        }
        for i in 0..<picture.floats {
            let focused = picture.focus == .float(i)
            append(.float(i), CGRect(x: originX + railWidth + 9, y: padding + Double(i) * 11 + (height - floatHeight) / 2,
                                    width: 7, height: 7),
                   fill: focused ? .accent : picture.layerShown ? .seen : nil,
                   stroke: focused || picture.layerShown ? nil : .remembered, lineWidth: 1.5)
        }
        for (r, rail) in picture.rails.enumerated() {
            let g = geometry[r], current = r == picture.current
            let y = padding + (height - railHeight) / 2 + Double(r) * pitch + 7
            let left = originX + g.x(rail.offset), right = originX + g.x(rail.offset + 1)
            let end = originX + g.x(rail.spans.last.map { $0.start + $0.width } ?? 0)
            append(.track(r), CGRect(x: originX, y: y - 0.5, width: max(end, right) - originX, height: 1), fill: .track)
            append(.viewport(r), CGRect(x: left - 2, y: y - 6, width: right - left + 4, height: 12), fill: .viewport, stroke: .frame, lineWidth: 1)
            for (i, span) in rail.spans.enumerated() {
                let focused = current && picture.focus == .tile(i)
                let remembered = !current && i == rail.remembered
                let h = current ? 8.0 : remembered ? 7.0 : 4.0
                let top = h == 4 ? floor(y - h / 2) + 0.5 : y - h / 2
                let rect = CGRect(x: originX + g.starts[i], y: top, width: span.width * scale, height: h)
                append(.tile(rail: r, slot: i), rect, fill: focused ? .accent : remembered ? .remembered : nil,
                       stroke: focused || remembered ? nil : .mark, lineWidth: 1)
                if !focused && !remembered {
                    let a = max(rect.minX, left), b = min(rect.maxX, right)
                    if b > a {
                        append(.seen(rail: r, slot: i), CGRect(x: a, y: rect.minY, width: b - a, height: h), fill: .seen)
                    }
                }
            }
            if current, let wall = picture.wall {
                let rect = switch wall {
                case .left: CGRect(x: originX - 6, y: y - 6, width: 2, height: 12)
                case .right: CGRect(x: end + 3, y: y - 6, width: 2, height: 12)
                case .up: CGRect(x: left - 2, y: y - 9, width: right - left + 4, height: 2)
                case .down: CGRect(x: left - 2, y: y + 7, width: right - left + 4, height: 2)
                }
                append(.wall(wall), rect, fill: .wall)
            }
        }
        let width = ceil(railWidth + (picture.floats > 0 ? 16 : 0)) + 16 + labelSpace
        let natural = CGSize(width: width, height: height + 16)
        let reduction = max(0, min(1, area.width / 3 / natural.width, area.height / 3 / natural.height))
        size = CGSize(width: natural.width * reduction, height: natural.height * reduction)
        self.marks = marks.map { mark in
            Mark(kind: mark.kind, rect: CGRect(x: mark.rect.minX * reduction, y: mark.rect.minY * reduction,
                                               width: mark.rect.width * reduction, height: mark.rect.height * reduction),
                 fill: mark.fill, stroke: mark.stroke, lineWidth: mark.lineWidth * reduction)
        }
    }

    /// Expand desktop gaps to two points without changing nominal width ratios.
    private struct Geometry {
        let rail: MapPicture.Rail
        let scale: Double
        let gap: Double
        let starts: [Double]
        init(_ rail: MapPicture.Rail, scale: Double, gap: Double) {
            self.rail = rail; self.scale = scale; self.gap = gap
            var x = 0.0
            starts = rail.spans.map { span in
                defer { x += span.width * scale + gap }
                return x
            }
        }
        func x(_ position: Double) -> Double {
            for (i, span) in rail.spans.enumerated() {
                let end = span.start + span.width
                if position <= end { return starts[i] + (position - span.start) * scale }
                if rail.spans.indices.contains(i + 1), position < rail.spans[i + 1].start {
                    return starts[i] + span.width * scale + gap * (position - end) / (rail.spans[i + 1].start - end)
                }
            }
            guard let last = rail.spans.last, let start = starts.last else { return position * scale }
            return start + (position - last.start) * scale
        }
    }
}
