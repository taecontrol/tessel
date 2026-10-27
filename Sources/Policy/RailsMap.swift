import CoreGraphics
import Foundation
#if SWIFT_PACKAGE
import Ports
#endif

@MainActor final class RailsMap {
    private enum State {
        case hidden, shown(any ScheduledWork), leaving
    }
    private let port: (any RailsMapPort)?
    private let scheduler: any SchedulingPort
    private var state = State.hidden
    private var duration = 1000
    private var transition: TimeInterval = 0
    private var picture: MapPicture?
    private var area: CGRect = .zero
    private var drawnTransition: TimeInterval = 0
    private(set) var enabled = false
    var shown: Bool { if case .shown = state { true } else { false } }

    init(port: (any RailsMapPort)?, scheduler: any SchedulingPort) {
        self.port = port; self.scheduler = scheduler
    }

    func configure(enabled: Bool, duration: Int, motion: Bool, transition: TimeInterval) {
        self.enabled = enabled && port != nil
        self.duration = duration
        self.transition = motion ? transition : 0
        if !self.enabled { dismiss() }
        else if !motion, case .leaving = state { dismiss() }
    }

    func command(_ picture: MapPicture, in area: CGRect) {
        guard enabled else { return }
        if case .shown(let timer) = state { timer.cancel() }
        draw(picture, in: area)
        state = .shown(scheduler.main.after(milliseconds: duration) { [weak self] in
            guard let self else { return }
            let fade = self.transition > 0 ? 0.12 : 0
            self.state = fade > 0 ? .leaving : .hidden
            self.port?.hide(fade: fade)
            self.picture = nil
        })
    }

    func refresh(_ picture: MapPicture, in area: CGRect) {
        guard shown else { return }
        var next = picture
        next.wall = self.picture?.wall
        next.workspace = self.picture?.workspace
        guard next != self.picture || area != self.area || transition != drawnTransition else { return }
        draw(next, in: area)
    }

    func dismiss() {
        if case .hidden = state { return }
        if case .shown(let timer) = state { timer.cancel() }
        state = .hidden
        picture = nil
        port?.hide(fade: 0)
    }

    private func draw(_ picture: MapPicture, in area: CGRect) {
        self.picture = picture; self.area = area; drawnTransition = transition
        port?.show(picture, in: area, transition: transition)
    }
}
