import CoreGraphics
import Foundation
import Ports

extension SimulatedMac {
    package enum StageEventKind: Sendable, Equatable {
        case capture(UInt32)
        case order([UInt32])
        case background
        case show([UInt32: CGRect])
        case move([UInt32: CGRect], duration: Int)
        case settled
        case revealed
        case covered
        case refresh(UInt32)
        case clear
        case accessRequest
    }
    package struct StageEvent: Sendable {
        package let at: Int
        package let kind: StageEventKind
    }
    /// What policy asked for, even if an adapter deduplicates the work or a
    /// later clear cancels it. Events above describe completed native work.
    package struct StageCaptureRequest: Sendable {
        package let at: Int
        package let windows: Set<UInt32>
        package let backgroundExcluding: Set<UInt32>?
        package let refreshing: Bool
    }
    struct StageState {
        var screenRecording = true
        var events: [StageEvent] = []
        var captureRequests: [StageCaptureRequest] = []
        var pendingCaptures = 0
        var onCapturesSettled: (@MainActor @Sendable () -> Void)?
        var session = 0
        /// Captures are serial, like ScreenCaptureKit's.
        var captureCost = 14
        var busyUntil = 0
        var captured: [UInt32: Int] = [:]
        var backgroundReady: Int?
        var shown = false
        var failing = Set<UInt32>()
        /// Counts moves, reveals and clears: a later one cancels an earlier
        /// one's callback.
        var motion = 0
    }

    @MainActor package var stage: any MotionStagePort { Stage(mac: self) }
    @MainActor package var stageEvents: [StageEvent] { stageState.events }
    @MainActor package var stageCaptureRequests: [StageCaptureRequest] { stageState.captureRequests }
    /// Chooses when the contracted async capture completion arrives. Clearing
    /// the overlay invalidates its image, not this outstanding native reply.
    @MainActor package func setStageCaptureCost(milliseconds: Int) {
        precondition(milliseconds > 0)
        stageState.captureCost = milliseconds
    }
    /// Screen Recording, which the stage needs.
    @MainActor package func setScreenRecording(_ granted: Bool) {
        action("Screen Recording=\(granted)")
        stageState.screenRecording = granted
    }
    /// Failure injection: a window ScreenCaptureKit cannot capture.
    @MainActor package func failCapture(of id: UInt32) { stageState.failing.insert(id) }
    @MainActor package func clearStageHistory() {
        stageState.events.removeAll()
        stageState.captureRequests.removeAll()
    }

    @MainActor private func recordStage(_ kind: StageEventKind) {
        stageState.events.append(StageEvent(at: scheduler.now, kind: kind))
        // Dictionary order varies by process; traces must not.
        func rects(_ rects: [UInt32: CGRect]) -> String { rects.keys.sorted().map { "\($0):\(rects[$0]!)" }.joined(separator: " ") }
        switch kind {
        case .show(let shown): scheduler.note("stage show \(rects(shown))")
        case .move(let moved, let duration): scheduler.note("stage move \(duration) ms \(rects(moved))")
        default: scheduler.note("stage \(kind)")
        }
    }

    @MainActor private final class Stage: MotionStagePort {
        let mac: SimulatedMac
        init(mac: SimulatedMac) { self.mac = mac }

        var available: Bool {
            mac.assume(.screenRecordingPreflight)
            mac.scheduler.call("MotionStagePort.available")
            return mac.stageState.screenRecording
        }

        func requestAccess() {
            mac.assume(.screenRecordingPreflight)
            mac.scheduler.call("MotionStagePort.requestAccess")
            mac.recordStage(.accessRequest)
        }

        var capturesPending: Bool { mac.stageState.pendingCaptures > 0 }
        var onCapturesSettled: (@MainActor @Sendable () -> Void)? {
            get { mac.stageState.onCapturesSettled }
            set { mac.stageState.onCapturesSettled = newValue }
        }

        private func completeCapture(after milliseconds: Int, _ completed: @escaping @MainActor @Sendable () -> Void) {
            mac.stageState.pendingCaptures += 1
            mac.scheduler.main.after(milliseconds: milliseconds) { [mac] in
                completed()
                mac.stageState.pendingCaptures -= 1
                if mac.stageState.pendingCaptures == 0 { mac.stageState.onCapturesSettled?() }
            }
        }

        func order(_ windows: [UInt32]) {
            mac.scheduler.call("MotionStagePort.order")
            mac.recordStage(.order(windows))
        }

        func capture(_ windows: Set<UInt32>, background excluding: Set<UInt32>?) {
            mac.assume(.stageWholeWindowCapture)
            mac.stageState.captureRequests.append(StageCaptureRequest(at: mac.scheduler.now, windows: windows,
                backgroundExcluding: excluding, refreshing: false))
            mac.scheduler.call("MotionStagePort.capture")
            let session = mac.stageState.session
            for id in windows.sorted() where mac.stageState.captured[id] == nil {
                let done = max(mac.scheduler.now, mac.stageState.busyUntil) + mac.stageState.captureCost
                mac.stageState.busyUntil = done
                mac.stageState.captured[id] = done
                completeCapture(after: done - mac.scheduler.now) { [mac] in
                    guard mac.stageState.session == session else { return }
                    mac.recordStage(.capture(id))
                }
            }
            if excluding != nil, mac.stageState.backgroundReady == nil {
                let done = max(mac.scheduler.now, mac.stageState.busyUntil) + mac.stageState.captureCost * 3
                mac.stageState.busyUntil = done
                mac.stageState.backgroundReady = done
                completeCapture(after: done - mac.scheduler.now) { [mac] in
                    guard mac.stageState.session == session else { return }
                    mac.recordStage(.background)
                }
            }
        }

        func show(_ rects: [UInt32: CGRect], completion: @escaping @MainActor @Sendable (Bool) -> Void) {
            mac.assume(.stageOverlay)
            mac.scheduler.call("MotionStagePort.show")
            let session = mac.stageState.session
            let ready = ([mac.stageState.backgroundReady] + rects.keys.map { mac.stageState.captured[$0] }).compactMap { $0 }.max() ?? mac.scheduler.now
            let failed = rects.keys.contains { mac.stageState.failing.contains($0) || mac.windows[$0] == nil }
            // The overlay draws in the next display frame after its commit.
            mac.scheduler.main.after(milliseconds: max(0, ready - mac.scheduler.now) + 16) { [mac] in
                guard mac.stageState.session == session else { completion(false); return }
                guard !failed else { completion(false); return }
                mac.stageState.shown = true
                mac.recordStage(.show(rects))
                completion(true)
            }
        }

        func move(_ rects: [UInt32: CGRect], entering: [UInt32: CGRect], duration: TimeInterval,
                  settled: @escaping @MainActor @Sendable () -> Void) {
            mac.assume(.stageOverlay)
            mac.scheduler.call("MotionStagePort.move")
            mac.stageState.motion += 1
            let motion = mac.stageState.motion, milliseconds = Int((duration * 1_000).rounded())
            mac.recordStage(.move(rects, duration: milliseconds))
            // Stand-ins come within 1.5 pt of rest before the curve's end.
            mac.scheduler.main.after(milliseconds: milliseconds * 7 / 10) { [mac] in
                guard mac.stageState.motion == motion else { return }
                mac.recordStage(.settled)
                settled()
            }
        }

        func cover(_ covered: @escaping @MainActor @Sendable () -> Void) {
            mac.assume(.stageOverlay)
            mac.scheduler.call("MotionStagePort.cover")
            let session = mac.stageState.session
            // A restored overlay draws in the next display frame.
            mac.scheduler.main.after(milliseconds: 16) { [mac] in
                guard mac.stageState.session == session else { return }
                mac.recordStage(.covered)
                covered()
            }
        }

        func reveal(_ frames: [UInt32: CGRect], hidden: Set<UInt32>, revealed: @escaping @MainActor @Sendable () -> Void) {
            mac.assume(.stageOverlay)
            mac.scheduler.call("MotionStagePort.reveal")
            mac.stageState.motion += 1
            let motion = mac.stageState.motion
            // The simulated WindowServer shows an accepted placement at once;
            // the stage then fades into it.
            mac.scheduler.main.after(milliseconds: 40) { [mac] in
                guard mac.stageState.motion == motion else { return }
                mac.recordStage(.revealed)
                revealed()
            }
        }

        func refresh(_ window: UInt32) {
            mac.assume(.stageWholeWindowCapture)
            mac.stageState.captureRequests.append(StageCaptureRequest(at: mac.scheduler.now, windows: [window],
                backgroundExcluding: nil, refreshing: true))
            mac.scheduler.call("MotionStagePort.refresh")
            let session = mac.stageState.session
            mac.scheduler.main.after(milliseconds: 17) { [self, mac] in
                guard mac.stageState.session == session else { return }
                completeCapture(after: mac.stageState.captureCost) { [mac] in
                    guard mac.stageState.session == session else { return }
                    mac.recordStage(.refresh(window))
                }
            }
        }

        func clear() {
            mac.scheduler.call("MotionStagePort.clear")
            mac.stageState.session += 1
            mac.stageState.motion += 1
            mac.stageState.captured.removeAll()
            mac.stageState.backgroundReady = nil
            mac.stageState.busyUntil = mac.scheduler.now
            mac.stageState.shown = false
            mac.recordStage(.clear)
        }
    }
}
