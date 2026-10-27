import AppKit
import QuartzCore

@MainActor
final class SystemRailsMap: RailsMapPort {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var window: Panel?
    private var view: RailsMapView?
    private var generation: UInt64 = 0
    #if TESSEL_DEVELOPMENT
    var onEvent: ((AppStatus.TestMap) -> Void)?
    var onCapture: ((NSView) -> Void)?
    private var observation = AppStatus.TestMap()
    #endif

    func show(_ picture: MapPicture, in area: CGRect, transition: TimeInterval) {
        guard let screen = NSScreen.screens.first, area.width > 0, area.height > 0 else { return }
        let layout = MapLayout(picture, in: area)
        guard layout.size.width > 0, layout.size.height > 0 else { return }
        generation += 1
        if window == nil {
            let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            let view = RailsMapView(frame: .zero)
            panel.contentView = view
            self.view = view; window = panel
        }
        guard let window, let view else { return }
        // The picture uses AX coordinates; the card is anchored to AppKit's
        // visible frame, outside the workspace's own outer gap.
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - 10 - layout.size.width, y: visible.minY + 10,
                           width: layout.size.width, height: layout.size.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.layer?.removeAllAnimations()
        view.layer?.opacity = 1
        window.setFrame(frame, display: false)
        view.draw(layout, transition: transition)
        CATransaction.commit()
        if !window.isVisible { window.orderFrontRegardless() }
        #if TESSEL_DEVELOPMENT
        observation.railTileCounts = picture.rails.map { $0.spans.count }
        observation.shows += 1
        observation.window = UInt32(window.windowNumber)
        observation.key = window.isKeyWindow
        observation.main = window.isMainWindow
        onEvent?(observation)
        onCapture?(view)
        #endif
    }

    func hide(fade: TimeInterval) {
        guard let window, let view else { return }
        generation += 1
        let token = generation
        guard fade > 0, window.isVisible, let layer = view.layer else { orderOut(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.orderOut()
            }
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = 0
        animation.duration = fade
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        layer.opacity = 0
        layer.add(animation, forKey: "leave")
        CATransaction.commit()
    }

    private func orderOut() {
        window?.orderOut(nil)
        view?.clear()
    }
}

/// The material and semantic inks follow this view's effective appearance.
@MainActor
private final class RailsMapView: NSView {
    private let material = NSVisualEffectView()
    private let drawing = NSView()
    private let canvas = CALayer()
    private var layout: MapLayout?
    private var viewports: [Int: CAShapeLayer] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        addSubview(material)
        drawing.layer = CALayer()
        drawing.wantsLayer = true
        drawing.autoresizingMask = [.width, .height]
        addSubview(drawing)
        canvas.isGeometryFlipped = true
        canvas.cornerRadius = 6
        canvas.borderWidth = 1
        drawing.layer?.addSublayer(canvas)
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let layout { draw(layout, transition: 0) }
    }

    func draw(_ layout: MapLayout, transition: TimeInterval) {
        self.layout = layout
        let palette = Palette(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let scale = window?.backingScaleFactor ?? 2
        let previous = viewports.compactMapValues { $0.presentation()?.path ?? $0.path }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        material.frame = bounds
        drawing.frame = bounds
        canvas.frame = bounds
        canvas.backgroundColor = palette.background
        canvas.borderColor = palette.border
        canvas.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        viewports.removeAll()
        for mark in layout.marks {
            if case .workspace(let number) = mark.kind {
                let text = CATextLayer()
                let reduction = mark.rect.height / 14
                text.frame = mark.rect.insetBy(dx: 0, dy: -2 * reduction)
                text.string = String(number)
                text.font = NSFont.monospacedDigitSystemFont(ofSize: 14 * reduction, weight: .medium)
                text.fontSize = 14 * reduction
                text.alignmentMode = .center
                text.foregroundColor = palette.ink(.wall)
                text.contentsScale = scale
                canvas.addSublayer(text)
                continue
            }
            let shape = CAShapeLayer()
            let radius: CGFloat = switch mark.kind {
            case .track, .seen, .wall: 0.5
            case .viewport: 2
            case .float: 1.5
            default: 1
            }
            shape.path = CGPath(roundedRect: mark.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            shape.fillColor = mark.fill.map(palette.ink)
            shape.strokeColor = mark.stroke.map(palette.ink)
            shape.lineWidth = mark.lineWidth
            shape.contentsScale = scale
            canvas.addSublayer(shape)
            if case .viewport(let rail) = mark.kind {
                viewports[rail] = shape
                if transition > 0, let path = previous[rail] {
                    let move = CABasicAnimation(keyPath: "path")
                    move.fromValue = path
                    move.toValue = shape.path
                    move.duration = transition
                    move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                    shape.add(move, forKey: "viewport")
                }
            }
        }
        CATransaction.commit()
    }

    func clear() {
        layout = nil
        layer?.removeAllAnimations()
        canvas.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        viewports.removeAll()
    }

    private struct Palette {
        let dark: Bool
        private func color(_ hex: UInt32, alpha: Double = 1) -> CGColor {
            NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                    blue: Double(hex & 255) / 255, alpha: alpha).cgColor
        }
        var background: CGColor { color(dark ? 0x23262c : 0xedf0f5, alpha: 0.97) }
        var border: CGColor { color(0xffffff, alpha: dark ? 48.0 / 255 : 0.85) }
        func ink(_ ink: MapLayout.Mark.Ink) -> CGColor {
            switch ink {
            case .track: color(dark ? 0xf4f6fa : 0x373c45, alpha: 0.1)
            case .viewport: color(dark ? 0x454b55 : 0xffffff)
            case .frame: color(dark ? 0x727b88 : 0x949ba5)
            case .mark, .seen: color(dark ? 0xb8bec7 : 0x626873)
            case .remembered: color(dark ? 0xedf0f5 : 0x414752)
            case .accent: color(dark ? 0x409cff : 0x007aff)
            case .wall: color(dark ? 0xf6f7fa : 0x303640)
            }
        }
    }
}
