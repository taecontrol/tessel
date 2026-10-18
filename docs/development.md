# Development

Use macOS 27 or later on Apple silicon, with Xcode 27 selected by `xcode-select`.
The app, its build tool, and the acceptance harness are Swift with Apple's
frameworks; there are no package dependencies. `Package.swift` holds the
development tools, internal policy libraries and test
targets ([ADR 0004](adr/0004-verify-policy-against-a-simulated-macos.md)).
Never launch one of its products as the app.

## Signing and launching

Create `Signing.local.xcconfig` in this worktree, containing
`CODE_SIGN_IDENTITY =` followed by the name or SHA-1 fingerprint of an available
code-signing identity from your keychain. Use your Apple Development identity.
The file is ignored; never commit its contents, a certificate, or a team ID.

Run `scripts/build`. It builds the `tessel-build` tool from `Tools/Build`, which
compiles optimized binaries and installs signed bundles in `.build/apps`. It refuses missing, unavailable, or ad-hoc signing identities
before building a bundle. Every rebuild changes the app binary's build version,
so the permission-preservation test exercises a real signature change.

Open the development bundle and grant Accessibility in System Settings:

```sh
open ".build/apps/Tessel Dev.app"
".build/apps/Tessel Dev.app/Contents/MacOS/tessel" status --json
```

The read-only CLI accepts `windows [--json]` and `status [--json]`.
You can symlink this bundled CLI into a directory on your `PATH`.
With a custom `XDG_CONFIG_HOME`, pass the same value to `open --env` and the CLI.
The bundle ID and config path select the instance the CLI observes.
Every JSON answer carries `answeredAt`: raw monotonic seconds
(`CLOCK_MONOTONIC_RAW`, the clock `clock_gettime_nsec_np` reads) when tessel
read the state it reports. `status --json` has it at the top level, and each
`windows --json` record repeats it. Text output is unchanged.

Development uses `com.taecontrol.tessel.dev`; `scripts/build --variant daily`
uses `com.taecontrol.tessel`. Keep the signing identity stable across rebuilds.
Never launch an unsigned or ad-hoc-signed bundle with either ID. Doing so can
revoke the existing Accessibility grant. Bundles must stay outside `/tmp`,
where LaunchServices cannot register them reliably.

## Verification

Bare `swift test` runs the deterministic scenarios, simulator framework and
integrity checks, and tooling tests. It compiles no Acceptance target, launches
no app or fixture, creates no windows and needs no Accessibility permission.
The tests run in seconds after compilation and print total test time plus one
SHA-256 `trace digest:` line. `swift run tessel-check determinism --runs 20`
requires every run to pass with the same digest. Separate processes vary
Swift's hash seed, which is what can reorder an unsorted iteration; the digest
test also runs its fixed catalog of 25 scenarios twice within each process. CI runs 3.

The production catalog, Workspaces, Rails, closet recovery and config reload run
against a simulated macOS behind small platform ports. Its virtual clock proves
tessel's own delays; enumerated schedules expose races without depending on
macOS timing. A failed scenario reports the expectation, schedule and port trace
with virtual times, invented app aliases and window IDs. Unmodeled calls and
runs that exceed a transition or virtual-time bound fail instead of inventing a
result or hanging. See [Policy scenarios](policy-scenarios.md) for authoring and
replay, and [ADR 0004](adr/0004-verify-policy-against-a-simulated-macos.md) for the seam.

Simulator depends only on Ports and Assumptions, never Policy. Each modeled OS
behavior declares an `assume(.caseName)` from `Tests/Assumptions`; a real contract
in `Tests/Acceptance/Contracts*.swift` declares the matching
`contract(.caseName)`. The registry rejects unknown IDs and missing behaviors or
contracts. Contracts pin macOS assumptions through the signed independent
observer; journeys check wiring; latency measures speed. Every accepted example
has exactly one layer in the [example map](#acceptance-example-layers-24).

For real-system verification, stop this worktree's development app and every
other tessel instance managing windows. Use an awake, unlocked desktop:

```sh
scripts/build
scripts/verify --contracts
scripts/verify --journeys
scripts/verify --latency
scripts/verify --resources
```

With no arguments, `scripts/verify` runs every real-system suite except the
disposable-runner permission steps. `--journeys` includes those steps on CI;
`--permission` selects just those steps. The signing-and-permission journey has
separate signing and permission tests so the default can skip only the latter. Captures
run only with `TESSEL_CAPTURE_WORKSPACES=1`. Select a suite as above or pass a test
name fragment, such as `scripts/verify switchWorkspaces`. Empty selections fail
before a GUI session starts. The script sets `TESSEL_ACCEPTANCE=1`; a direct
`TESSEL_ACCEPTANCE=1 swift build --build-tests` compiles these suites without
launching them.

All real-system state checks use the single generous 5 s `margin` in
`Tests/Acceptance/Support.swift`, including setup, lifecycle, CLI transport,
contracts and captures. Their final-state API accepts no per-call deadline.
Only `Latency.swift` judges elapsed time. Compilation and CI permission
provisioning have separate process limits; resource observation retains its
ADR 0003 window and settle. The integrity check rejects shorter state waits and
retired `since:` or `within:` APIs outside latency.

### Signed fixture harness

The harness checks the desktop session and holds a temporary `caffeinate`
assertion until cleanup. It launches the signed development bundle through
`open`, an isolated temporary `XDG_CONFIG_HOME`, real AppKit fixtures and an
independent signed AX/CG observer. A test-only local socket drives the fixtures;
tessel is observed through its bundled CLI. The harness cleans up its own
processes and data. It always passes `--test-fixture-only`, so only fixture
processes are observed or managed, including crash recovery. The daily build
rejects that argument. Another tessel instance can contaminate these fixtures.

The observer validates the running fixture's signed identifier before reading a
window or posting a key, revalidating on every operation. Audit-bound Security
code objects avoid repeated construction during latency sampling; exec and PID
reuse invalidate the binding, and denied task-name access retains stateless
validation. A journey replaces a fixture's code and checks rejection while its
PID still lives. No full window listing, title or personal config is printed or
saved. Fixture replies reserve 64 KiB per socket because twenty-window AX
observations exceed macOS's default 2 KiB datagram limit; no system socket
settings change.

Full setup observations allow 100 ms per AX read; focused-only observations use
20 ms so a busy app can be sampled again. A timeout is an unanswered read, not
proof that a window is absent or unfocused. The oracle reads the frontmost app
through live AX because cached LaunchServices metadata can lag activation.
Fixtures cooperate with AppKit's activation handoff without ordering windows.
Their minimize/restore acknowledgement follows AppKit's completion notification,
after the Dock animation, when macOS sends the AX event.

Each observation carries raw monotonic `sampledAt`; JSON CLI answers carry
`answeredAt`. A final-state evaluation uses its latest input's production time,
or receipt time when no timestamp exists, so descheduling the test process does
not turn an earlier observer sample into tessel latency (issue #21). The script
prints its scheduling priority and relaunches a clamped process tree as an
`Interactive` launchd job in the user's GUI session, forwarding environment,
output and exit status. Priority below 31 indicates a utility/background clamp
that child QoS changes cannot lift. Interrupting verification removes the job.

### Resources

`Resources.swift` keeps foundation E22's twenty default-config windows, workspace
E36's twenty windows across ten workspaces, and rails E29's twenty windows
across five workspaces and multiple rails. Each retains its setup and one-second
settle, then observes one 20-second idle window from outside the app with
`proc_pid_rusage` (`rusage_info_v0`). Interrupt wakeups must be at most 11;
user + system CPU must be at most 100 ms, converting Mach ticks with
`mach_timebase_info`. Physical footprint must be below 30 MB at both boundaries;
a start failure stops before the idle wait. Measurements and exceeded limits
are printed. The CPU oracle remains a named journey self-check.

The wakeup limit targets work recurring every two seconds or less; CPU also
catches work that never sleeps. `Tests/Acceptance/resource-budget.json` and
[ADR 0003](adr/0003-verify-idle-work-with-wakeups-cpu-and-footprint.md) retain the
limits and evidence. Changing a limit requires an owner decision and new
evidence. LaunchServices notifications can raise local idle CPU (issue #15).
Do not run `sample` during a measured window: it suspends the app and changes
its counters.

### CI

CI runs on `xcode-27` (macOS 27). The Policy job runs bare tests, the layer check,
known-bug mutants, trace repetition and the simulator-evidence guard. The
Acceptance job signs and builds once, then runs contracts, journeys (including
permission denial/restart), latency, resources and the rails status-item capture.
Resources retain their 90 s command budget. The job has a ten-minute timeout for
these suites, signed rebuilds and runner setup, with margin for a slower runner.
Latency samples and the app-rendered rails capture are uploaded even on failure.

The runner first hides the Dock: fixture Dock icons can move the visible frame's
bottom edge by two points on its 1024×768 display. It creates a short-lived
certificate in a temporary keychain, removed at the end; no signing material is
stored in GitHub. Before any harness suite, `scripts/ci-accessibility` grants the
development app and fixture access on that disposable runner. Only `CI=true`
together with `GITHUB_ACTIONS=true` enables
Accessibility denial and restart steps. Local runs use the signed development
bundle's existing permission and never provision the Accessibility database.

## Configuration and observation

The config is `$XDG_CONFIG_HOME/tessel/tessel.toml`, defaulting to
`~/.config/tessel/tessel.toml`. An absent file or an empty document disables all
experiments. Unknown keys and invalid
TOML produce a line-numbered error; the last valid configuration stays active.
Saving, replacing, or deleting the file reloads it automatically. `status --json`
reports the effective config, its revision, its source state, and any error.

```toml
[experiments]
workspaces = true

[gaps]
outer = 10

[keys]
alt-1 = "workspace 1"
alt-shift-1 = "send 1"
alt-j = "focus next"
alt-k = "focus previous"
```

The workspace experiment manages the primary display only. It shows one tiled
window per workspace, filling `visibleFrame` minus the outer gap. Dialogs float
at their original frames and belong to their workspace; sheets follow their
parents. Size-constrained windows float centered with the reason
`cannot fill the screen`. Native fullscreen windows have no workspace. Stage
Manager is assumed off, and external monitors are outside the experiment.

Default shortcuts are Option+1…0 for workspaces 1…10, Option+Shift+1…0 to send
the focused window and follow it, and Option+J/K to cycle in arrival order.
`[keys]` overrides merge with defaults; an empty command disables that binding.
Keys are lowercase ANSI letters and digits, with optional `alt`, `shift`, `ctrl`,
and `cmd` modifiers. Commands are `workspace N`, `send N` (N = 1…10),
`focus next`, and `focus previous`. `outer` is a nonnegative number of points.
Keys and gaps are validated even with the flag off. Invalid edits preserve the
last valid configuration and registrations. Carbon cannot detect a shortcut
registered by another process; resolve a noticed conflict with `[keys]`.

Inactive windows live in one invisible Space, returned to the current desktop
when shown. Disabling the flag or quitting returns all managed windows. Startup
also recovers orphaned windows after a crash, even when the flag is off; no
workspace membership is persisted. See [ADR 0002](adr/0002-hide-inactive-windows-in-a-skylight-space.md)
for the private system dependency and its tradeoffs.

Window records contain an ID, app name, bundle ID, state, reason, native tab
count, `workspace` (1…10 or null), `visible` (CG on-screen membership), and
`answeredAt`.
`state` includes `fullscreen`. Titles are never queried. `status --json` adds
`workspaces.enabled`, `reason`, `active`, `gaps`, and the effective `keys`.
With the experiment disabled, tessel observes without managing ordinary windows.

Native tab groups have one front entry while visible or hidden. When a group is
minimized, macOS 27 exposes each tab as an AX window, and only one reports the
group's tab count. Tessel lists those minimized entries as reported; it does not
guess which windows belong together. Restoring the group returns to one entry.
Keeping one entry while minimized needs further investigation beyond #1.

`AXTabGroup` alone also describes content controls. On macOS 27, AppKit's native
tab bar publishes its `AXTabs` buttons within `AXContents`; an `NSTabView`
publishes the selected page's content instead. Tessel uses that identity
relationship and counts only `AXTabs`, excluding an optional New Tab button.
Fixtures cover empty and populated content tabs, segmented controls, native
tabs without close buttons, and native windows containing more content tabs.
Their independent native-count oracle is `NSWindow.tabGroup.windows`.
This relationship follows the installed AppKit implementation, rather than a
public guarantee about future OS versions or custom Accessibility publishers.
AXWindows can temporarily omit a live window during a Space move, fullscreen,
or an app hide/unhide. The catalog revalidates known AX handles and retains sheet
ownership. A native tab's bar keeps its AX identity when selection replaces the
front window, so that identity retires the old tab root without retaining an
extra window. A read can find the old root without its bar before focus or the
moved bar identifies the successor, and AXWindows can keep listing a retired
root afterwards. An unfocused root without a bar keeps the bar identity it last
showed, so the successor retires it and it stays retired while another listed
window holds that bar. A focused window without a bar, such as a tab dragged
out of its group, is an ordinary window. A queued presentation never writes to
a tab that is no longer its group's front, rechecked before each focus write,
and a classification change reasserts focus only when the app reports another
window, so a raise cannot select the former tab again over the user's choice.
Minimized tab entries continue to follow AppKit's published list.
The catalog carries a native front's replacement relationship into Workspaces,
which preserves membership, arrival position, and focus history. Its next render
reconciles visibility for the replacement CG window, including hidden groups.
The group's last fill result also follows its front; an ordinary show retries
that result without resizing the group merely because another tab was selected.
The close fixture can retain a closed NSWindow object to verify that revalidation
still retires its AX window.

Policy scenarios prove workspace decisions; real journeys drive Carbon and
observe AX frames/focus and CG visibility independently. The trusted fixture
posts CGEvents only while a fixture window is frontmost and on screen. Safety
refusals are retried before posting within the final-state margin; transport
failures and posted events are never retried. Latency starts at the actual post.

Focused-only reads use `AXFocusedWindow` directly, including a focused sheet's
parent: AXWindows can omit a live window during a Space move. CG independently
supplies fixture visibility. Focused frame and main state are read together;
full/sheet observations retain parent-child relationships. `expectedPID` can
restrict AX reads to the known destination while CG still observes every
fixture. Only observations explicitly checking an empty workspace inspect
Finder, so unrelated AX reads cannot delay a sample.

In fixture-only mode, activating Finder requires a successful AXWindows read
without ordinary windows. Its desktop scroll area is allowed; unknown entries
and failures block activation. Failed reads retry twice off the main thread,
and only the render that requested them may activate Finder. No window content
is inspected. The simulator proves the decision; real contracts pin Finder's AX
shape. Crash-recovery journeys check that a blocked initial AX read keeps orphans
hidden and recovery follows the first successful enumeration.
The fixture includes AppKit and SwiftUI width constraints, dialogs, sheets,
native fullscreen, and separate instances for activation and hung-app checks.
`--test-missing-skylight` (requiring fixture-only development mode) tests safe
disablement. `--test-failed-hide`, with the same restrictions, verifies cleanup
when an asynchronous hide fails. Capture E37 for owner review with:

```sh
TESSEL_CAPTURE_WORKSPACES=1 scripts/verify captureWorkspaceMenu
```

The harness adds `--test-capture-ui`, accepted only together with fixture-only
development mode. The running app exports its own rendered AppKit status button
and menu views into the isolated config directory; the harness copies them to
`.work/captures`. This requires no Screen Recording permission and captures no
desktop or other app windows. Review the two workspace numbers and the disabled
reason in those images. The capture facility is absent from the daily build.
Run this capture only when owner review requires new evidence; it is separate
from the automated gates. The issue #2 delivery's E37 capture is already accepted.

Workspace E36 enforces the same unchanged idle limits as foundation E22.
Before the first public release (#6), revisit the bundle IDs, config schema,
and read-only CLI contract. A command that changes state or exposes titles needs
an architecture decision before implementation.

## Rails experiment (#17)

`[experiments] rails = true` enables workspaces in rail layout, independently
of the `workspaces` flag. Without it, the workspace experiment keeps its
one-window layout and shortcuts. With both flags absent, tessel only observes.
Reloading into rails forms one row per existing workspace in arrival order.
The active workspace and focused window remain selected. Enabling either
layout never raises the front app's last-read focus: that read can predate a
newer native selection, so the first render only lays windows out and the
next focus report selects the window that really has focus. Membership and rail
positions are session state, with no persistence across restarts.

A rail is a horizontal row of windows with individual widths, separated by the
outer gap. Windows keep their current width, capped at the rail area's width,
and take the area's height. Height-constrained windows remain tiled, aligned
to the top; their CLI reason explains the constraint. A row that fits starts
at the area's left edge. A longer row forms a ring: the last window's next
neighbor is the first. Focus moves without scrolling when the destination is
fully visible. Otherwise the row scrolls to reveal it with a 56-point peek;
wide windows are centered. The 56-point peek is the scroll target. Each window
then uses the single ring placement exposing the most of it. In a short ring,
that can put the next neighbor on the opposite edge, for any window count.
Completely off-screen windows go into the closet.
Focus, scrolling and elevator travel never resize windows.
A rail write that times out against a busy or briefly hung app is retried
after 100, 200, 400 and 800 ms, like a failed read, unless a newer render
replaces it. An app that stays hung longer keeps its stale frame until the next
render.

Option+H/L (`focus left|right`) wraps within the current rail. Option+K/J
(`focus up|down`) visits adjacent rails, stopping at either end. Each rail
remembers its focused window and scroll position. Option+Shift+H/L
(`move left|right`) swaps neighbors, including across the ring's end.
Option+Shift+K/J (`move up|down`) inserts the window after the destination
rail's remembered window and follows it. Moving beyond an end creates a rail,
except when already alone at that end. Empty rails disappear.

New windows enter to the right of the current window. Closing selects the
left neighbor and closes the gap. Sending still follows the window to the
selected workspace, inserting after its current rail's remembered window.
When a rail empties on close, move or send, its current position selects the
rail below, or the one above if it was last. Minimize/hide instead selects the
most recently focused available window anywhere in the workspace, even when
that empties a rail. This preserves the workspace experiment's focus policy.
Minimized or hidden windows leave their rail temporarily; restoring inserts
after their former left neighbor when that rail survives, or after the current
window otherwise. External activation selects the window's workspace and rail
and reveals it. Dialogs float as before, sheets follow their parents, and
native fullscreen windows have no rail or workspace.

A manually moved window stays where released until the next rail render.
Successful window moves redraw the rail even when a ring's final target frames
coincide. A manual resize updates that window's width and repositions its right
neighbors.
Disabling rails or quitting returns all managed windows fully inside the
visible desktop. After a crash, closet recovery still works with the flag off,
but a partially visible window stays where it was: no persisted membership
identifies it as a former rail window.

Numeric workspace/send shortcuts keep their meanings. `focus next|previous`
remain bindable aliases for rail traversal, with no default binding in rails.
`[keys]` overrides merge with the layout's defaults. Directional rail commands
are validated with the flag off, but their shortcuts are registered only while
rails is enabled. `windows --json` adds
nullable one-based `rail` and `slot` fields, and `status --json` reports
`workspaces.layout`, the nullable current `rail`, and `railCount`. The status
item shows the workspace number and one bar per rail, highlighting the current
one; its AX label includes the current rail and total. The map overlay belongs
to #18, and the floating layer to #19.

Rail scenarios prove geometry, membership, native-tab replacement, retries and
focus ordering in virtual time. Journeys check real scroll/elevator hotkeys,
CLI fields, the status-item AX label and recovery. Fixtures accept width
fractions of the usable area, keeping fitting and overflowing setups independent
of screen size. Resource E29 runs with `scripts/verify --resources` and the
unchanged ADR 0003 limits. Capture the app's own status button with:

```sh
TESSEL_CAPTURE_WORKSPACES=1 scripts/verify captureRailsStatusItem
```

The PNGs are `.work/captures/E26-workspace-1-rail-{1,2}.png`. Both owner captures
live in `Tests/Acceptance/Captures.swift` and require the capture environment flag.

## Journeys and latency (#24)

`scripts/verify --journeys` runs eight journeys. The signing-and-permission
journey includes the disposable-runner-only permission steps under the guard
described above. Foundation E11 (CLI failure) and E14 (permission restart) prove
their timing decisions in the deterministic layer. The same journey wiring
checks wait only for the final state within 5 s and carry no example IDs.

The CLI's connect, write and read waits share a 750 ms virtual deadline;
interrupted polls consume that same budget. An absent listener fails immediately.
The permission monitor requests its next probe every 750 ms, with the existing
50 ms timer tolerance, and requests relaunch immediately on a trusted answer.
Its virtual proof bounds that scheduling share at 750 ms (800 ms with tolerance),
excluding macOS time spent running the probe and opening the replacement app.
An outstanding probe prevents overlap; a denied or failed probe retries on the
next tick. The original 3 s restart promise includes those external costs.

The journey steps carry these example IDs; decision examples belong to the
deterministic policy layer and are not tagged in these files:

| Journey | Journey example IDs |
| --- | --- |
| Enable | #1 E9; #2 E1; #17 E1 |
| Switch | #2 E31, E32 |
| Send | #2 E35 |
| Rail scroll and elevator | #17 E24, E25 |
| Reload | File watcher wiring for save, atomic replace, chmod and delete |
| Crash, quit and disable | #2 E28, E29, E34; #17 E3 |
| CLI and config files | #1 E10, E12; #1 U-cli-args, U-private-transport, U-read-only-transport, U-stalled-clients, U-observer-identity, U-cpu-oracle, U-notification-retries |
| Signing and permission | #1 E13, E15, E16 |

Latency owns #2 U-switch-budget and #17 E28 in `Tests/Acceptance/Latency.swift`.
It records 100 workspace switches and 100 rail moves (50 scrolls and 50 elevator
trips). Each sample starts at the trusted fixture's real key `postedAt` and ends
at the independent observer's `sampledAt` when destination frames, focus and CG
visibility all match. Samples must finish within the final-state margin.
Only this suite judges elapsed time: each kind's nearest-rank p95 must be at
most 200 ms. It prints p50, p95 and maximum, and writes `.work/latency.json` with
the samples, counts, percentiles and nonpersonal run metadata. CI uploads that
artifact even on failure; incomplete runs retain their partial counts and the
failed sample index. No window listings or titles reach the artifact.

## Acceptance example layers (#24)

This table is the maintained example-to-layer map for issues #1, #2 and #17.
Its format is exactly `Example | Layer`, one literal ID per row, with no
description in either cell. Numbered IDs use `#1 E9`; unnumbered IDs use
`#1 U-cli-args`. P means deterministic policy, J journey, L latency,
R the unchanged resource suite, and X an owner-reviewed capture.
Foundation E13 belongs to J; supplementary visual permission evidence does
not assign it to a second layer.

An ID appears literally in its `@Test` name or a journey's `step` name.
P files live in `Tests/PolicyTests/Scenarios/`, J in
`Tests/Acceptance/Journeys*.swift`, L in `Tests/Acceptance/Latency.swift`,
and R in `Tests/Acceptance/Resources.swift`. X tests use `capture*` function
names in Acceptance, or live in `Tests/Acceptance/Captures*.swift`.
Contracts carry assumption IDs, never example IDs. The E20 integrity check
rejects missing tags, unmapped tags, duplicate map rows and tags in another
layer. Every mapped ID must have a tagged test in its own layer.

| Example | Layer |
| --- | --- |
| #1 E1 | P |
| #1 E2 | P |
| #1 E3 | P |
| #1 E4 | P |
| #1 E5 | P |
| #1 E6 | P |
| #1 E7 | P |
| #1 E8 | P |
| #1 E9 | J |
| #1 E10 | J |
| #1 E11 | P |
| #1 E12 | J |
| #1 E13 | J |
| #1 E14 | P |
| #1 E15 | J |
| #1 E16 | J |
| #1 E17 | P |
| #1 E18 | P |
| #1 E19 | P |
| #1 E20 | P |
| #1 E21 | P |
| #1 E22 | R |
| #1 U-cli-args | J |
| #1 U-private-transport | J |
| #1 U-read-only-transport | J |
| #1 U-stalled-clients | J |
| #1 U-observer-identity | J |
| #1 U-cpu-oracle | J |
| #1 U-notification-retries | J |
| #2 E1 | J |
| #2 E2 | P |
| #2 E3 | P |
| #2 E4 | P |
| #2 E5 | P |
| #2 E6 | P |
| #2 E7 | P |
| #2 E8 | P |
| #2 E9 | P |
| #2 E10 | P |
| #2 E11 | P |
| #2 E12 | P |
| #2 E13 | P |
| #2 E14 | P |
| #2 E15 | P |
| #2 E16 | P |
| #2 E17 | P |
| #2 E18 | P |
| #2 E19 | P |
| #2 E20 | P |
| #2 E21 | P |
| #2 E22 | P |
| #2 E23 | P |
| #2 E24 | P |
| #2 E25 | P |
| #2 E26 | P |
| #2 E27 | P |
| #2 E28 | J |
| #2 E29 | J |
| #2 E30 | P |
| #2 E31 | J |
| #2 E32 | J |
| #2 E33 | P |
| #2 E34 | J |
| #2 E35 | J |
| #2 E36 | R |
| #2 E37 | X |
| #2 U-switch-budget | L |
| #17 E1 | J |
| #17 E2 | P |
| #17 E3 | J |
| #17 E4 | P |
| #17 E5 | P |
| #17 E6 | P |
| #17 E7 | P |
| #17 E8 | P |
| #17 E9 | P |
| #17 E10 | P |
| #17 E11 | P |
| #17 E12 | P |
| #17 E13 | P |
| #17 E14 | P |
| #17 E15 | P |
| #17 E16 | P |
| #17 E17 | P |
| #17 E18 | P |
| #17 E19 | P |
| #17 E20 | P |
| #17 E21 | P |
| #17 E22 | P |
| #17 E23 | P |
| #17 E24 | J |
| #17 E25 | J |
| #17 E26 | X |
| #17 E27 | P |
| #17 E28 | L |
| #17 E29 | R |

## Deterministic checks (#24)

Run these commands from the repository root. They use SwiftPM tooling only;
they do not launch the app or fixtures. Child test processes remove
`TESSEL_ACCEPTANCE` and the purity-test override from their environment.

```sh
swift test
swift run tessel-check layers
swift run tessel-check mutants
swift run tessel-check determinism --runs 100
swift run tessel-check simulator-evidence --base origin/main --body-file pr-body.txt
```

`layers` lists tests without entering their execution scopes, and rejects
Acceptance compilation or discovery. `mutants` copies the tracked tree with
its current working contents to a fresh temporary directory per patch,
using APFS clones when available. Stage new source files before running it.
It applies each patch under `Tests/Mutants/` and requires a failing bare
`swift test`; known bugs must reach test failures, and guards must fail at
their intended boundary. An obsolete patch or surviving mutant fails the
check. It removes its copies and reports every mutant's result and time.
The patch inventory records fixing commits and rejected candidates.

`determinism` requires successful runs and one identical SHA-256
`trace digest:` line per run, printing the digest and each run's time.
`simulator-evidence` checks `<base>...HEAD`: a change under `Tests/Simulator/`
needs either a changed `Tests/Acceptance/Contracts*.swift` file or a PR-body
line starting exactly `Simulator-evidence:` with non-empty text after it.
CI passes the body through an environment variable into a file, then runs
the guard; it never treats the body as shell source.
