import CoreGraphics
import Testing

@Suite struct InstantHandoffOracleTests {
    private let left = CGRect(x: 0, y: 0, width: 40, height: 40)
    private let right = CGRect(x: 60, y: 0, width: 40, height: 40)
    private var oracle: InstantHandoffOracle {
        InstantHandoffOracle(area: CGRect(x: 0, y: 0, width: 100, height: 40), ids: [1, 2],
                             before: [1: left, 2: right], startOrder: [1, 2],
                             final: [1: left.offsetBy(dx: 10, dy: 0), 2: right], endOrder: [1, 2])
    }

    @Test("#33 E18: concurrent bursts excuse only their own intermediate geometry")
    func concurrentBurstsAreLocal() {
        let frames: [UInt32: CGRect] = [1: left.offsetBy(dx: 5, dy: 0), 2: right.offsetBy(dx: -5, dy: 0)]
        #expect(oracle.violations(frames: frames, order: [1, 2], inProgress: [1, 2]).isEmpty)
        #expect(!oracle.violations(frames: frames, order: [1, 2], inProgress: [1]).isEmpty,
                "a different app's burst cannot excuse window 2's intermediate geometry")
        #expect(!oracle.violations(frames: frames, order: [1, 2], inProgress: []).isEmpty,
                "an intermediate frame cannot outlive its own burst")
    }

    @Test("#33 E18: a burst never masks a gap or wrong owner outside its affected area")
    func unrelatedPointsRemainObservable() {
        let moving = left.offsetBy(dx: 5, dy: 0)
        #expect(oracle.violations(frames: [1: moving, 2: right], order: [1, 2], inProgress: [1]).isEmpty)
        #expect(!oracle.violations(frames: [1: moving], order: [1], inProgress: [1]).isEmpty,
                "the missing right tile remains a coverage violation while the left tile moves")

        let wrongOwner = InstantHandoffOracle(area: oracle.area, ids: [1, 2, 3],
            before: [1: left, 2: right, 3: right], startOrder: [1, 2, 3],
            final: [1: left.offsetBy(dx: 10, dy: 0), 2: right, 3: right], endOrder: [1, 2, 3])
        #expect(!wrongOwner.violations(frames: [1: moving, 2: right, 3: right], order: [1, 3, 2], inProgress: [1]).isEmpty,
                "a third window cannot cover the right tile during an unrelated burst")
    }

    @Test("#33 E18: hidden bursts are invisible and cannot excuse visible gaps")
    func hiddenBurstsHaveNoVisibleException() {
        let hidden = InstantHandoffOracle(area: oracle.area, ids: [1, 2, 3],
            before: oracle.before, startOrder: oracle.startOrder,
            final: [1: left.offsetBy(dx: 10, dy: 0), 2: right, 3: right], endOrder: [3, 1, 2])
        #expect(hidden.violations(frames: oracle.before, order: [1, 2], inProgress: [3]).isEmpty)
        #expect(!hidden.violations(frames: [1: left], order: [1], inProgress: [3]).isEmpty,
                "a hidden window's preparation cannot mask the missing right tile")
    }

    @Test("#33 E18: a returning window must be final even during concurrent bursts")
    func showingAlwaysRequiresFinalGeometry() {
        let returning = InstantHandoffOracle(area: oracle.area, ids: [1, 2],
            before: [1: left], startOrder: [1], final: oracle.final, endOrder: [1, 2])
        #expect(returning.violations(frames: [1: left.offsetBy(dx: 5, dy: 0), 2: right], order: [1, 2],
                                     inProgress: [1, 2], showing: [2]).isEmpty)
        #expect(!returning.violations(frames: [1: left.offsetBy(dx: 5, dy: 0), 2: right.offsetBy(dx: -5, dy: 0)],
                                      order: [1, 2], inProgress: [1, 2], showing: [2]).isEmpty)
    }
}
