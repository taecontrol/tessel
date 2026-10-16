import AppKit
import ApplicationServices

/// TCC caches trust in the running process. A fresh, short-lived copy checks for
/// the grant while permission is missing; no timer survives a successful grant.
@MainActor
final class PermissionMonitor {
    private var timer: Timer?
    private var check: Process?
    private let granted: () -> Void

    init(granted: @escaping () -> Void) { self.granted = granted }

    func start() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func probe() {
        guard check == nil, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--check-permission"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.check = nil
                if process.terminationStatus == 0 {
                    self.timer?.invalidate()
                    self.timer = nil
                    self.granted()
                }
            }
        }
        do { try process.run(); check = process }
        catch { check = nil }
    }
}
