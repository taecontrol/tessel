# Deterministic policy scenarios

`swift test` runs the production catalog, Workspaces, Carousel, closet recovery and
configuration reload against a test-only simulated macOS. It does not launch an
app, create windows, read real configuration, or use Accessibility. Simulator
has only Ports and Assumptions as dependencies. Policy remains a separate target.
Its SwiftPM module permits only the PolicyTests compiler client, so an
accidental Simulator import fails even when Policy is already built nearby.

A scenario owns its simulated machine and retains the production composition
until the result is captured. Tests use invented app aliases and integer window
IDs; traces never query titles or content.

```swift
let result = Scenario.run("keep the native selection") { scenario in
    let mac = scenario.mac
    let app = mac.launch(windows: 3)
    let tessel = scenario.startTessel()
    scenario.settle()
    app.select(1)
    mac.pause(after: .read(app)) // AX state captured; reply not delivered
    tessel.configure(.carousel)
    scenario.settle()
    scenario.expect("window 1 keeps focus", mac.focusedWindow == 1)
    scenario.expect("window 1 is fully visible", mac.isFullyOnScreen(1))
}
requireScenario(result)
```

`Tessel(on: mac)` composes the real objects directly when a test needs to own
its lifetime. `Scenario.startTessel` retains that composition automatically.
The facade exposes published `windows`, workspace `status`, configuration
status, `configure(.off / .stack / .carousel)`, `changeConfig` (the real 30 ms
reload debounce), `press("focus right")`, and `quit`. Presses go through the
in-test hotkey registration. File watching and Carbon stay in real journeys.

Use `Scenario.step` to name actions in a failure's schedule. `expect` collects
failures without recording a Swift Testing issue; `requireScenario` records
its report. Framework tests can inspect an intentionally failed result.
Always finish with `settle` before final expectations. A directly owned
SimulatedMac needs `defer { mac.shutdown() }`, including when a run stops early.

## Ordering

`mac.orders(of:requiring:)` enumerates every topological order of a small list
of distinct steps. Each `Precedence(a, before: b)` constrains that enumeration.
Each order is crossed with all three `WriteOrder` strategies:

- `eager`: after each named scenario step, drain already submitted worker work,
  leaving main notifications and future timers queued;
- `writesFirst`: prefer ready serial work before main notifications;
- `readsFirst`: prefer queued main notifications before ready serial work.

Every strategy preserves each lane's FIFO order. AX replies cost virtual time,
so other lanes and timers can run while a call is outstanding. Named read
pauses stop after paired focused-window and frontmost reads in one worker job.
`deliver(app)` resumes that lane and stops after its publication main hop;
native notifications cannot satisfy that checkpoint. `settle` releases all
explicit holds and drains the machine. For finer worker interruption points,
`PausePoint.call` names a trace operation. Trying to pause a synchronous main
frame stops as unmodeled; it never reports a pause after executing its effect.

The scheduler uses one real thread per serial lane and the actual main lane,
with one baton holder at a time. `sync` drains preceding work while main is
blocked; its body runs on the lane thread. Equal-deadline timers use submission
order. Neither detail may be an oracle in a scenario. Transition and absolute
virtual-time limits stop unsettled runs and report pending lanes and timers.
Every failed run must still call `shutdown` to release its parked threads.

Every `Scenario.run` contributes its schedule name and SHA-256 trace digest to
a process-wide aggregate, sorted so that test execution order cannot change it;
the process prints one `trace digest:` line at exit. One small omitted-handles
and subscription-removal scenario is replayed twice in process. Inputs,
iteration order and trace text are independent of Swift hash seeds.

## Adding scenarios and assumptions

Put accepted policy examples in `Tests/PolicyTests/Scenarios`, with the literal
issue/example ID in the `@Test` name, for example `#17 E2`. Framework tests
belong in `Framework` and registry/purity checks in `Integrity`. Preserve the
example's assigned layer in `docs/development.md`.

The simulator exposes app/user actions: opening, closing, selecting, native
tabs, sheets via `WindowSpec.parent`, hide/unhide, minimize/restore,
fullscreen, drag/resize, app hang/resume or temporary busy state, launch and
termination. Window-list choice sequences represent native omissions, zero
IDs, failed/non-array reads and retained closed handles. They do not publish
catalog rows or decide workspace membership. The production catalog must
interpret the resulting port calls.

Content tabs flatten their selected page: an empty page contributes no contents
or child, while a populated page exposes its static-text leaf in both AXContents
and AXChildren. The content handles remain distinct from the tab buttons.
Content tab buttons have no AXChildren value. Segmented radio groups expose
only those buttons as children and report unsupported AXTabs/AXContents;
the other segmented roles retain conservative alternative shapes.

`addTab(to:activating:)` creates a new native root on the active desktop, retaining
the group's bar and frame. A background insertion can therefore be CG-visible
before policy reconciles a closeted group's hidden intent; it does not inherit
the reference root's completed Space move or activate the app.

`beginFullscreenTransition(_:publishingRoot:)` chooses whether AppKit exposes
an auxiliary display-sized `AXUnknown` root. It stays live across reads until
`finishFullscreenTransition` removes it; `enterFullscreen` and `leaveFullscreen`
set the ordinary window's final state independently. Native creation and
destruction notifications accompany the auxiliary root. The workspace fullscreen
example exercises both choices and settles root removal before fullscreen exit.

`WindowSpec.positionAcceptance` chooses exact AX position acceptance or the
native right-edge clamp that leaves a 40-point strip (the default). App drag
actions keep their requested position. Size constraints remain independent.
`WindowSpec.offDisplayMembership` chooses whether a window entirely outside
the display remains in the active Space's CG list (included by default).
Frame intersection alone does not prove native visibility or occlusion.
Space membership is a set: showing a window restores ordinary active membership
and, by default, retains its invisible closet membership until destruction.
`closetPort(retainingShownMembership:)` also models immediate removal. A shown
window with both memberships is visible and is no longer in the closet.

`deferNextActivation(completion:)` accepts the AX request before activation is
confirmed. Completion can follow a main/raise write (the default), arrive as a
native event, or wait for another activation request. Retry scenarios select
the last choice explicitly; native completion does not require that retry.

`beginMinimize` and `finishMinimize` separate the pending Dock transition from
its completion. AXMain or AXRaise can cancel the pending operation. After
completion AXMain leaves the window minimized, while AXRaise restores it.
`WindowSpec.minimizedRaiseReply` chooses success (the default) or cannotComplete;
both restore the window and publish its native restore notification. A timeout
before a hung app processes the request still has no effect.

`terminate(activating:crash:publishesNotification:exitOrder:)` separates a dying
app's destroyed windows from the process-existence probe. The process can exit
before promotion or remain unreaped through survivor activation (the default).
Publishing termination completes process exit before lifecycle delivery.
The rail termination example enumerates both exit orders without changing its
adjacent-rail landing assertion.

A new OS behavior gets a stable kebab-case ID and a one-sentence statement in
`Assumption`, and an `assume(.caseName)` call at its simulator definition.
Real contracts in `Tests/Acceptance/Contracts*.swift` declare
`contract(.caseName)`. The source registry locates both from `#filePath`, rejects
unknown IDs, and rejects declared assumptions with no simulator behavior.
A simulator change needs contract evidence under the project's review rules.
An unmodeled port/operation/attribute must stop the run, never return a plausible
successful value.

## Known gap

No scenario covers the closed-window settling fixed for #1 in 1a3b9c5:
destruction settling and bounded retries after a failed read. Reverting that
fix still passes #1 E8, because no scenario makes the first read after a close
time out and then lets the app recover without another notification. The real
system has not shown that sequence: closed handles were invalid on the first
sample in every probe. Add the scenario once a contract shows the behavior.
