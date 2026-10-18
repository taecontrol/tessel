# Spike: deterministic policy verification

Discovery work, not production code. Nothing here is built by `scripts/build`
or run by `scripts/verify`. Reusing any of it is new work under the project's
normal practices.

## Question

Can tessel's real workspace and rail policy (`Workspaces.swift`, `Rails.swift`)
run against an in-process simulated macOS so that a known race reproduces on
every run, without timing? The race is the stale native focus when enabling
rails, fixed by 6b80843 ("Never raise a stale focus when enabling
workspaces"). Before that fix it failed foundation and rails setup waits on
xcode-27 intermittently (issue #21).

It decides whether acceptance examples about policy can move from timed
end-to-end waits to a deterministic layer.

## Method

- `Workspaces.swift` reads the system through `WorkspaceSystem`
  (`Sources/App/WorkspaceSystem.swift`): frontmost app, running apps, screen,
  on-screen order, process liveness, delayed work and Finder activation. The
  app passes the real system and still builds; the change is 31 insertions and
  33 deletions in `Workspaces.swift`.
- `Simulation.swift` replaces `WindowCatalog`, `WindowCloset`, `Hotkeys` and
  `SnapshotStore` with a simulated world: windows, each app's key window, the
  frontmost app, a closet, an AX write queue, AX reads captured at one moment
  and delivered later, and a virtual clock.
- `Scenario.swift` sets up one app with windows 1, 2 and 3 (3 key, already
  read by tessel) and runs every order of four steps: the user selects 1 (U),
  the catalog reads the app (R), the read is delivered (D), rails is enabled
  (E), with U before R before D. Each order runs with AX writes executed
  eagerly, writes before reads, or reads before writes: 12 schedules.
- After everything settles, window 1 must be key and fully on screen.
- `run` compiles the policy as checked out and with 6b80843 reverted.

```sh
Spikes/deterministic-policy/run 1000
```

## Results

| Schedule | Current policy | 6b80843 reverted |
|---|---|---|
| URDE (all) | pass | pass |
| URED (all) | pass | fail: 3 key, 1 at x 968 |
| UERD (all) | pass | fail: 3 key, 1 at x 968 |
| EURD eager | pass | pass |
| EURD writes first / reads first | pass | fail: 3 key, 1 at x 968 |

- 1000 repetitions of all 12 schedules gave identical results for both
  variants; 12,000 schedules took about 0.8 s.
- The failing state matches the xcode-27 dump of rails E22 in run
  39129084478: the first window at `[968, 41, 451, 717]` and the third focused.
- Surprise: EURD also fails before the fix. Enabling before the user's
  selection queues a raise of the then-focused window; when that write runs
  after the selection, it takes focus back. The CI evidence did not show this
  order; the fix covers it.

## Remaining uncertainty

- Fidelity: `cancelPresentations` approximates the catalog's presentation
  tokens; reads are atomic; one app; no AppKit activation handoff; Finder is
  not simulated. Each assumption needs a real-macOS contract test.
- Only the rails-enable path was exercised. Commands, sends, sheets, tabs and
  minimize paths depend on more catalog behavior.
- It says nothing about latency or about failures caused by macOS itself, such
  as the empty snapshot hypothesis of #22.
