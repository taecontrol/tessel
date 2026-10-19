import CoreGraphics
import Foundation
import Ports
import Testing
@testable import Policy

/// The animator owns these resource lifetimes even if a requested frame never
/// arrives. This checks that boundary directly, independently of AX completion.
@Suite @MainActor struct CarouselAnimatorLifetime {
    @Test("ordinary landing releases its deadline and all display demand")
    func ordinaryLandingReleasesResources() {
        let p = Probe()
        p.start(duration: 80)
        p.display.deliver(at: 0.04)
        #expect(p.batches.count == 1 && !p.batches[0].final)
        #expect(p.main.outstanding == 1 && p.display.outstanding == 1)
        p.display.deliver(at: 0.08)
        p.expectLanded()
        let count = p.batches.count
        p.main.advance(to: 2)
        #expect(p.batches.count == count && p.completions == 1)
    }

    @Test("the fallback lands exactly and releases a withheld display request", arguments: [false, true])
    func missingFramesReleaseResources(afterIntermediate: Bool) {
        let p = Probe()
        p.holdFinal = true
        p.start(duration: 80)
        if afterIntermediate { p.display.deliver(at: 0.04) }
        #expect(p.main.outstanding == 1 && p.display.outstanding == 1)
        p.main.advance(to: 0.129)
        #expect(p.completions == 0)
        p.main.advance(to: 0.131)
        #expect(p.batches.last?.final == true && p.batches.last?.writes[1]?.frame == p.target)
        #expect(p.main.outstanding == 0 && p.display.outstanding == 0)
        #expect(p.completions == 0 && p.animator.active)
        p.acknowledgeFinal?()
        p.acknowledgeFinal = nil
        p.expectLanded()
        let count = p.batches.count
        p.display.deliver(at: 2)
        #expect(p.batches.count == count && p.completions == 1)
    }

    @Test("cancelling motion releases pending timers and frames before its old deadline")
    func interruptionReleasesResources() {
        let p = Probe()
        p.start(duration: 1_000)
        p.display.deliver(at: 0.03)
        #expect(p.batches.count == 1 && !p.batches[0].final)
        p.animator.cancel()
        #expect(!p.animator.active)
        #expect(p.main.outstanding == 0 && p.display.outstanding == 0)
        p.main.advance(to: 2)
        p.display.deliver(at: 2)
        #expect(p.batches.count == 1 && p.completions == 0)
    }

    @Test("retargeting replaces resources and no old deadline can land later")
    func retargetingReplacesResources() {
        let p = Probe()
        p.start(duration: 1_000)
        p.display.deliver(at: 0.03)
        let current = p.animator.frames
        let revised = CGRect(x: 100, y: 43, width: 849, height: 1_064)
        p.start(from: current, to: revised, duration: 80)
        #expect(p.main.outstanding == 1 && p.display.outstanding == 1)
        p.display.deliver(at: 0.12)
        p.expectLanded(at: revised)
        let count = p.batches.count
        p.main.advance(to: 2)
        #expect(p.batches.count == count && p.completions == 1)
    }

    @Test("an instant retarget releases the old resources without requesting any new ones")
    func instantRetargetReleasesResources() {
        let p = Probe()
        p.start(duration: 1_000)
        p.display.deliver(at: 0.03)
        p.start(from: p.animator.frames, duration: 0)
        #expect(!p.animator.active)
        #expect(p.main.outstanding == 0 && p.display.outstanding == 0)
        p.main.advance(to: 2)
        p.display.deliver(at: 2)
        #expect(p.batches.count == 1 && p.completions == 1)
    }

    @MainActor private final class Probe {
        let main = ManualMain()
        let display: ManualDisplay
        let animator: CarouselAnimator
        let target = CGRect(x: 869, y: 43, width: 849, height: 1_064)
        var batches: [(writes: [UInt32: CarouselAnimator.Write], final: Bool)] = []
        var completions = 0
        var holdFinal = false
        var acknowledgeFinal: (@MainActor @Sendable () -> Void)?
        init() {
            display = ManualDisplay(main: main)
            animator = CarouselAnimator(display: display, main: main)
        }
        func start(from: [UInt32: CGRect]? = nil, to: CGRect? = nil, duration: Int) {
            animator.start(from: from ?? [1: CGRect(x: 10, y: 43, width: 849, height: 1_064)],
                           to: [1: to ?? target], duration: duration,
                           bounds: CGRect(x: 0, y: 0, width: 1_728, height: 1_117), menuBottom: 33,
                           apply: { [self] writes, final, done in
                               batches.append((writes, final))
                               if final && holdFinal { acknowledgeFinal = done }
                               else { done() }
                           }, completion: { [self] in completions += 1 })
        }
        func expectLanded(at frame: CGRect? = nil) {
            #expect(completions == 1 && !animator.active)
            #expect(batches.last?.final == true && batches.last?.writes[1]?.frame == (frame ?? target))
            #expect(main.outstanding == 0 && display.outstanding == 0)
        }
    }

    /// Tokens remain outstanding until delivered or cancelled. In particular,
    /// withholding a frame never silently consumes its native display demand.
    private final class Token: ScheduledWork, @unchecked Sendable {
        var active = true
        func cancel() { active = false }
    }
    private final class ManualMain: MainLane, @unchecked Sendable {
        struct Timer {
            let at: TimeInterval
            let token: Token
            let work: @MainActor @Sendable () -> Void
        }
        var now: TimeInterval = 0
        var timers: [Timer] = []
        var outstanding: Int { timers.filter { $0.token.active }.count }
        func async(_ work: @escaping @MainActor @Sendable () -> Void) { after(milliseconds: 0, work) }
        @discardableResult
        func after(milliseconds: Int, _ work: @escaping @MainActor @Sendable () -> Void) -> any ScheduledWork {
            let token = Token()
            timers.append(Timer(at: now + Double(milliseconds) / 1_000, token: token, work: work))
            return token
        }
        @MainActor func advance(to time: TimeInterval) {
            while let first = timers.filter({ $0.token.active && $0.at <= time }).min(by: { $0.at < $1.at }) {
                now = first.at
                first.token.active = false
                timers.removeAll { $0.token === first.token }
                first.work()
            }
            timers.removeAll { !$0.token.active }
            now = time
        }
    }
    private final class ManualDisplay: DisplayFramePort {
        let main: ManualMain
        var pending: [(token: Token, receive: @MainActor @Sendable (TimeInterval) -> Void)] = []
        var now: TimeInterval { main.now }
        var outstanding: Int { pending.filter { $0.token.active }.count }
        init(main: ManualMain) { self.main = main }
        func requestFrame(_ receive: @escaping @MainActor @Sendable (TimeInterval) -> Void) -> any ScheduledWork {
            let token = Token()
            pending.append((token, receive))
            return token
        }
        func deliver(at time: TimeInterval) {
            main.advance(to: time)
            let delivery = pending.filter { $0.token.active }
            for request in delivery { request.token.active = false }
            pending.removeAll()
            for request in delivery { request.receive(time) }
        }
    }
}
