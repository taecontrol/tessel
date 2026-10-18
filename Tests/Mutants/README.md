# Policy mutants

Run `swift run tessel-check mutants` from the repository root. Each `.patch`
is applied independently to a fresh copy of tracked working-tree contents.
Headers name the real bug and its fixing commit; the changes semantically
revert that fix against the current `Sources/Policy` layout.

Retain a known-bug mutant only after inspecting its failure: the scenario for
the affected example must reject the historical behavior. A compilation error,
an unrelated scenario failure, or merely missing a checkpoint is insufficient.
Do not alter scenarios or the simulator to kill a candidate.

## Kept known bugs

The four round-one candidates were re-examined after all P examples migrated.
Three now have the required kills; the close candidate remains rejected below.
Times include a fresh copy, patch application, compilation and bare `swift test`
on the development machine (2026-10-18).

| Mutant | Fix | Killing test | Time (s) |
| --- | --- | --- | --- |
| [stale-focus-enable.patch](stale-focus-enable.patch) | 6b80843 | #2 E2 / #17 E2: `Enabling` preserves the newer native selection | 39.863 |
| [stale-focus-layout-switch.patch](stale-focus-layout-switch.patch) | 5549050 | #17 E16: `RailReload.delayedDialog` preserves unpublished dialog focus and send intent | 32.857 |
| [busy-rail-write.patch](busy-rail-write.patch) | c38ae75 | #17 E22: `RailInput.burst` completes pending positions; `retryDelays` requires bounded backoff | 31.386 |
| [queued-native-tab.patch](queued-native-tab.patch) | 9783347 | #17 E19: `RailNativeWindows.unpublishedSuccessor` never reselects the former root | 34.521 |
| [zero-window-id.patch](zero-window-id.patch) | 647500d | #2 E8: `WorkspaceSend.emptyLists`, `zeroIDs`, retains the living sent row in every publication | 50.122 |
| [omitted-minimized-window.patch](omitted-minimized-window.patch) | 647500d | #2 E8: `WorkspaceSend.emptyLists`, `minimizedOmissions`, retains the living minimized row | 31.565 |
| [retired-native-tab-root.patch](retired-native-tab-root.patch) | 97f790d | #1 E5: `FoundationNativeTabs.laggingRoot` keeps the former root retired on later reads | 39.193 |
| [unpublished-rail-successor.patch](unpublished-rail-successor.patch) | 28093c6 | #17 E19: `RailNativeWindows.unpublishedSuccessor` completes the still-current successor focus | 41.918 |
| [dying-rail-owner.patch](dying-rail-owner.patch) | d31cefa | #17 E11: `RailNativeWindows.termination` retains the adjacent-rail landing when native promotion precedes process exit and termination delivery | 21.004 |
| [minimize-between-focus-writes.patch](minimize-between-focus-writes.patch) | 5fe9b3d | #2 E25 / #17 E17: `RailOrderingRegressions.minimizeBetweenFocusWrites` preserves minimization and successor focus across an outstanding AXMain reply | 20.978 |

The two 647500d paths are separate mutants so one cannot mask missing coverage
of the other. The zero-ID mutant also removes the subsequent closed-handle
revalidation: on macOS 27 a closed handle's ID lookup can report
`illegalArgument`, while its attributes report `invalidUIElement`. The keeper
still rejects losing a live zero-ID row; foundation E8 separately rejects
retaining a closed one. The 9783347 native-front check now lives in
`isNativeFront`, shared by initial presentation checks and repeated focus
writes; its semantic revert disables that predicate and restores the redundant
classification raise.
The 97f790d revert removes both the retired-root bar retention and the later
enumeration guard; its failures identify the extra catalog row directly.
The d31cefa revert removes owner-handle revalidation before cross-app focus.
Its focused run reproduces all six original failures: quit and crash under
three write orders select window 1 instead of the adjacent rail's window 2
when termination arrives late and the dying PID still exists at promotion.

The 5fe9b3d revert restores the native-tab-only checks between focus writes,
including the deferred rail activation retry. Signed macOS 27.0.1 probes
witnessed AXRaise restoring a completed minimize even with a cannotComplete
reply. Before the fix, the regression failed in both layouts under readsFirst
with either raise reply: the minimized window was restored and took focus
from its available successor. Existing accepted assertions remain unchanged.

Fresh review found two further ordering regressions, fixed in 790be60:

| Mutant | Killing test |
| --- | --- |
| [owner-check-geometry.patch](owner-check-geometry.patch) | #17 E16: `RailOrderingRegressions.ownerReadSurvivesGapReload` follows external focus after a gap redraw while owner AX revalidation is outstanding |
| [background-discovery-focus.patch](background-discovery-focus.patch) | #2 E2 / #17 E2: `RailOrderingRegressions.initialBackgroundReadPreservesKeyboardFocus` completes a pending keyboard selection across background discovery in stack and rails |

The dying-owner mutant now reverts the revalidation call without deleting its
unused worker methods, so changes to their cancellation guard cannot make the
historical bug's patch obsolete.

## Architecture guards

| Mutant | Required failure | Time (s) |
| --- | --- | --- |
| [guards/simulator-import-policy.patch](guards/simulator-import-policy.patch) | E10: the compiler rejects Simulator importing Policy | 10.731 |
| [guards/policy-wall-clock.patch](guards/policy-wall-clock.patch) | E13: `Integrity.policyIsHeadless` rejects `ForbiddenClock.swift:2: wall clock` | 30.785 |

## Rejected candidate and surviving close example

`closed-window-settling.patch` was tried as a semantic revert of **1a3b9c5**:
remove destruction settling and bounded failed-read retries. In a 49.628 s
fresh-copy trial, compilation succeeded and the #1 E8
`FoundationLifecycle.closedAndQuit` scenario still passed in every
write order. The full suite failed only in #2 E8's zero-ID, failed-read and
mixed-read recovery paths, at their missing read checkpoints. Those failures
prove that recovery needs another read; they do not reproduce a closed row
remaining listed. The patch is excluded from the active `.patch` set.

Coverage finding: #1 E8 lists retained closed AX handles, but the simulator
immediately invalidates their attributes, and the current catalog revalidates
them. The scenario never makes the first read after destruction time out and
then lets the app recover without another notification. #1 E21 leaves the affected app
hung and closes windows only in a healthy app; #2 E8's failed-read case later
supplies a new activation. The historical close-after-timeout behavior therefore
survives its intended example. No candidate survived the entire suite.

After the S8 signed macOS 27.0.1 probe corrected closed ID lookups to return
`illegalArgument` and ID 0, this semantic revert was retried against the repaired
catalog. All six E8 cases (three write orders, listed and omitted handles) still
passed in 0.176 s. The observed closes invalidated their attributes on the first
sample and had no timeouts. No extra delayed-close behavior was invented to
kill this candidate; it remains excluded.

Preserved here for the next coverage investigation, outside patch discovery:

```diff
# Bug: A stale or timed-out destruction read retains a closed window.
# Fixing commit: 1a3b9c5ac93175d4fff2db41fb9301c81cf762fe
diff --git a/Sources/Policy/WindowCatalog.swift b/Sources/Policy/WindowCatalog.swift
--- a/Sources/Policy/WindowCatalog.swift
+++ b/Sources/Policy/WindowCatalog.swift
@@ -204,7 +204,6 @@
     private func changed(_ notification: AXNotification, element: AXElement) {
         // A closing window can still be listed by the read that follows its event.
-        let needsSettling = [.windowCreated, .sheetCreated, .mainWindowChanged,
-                             .destroyed].contains(notification)
+        let needsSettling = [.windowCreated, .sheetCreated, .mainWindowChanged].contains(notification)
         let change: CatalogChange = notification == .restored ? .restored
             : [.focusedWindowChanged, .mainWindowChanged].contains(notification) ? .focus : .snapshot
         if notification == .resized {
@@ -380,9 +379,5 @@
             // would query the same busy app for focus and frontmost state again.
             // A busy app can time out the only read after its last event. Back off
             // a few times, then wait for the next event so a hung app costs nothing.
-            if failedReads < 4 {
-                failedReads += 1
-                scheduleRead(after: 50 << failedReads)
-            }
         }
     }
```

## Runtime budget

S6 fresh-copy check: **347.71 s (5 min 47.71 s)** for eight known
bugs and two architecture guards. Tracked copies batch `cp -c` by parent
directory. A 116-file copy benchmark took 8.181 s with 116 processes and
1.981 s with 28 processes. Each mutant still gets its own tracked copy,
patch application and bare `swift test`.

That run left about 12 s under the six-minute target. Measure the
whole check when adding a patch. Exploratory candidate runs stay local;
CI runs only the retained known bugs and guards.

S8 reran all ten patches after closed-handle revalidation: all were killed,
with 298.707 s summed across the per-mutant timings. The updated zero-ID
mutant took 30.034 s and the omitted-minimized-window mutant took 34.821 s.
After merging the contracts/timing slices and consolidating the closed-handle
contract, all ten were killed again (302.513 s summed per-mutant time).
Zero-ID took 31.043 s and omitted-minimized-window took 32.435 s.

S12 killed all eleven patches (nine known bugs and two architecture guards),
with 227.013 s summed across per-mutant timings. The new dying-owner mutant
took 21.004 s. Its focused failure was inspected separately; compilation and
missing revalidation checkpoints were not counted as evidence of that bug.

S15 killed all fourteen patches, including the new minimize-between-focus-writes
mutant in 20.978 s. The sum was 867.501 s, including a 601.789 s outlier for
zero-window-id; the other thirteen totaled 265.712 s. No runner budget changed.
An immediate rerun of the full set on the integrated branch killed all
fourteen in 317.8 s, zero-window-id in 22.6 s; the outlier did not recur.
