# Deterministic policy scenarios

`swift test` runs the production catalog, Workspaces, Rails, closet recovery and
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
    tessel.configure(.rails)
    scenario.settle()
    scenario.expect("window 1 keeps focus", mac.focusedWindow == 1)
    scenario.expect("window 1 is fully visible", mac.isFullyOnScreen(1))
}
requireScenario(result)
```

`Tessel(on: mac)` composes the real objects directly when a test needs to own
its lifetime. `Scenario.startTessel` retains that composition automatically.
The facade exposes published `windows`, workspace `status`, configuration
status, `configure(.off / .stack / .rails)`, `changeConfig` (the real 30 ms
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

The framework catalog includes the enabling enumeration, omitted handles and
subscription removal. It replays twice, compares each SHA-256 trace digest,
and prints one aggregate `trace digest:` line plus elapsed time. Its inputs,
iteration order, and trace text are independent of Swift hash seeds.

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

A new OS behavior gets a stable kebab-case ID and a one-sentence statement in
`Assumption`, and an `assume(.caseName)` call at its simulator definition.
Real contracts in `Tests/Acceptance/Contracts*.swift` declare
`contract(.caseName)`. The source registry locates both from `#filePath`, rejects
unknown IDs, and rejects declared assumptions with no simulator behavior.
A simulator change needs contract evidence under the project's review rules.
An unmodeled port/operation/attribute must stop the run, never return a plausible
successful value.
