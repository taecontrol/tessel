# Policy mutants

`swift run tessel-check mutants` applies each `.patch` here to a fresh copy of
the tracked working tree and runs bare `swift test` there. A known-bug mutant
must make the deterministic layer fail; a guard mutant under `guards/` must
make the build or an integrity test fail. A surviving mutant, or a patch that
no longer applies, fails the check. CI runs it on every pull request.

Each known-bug patch semantically reverts a real fix against the current
`Sources/Policy` layout; its header names the bug and where it was fixed. Keep
a mutant only after inspecting its failure: the scenario of the affected
example must reject the historical behavior. A compilation error or an
unrelated scenario failure does not count. Never alter a scenario or the
simulator just to kill a candidate. Exploratory mutation plans stay local.

## Known bugs

| Mutant | Fixed in | Killing scenario |
| --- | --- | --- |
| [stale-focus-enable](stale-focus-enable.patch) | #20 | #2 E2 / #17 E2: enabling preserves a newer native selection |
| [stale-focus-layout-switch](stale-focus-layout-switch.patch) | #20 | #17 E16: a layout switch preserves an unpublished dialog focus |
| [busy-rail-write](busy-rail-write.patch) | #20 | #17 E22: rail writes timed out by a busy app retry with backoff |
| [unpublished-rail-successor](unpublished-rail-successor.patch) | #20 | #17 E19: an unpublished tab successor completes its rail focus |
| [queued-native-tab](queued-native-tab.patch) | #13 | #17 E19: a queued presentation never reselects a former tab |
| [retired-native-tab-root](retired-native-tab-root.patch) | #13 | #1 E5: a retired tab root stays retired on later reads |
| [zero-window-id](zero-window-id.patch) | #24 | #2 E8 (#22): a live row survives a zero window ID |
| [omitted-minimized-window](omitted-minimized-window.patch) | #24 | #2 E8 (#22): a live minimized row survives its omission |
| [dying-rail-owner](dying-rail-owner.patch) | #24 | #17 E11: a dying owner keeps the adjacent-rail landing |
| [owner-check-geometry](owner-check-geometry.patch) | #24 | #17 E16: a redraw keeps an external selection awaiting its owner check |
| [background-discovery-focus](background-discovery-focus.patch) | #24 | #2 E2 / #17 E2: background discovery keeps a pending keyboard focus |
| [minimize-between-focus-writes](minimize-between-focus-writes.patch) | #24 | #2 E25 / #17 E17: a raise preserves a minimize completed during AXMain |

The two #22 paths are separate mutants so one cannot mask the other. The
zero-ID mutant also removes the closed-handle revalidation: on macOS 27 a
closed handle's window-ID lookup reports `illegalArgument` while its
attributes report `invalidUIElement`; #1 E8 separately rejects retaining a
closed row.

The focus-write mutant removes only the AXMinimized recheck before each
AXRaise, including the deferred rail activation retry. Native-front checks
remain before both AXMain and AXRaise.

## Architecture guards

| Mutant | Required failure |
| --- | --- |
| [guards/simulator-import-policy](guards/simulator-import-policy.patch) | E10: the compiler rejects the simulator importing Policy |
| [guards/policy-wall-clock](guards/policy-wall-clock.patch) | E13: the purity test rejects a wall clock in Policy |

## Known gap

Reverting the #1 fix for closed-window settling (destruction settling and
bounded failed-read retries, commit 1a3b9c5) survives #1 E8. No scenario makes
the first read after a close time out and then lets the app recover without
another notification, and the real system has not shown that sequence: closed
handles invalidated on the first sample in every probe. The candidate stays
out of the set until evidence of that behavior exists.

## Runtime

The full set of fourteen took about 5.5 minutes locally (2026-10-18), about
23 s per mutant. Measure the whole check when adding a patch.
