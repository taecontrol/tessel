import Foundation

@MainActor
final class PermissionPolling {
    typealias StartTimer = (TimeInterval, TimeInterval, @escaping @MainActor @Sendable () -> Void) -> () -> Void
    typealias Probe = (@escaping @MainActor @Sendable (Bool) -> Void) -> Void

    private let startTimer: StartTimer
    private let probe: Probe
    private let granted: () -> Void
    private var cancelTimer: (() -> Void)?
    private var checking = false

    init(startTimer: @escaping StartTimer, probe: @escaping Probe, granted: @escaping () -> Void) {
        self.startTimer = startTimer
        self.probe = probe
        self.granted = granted
    }

    func start() {
        cancelTimer = startTimer(0.75, 0.05) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard cancelTimer != nil, !checking else { return }
        checking = true
        probe { [weak self] trusted in
            guard let self else { return }
            self.checking = false
            guard trusted else { return }
            self.cancelTimer?()
            self.cancelTimer = nil
            self.granted()
        }
    }
}
