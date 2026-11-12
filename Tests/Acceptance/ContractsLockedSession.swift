import Assumptions
import Foundation
import Testing

private extension NativeContractReply.LockWatch.Run {
    var beforeList: Bool { locked[0] }
    var betweenReads: Bool { locked[1] }
    var afterHandle: Bool { locked[2] }
    var wholeLocked: Bool { locked.allSatisfy { $0 } }
    var wholeUnlocked: Bool { !locked.contains(true) }
    var listIsTruthful: Bool { listError == 0 && listIsArray && listsID }
    func handleIsTruthful(_ id: UInt32) -> Bool { handleIDError == 0 && handleID == id && handleRoleError == 0 }
    /// What the catalog reads as a closed window. AXWindows and
    /// AXFocusedWindow answer an element that is not the retained handle and
    /// has no window ID, though its role still reads. The retained handle
    /// answers illegalArgument with ID 0 for its ID and invalidUIElement for
    /// its role. The app's own attributes keep answering.
    var blackout: Bool {
        listError == 0 && listIsArray && roots == 1 && !listsID && !listsHandle
            && rootIDError == -25201 && rootID == 0 && rootRoleError == 0
            && hiddenError == 0 && focusedError == 0 && focusedIsListed && frontmostError == 0
            && handleIDError == -25201 && handleID == 0 && handleRoleError == -25202
    }
    var summary: String {
        "x\(count) locked=\(locked) list error=\(listError) array=\(listIsArray) roots=\(roots) listsHandle=\(listsHandle) listsID=\(listsID)"
            + " root idError=\(rootIDError) id=\(rootID) role=\(rootRoleError)"
            + " app hidden=\(hiddenError) focused=\(focusedError) focusedIsListed=\(focusedIsListed) frontmost=\(frontmostError)"
            + " handle idError=\(handleIDError) id=\(handleID) role=\(handleRoleError)"
            + " windowServer listed=\(windowServerLists) onScreen=\(onScreen) span=\(String(format: "%.3f", last - first)) s"
    }
}

extension Acceptance.Contracts {
    /// Attended: the harness cannot lock or unlock the screen, so the owner
    /// does both once while the signed observer samples. Run it alone:
    /// `TESSEL_CONTRACT_LOCKED_SESSION=1 scripts/verify lockedSessionWindows`.
    @Test("locked-session-windows; #69 E4: a locked session invalidates AX windows that WindowServer still lists",
          .enabled(if: ProcessInfo.processInfo.environment["TESSEL_CONTRACT_LOCKED_SESSION"] == "1",
                   "attended: the owner locks and unlocks the screen"),
          contract(.lockedSessionWindows))
    func lockedSessionWindows() throws {
        try native("reset")
        try fixture.command("reset")
        let id = try fixture.open()
        let before = try window(id)
        try #require(before.idError == 0 && before.roleError == 0 && before.frameError == 0)
        try native("lockWatchStart", ["id": id])
        func watch() throws -> NativeContractReply.LockWatch { try #require(try native("lockWatch").lockWatch) }
        _ = try finalState { try !watch().runs.isEmpty }
        let baseline = try #require(try watch().runs.first)
        try #require(baseline.wholeUnlocked, "start with the screen unlocked")
        try #require(baseline.listIsTruthful && baseline.handleIsTruthful(id), "the unlocked baseline is not truthful: \(baseline.summary)")

        print("ATTENDED CONTRACT: lock the screen now (Control-Command-Q), wait ten seconds, then unlock it.")
        // A piped run buffers stdout; the owner needs this line before locking.
        fflush(stdout)
        // The owner sets the pace, so no elapsed time is judged. The count only
        // stops an unattended run, after about ten minutes of 0.2 s polls.
        let attendedPolls = 3_000
        // Ticks kept after the unlock, so its edge is covered.
        let unlockedTail = 500
        var cycle = false
        for _ in 0..<attendedPolls {
            let runs = try watch().runs
            if let last = runs.last, last.wholeUnlocked, last.count >= unlockedTail, runs.contains(where: { $0.wholeLocked }) {
                cycle = true
                break
            }
            sleep(seconds: 0.2)
        }
        try #require(cycle, "the screen was not locked and unlocked while the contract sampled")
        try requireFinalState("com.apple.screenIsUnlocked arrives after the unlock") {
            try watch().events.contains { $0.name == "com.apple.screenIsUnlocked" }
        }
        let observed = try watch()
        try native("reset")
        let start = observed.runs.first?.first ?? 0
        for run in observed.runs { print("locked-session at \(String(format: "%.3f", run.first - start)) s \(run.summary)") }
        for event in observed.events {
            print("locked-session at \(String(format: "%.3f", event.at - start)) s \(event.name) delivered with locked=\(event.locked)")
        }

        // What tessel's lock gate rests on: a read the session reports unlocked
        // on both sides never shows the blackout.
        let leakedLists = observed.runs.filter { !$0.beforeList && !$0.betweenReads && !$0.listIsTruthful }.map(\.summary)
        #expect(leakedLists.isEmpty, "AXWindows was not truthful between two unlocked reports: \(leakedLists)")
        let leakedHandles = observed.runs.filter { !$0.betweenReads && !$0.afterHandle && !$0.handleIsTruthful(id) }.map(\.summary)
        #expect(leakedHandles.isEmpty, "the retained handle was not truthful between two unlocked reports: \(leakedHandles)")
        let locked = observed.runs.filter { $0.wholeLocked }
        let blackouts = locked.filter { $0.blackout }.count
        #expect(blackouts > 0, "no read inside the lock showed the blackout")
        let unlisted = locked.filter { !$0.windowServerLists }.count
        #expect(unlisted == 0, "WindowServer stopped listing the window while locked")
        let lockedAtUnlock = observed.events.filter { $0.name == "com.apple.screenIsUnlocked" && $0.locked }.count
        #expect(lockedAtUnlock == 0, "the session still reported locked when com.apple.screenIsUnlocked arrived")
    }
}
