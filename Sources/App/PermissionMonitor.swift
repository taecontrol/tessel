import AppKit
import ApplicationServices

/// TCC caches trust in the running process. A fresh, short-lived copy checks for
/// the grant while permission is missing; no timer survives a successful grant.
@MainActor
final class PermissionMonitor {
    private var check: Process?
    private let granted: () -> Void
    private lazy var polling = PermissionPolling(startTimer: { interval, tolerance, tick in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }, probe: { [weak self] completed in self?.probe(completed) }, granted: granted)

    init(granted: @escaping () -> Void) { self.granted = granted }

    func start() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        polling.start()
    }

    private func probe(_ completed: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let executable = Bundle.main.executableURL else { completed(false); return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--check-permission"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.check = nil
                completed(process.terminationStatus == 0)
            }
        }
        do { try process.run(); check = process }
        catch { check = nil; completed(false) }
    }
}
