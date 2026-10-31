import Foundation
import os

/// The lock orders Quit after any in-flight record and seals the run, so late
/// AX replies or queued notifications cannot put an entry after its final Quit.
final class SystemDiagnostics: DiagnosticsPort, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let loggers: [DiagnosticCategory: Logger] = Dictionary(uniqueKeysWithValues: DiagnosticCategory.allCases.map {
        ($0, Logger(subsystem: Instance.bundleID, category: $0.rawValue))
    })

    func record(_ diagnostic: Diagnostic) {
        lock.withLock {
            guard !finished else { return }
            let logger = loggers[diagnostic.category]!
            // The closed payloads contain IDs and Tessel's own vocabulary;
            // Policy never reads a title or other Accessibility content.
            switch diagnostic.level {
            case .notice: logger.notice("\(diagnostic.text, privacy: .public)")
            case .error: logger.error("\(diagnostic.text, privacy: .public)")
            }
            if case .quit = diagnostic { finished = true }
        }
    }
}
