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
compiles optimized binaries and installs signed bundles in `.build/apps`. Each
whole-module compile uses about one core, so the app, CLI and fixture binaries
compile concurrently. It refuses missing, unavailable, or ad-hoc signing identities
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
Swift's hash seed, which is what can reorder an unsorted iteration; every scenario the
suite runs contributes to that digest, and one small scenario is also replayed
twice within each process. CI runs 3.

The production catalog, Workspaces, Carousel, closet recovery and config reload run
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
run only with their opt-in flag: `TESSEL_CAPTURE_WORKSPACES=1` for AppKit views,
`TESSEL_CAPTURE_CAROUSEL=1` for E21 geometry recordings, or
`TESSEL_CAPTURE_LAYER=1` for layer recordings and owner-session preparation. Select a suite or pass a test
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

The harness owns the Reduce Motion Given rather than inheriting the desktop's
setting; GitHub's macOS images turn Reduce Motion on, which made every carousel
move instant on CI. Each launch passes tessel `-reduceMotion NO`, or `YES` where
a journey asks for it. That argument domain precedes the user's preference in
tessel's process only. macOS protects the persistent preference, and the private
setter the Reduce Motion contract uses changes only the observer's own process,
so nothing desktop-wide changes and neither cleanup nor an interrupted run has
anything to restore. A launch waits until `status --json` reports whether
motion is off for Reduce Motion as the harness asked. Each suite that launches the app prints a `Motion:` line
with the effective and configured durations and both Reduce Motion values, read
in a fresh signed observer when the suite starts; E15 and E24 failures repeat
it. The Reduce Motion journey checks the other value natively: a configured
400 ms carousel move captures and shows nothing.

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
E36's twenty windows across ten workspaces, and carousel E24's twenty windows
across five workspaces and multiple rails, plus one hidden float with the layer
experiment enabled (also #19 E28). The two IDs share one resource test and the
same budgets and observation window. Each retains its setup and one-second
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

CI runs on `xcode-27` (macOS 27) and must finish in under ten minutes per pull
request, until every check is green. The Policy job runs bare tests, the layer
check and trace repetition. The simulator-evidence guard runs in its own
workflow; it is the only check that reads the pull request description, so it
is the only one an edit to the description reruns. The
Acceptance job signs and builds once, then runs contracts, journeys (including
permission denial/restart), latency, resources and the rails status-item capture.
Resources have a 200 s command budget: the stage's E24 put the suite at
91 s on `xcode-27`, past the former 90 s, and the owner raised it. The job has a twelve-minute timeout
for these suites, three optimized builds (the signed bundles, the signed-rebuild
journey and the daily-variant argument check) and runner setup. The carousel's
contracts, E15, E24 and larger compiles put a green run near nine and a half
minutes on `xcode-27`, so ten minutes no longer left margin for a slower runner.
`scripts/verify` checks the test selection once; its Interactive launchd job
does not repeat that check.
Latency samples and the app-rendered rails capture are uploaded even on failure.

The runner first hides the Dock: fixture Dock icons can move the visible frame's
bottom edge by two points on its 1024×768 display. It creates a short-lived
certificate in a temporary keychain, removed at the end; no signing material is
stored in GitHub. Before any harness suite, `scripts/ci-accessibility` grants the
development app and fixture Accessibility and Screen Recording on that disposable
runner, and records their screen-capture approval so macOS does not interrupt the
first capture with an alert that takes focus. Only `CI=true`
together with `GITHUB_ACTIONS=true` enables
Accessibility denial and restart steps. Local runs use the signed development
bundle's existing permissions and never provision the TCC database.

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
`state` is `tiled`, `floats`, `minimized`, `hidden`, `fullscreen`, or `ignored`.
Ignored surfaces have no workspace and are never placed, hidden or focused.
Titles are never queried. `status --json` adds
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

## Carousel experiment (#26)

`[experiments] carousel = true` enables the carousel layout independently of
`workspaces`. The former `rails` key is unknown and reports its line number.
Without carousel, the workspace experiment keeps its one-window layout and
shortcuts. With both experiments absent, tessel only observes.

Each workspace owns a stack of rails (rows). Existing windows enter one rail in
arrival order, retaining their observed widths; an exact preset is recognized.
New windows enter at half width immediately right of the focused tile, receive
focus, and are revealed with the smallest scroll. Presets are one third, one
half, two thirds and full width, measured as `p * (area.width + outer) - outer`.
The area is the primary display's visible frame inset by the outer gap.

Option+R (`cycle width`) chooses the next preset, keeping the tile's left edge
still unless a minimal scroll is needed to show it completely. AX readback
learns rejected minimum and maximum widths; later cycles skip them. Mouse
widths remain exact until cycling. A rail shorter than the area stretches its
windows proportionally; the stretch preserves nominal widths.
Height-constrained windows stay tiled at the top, with an explanatory reason.

Option+H/L (`focus left|right`) first selects the nearest complete window in
that direction. Otherwise it advances one stop: a window edge meeting the
same side of the area, clamped to the strip's ends. Focus waits for a complete
window. At an end, another press bounces: no window changes width or position.
Navigation and swaps never wrap.

Option+K/J (`focus up|down`) selects the adjacent rail. Each rail remembers its
stop and focus. Option+Shift+H/L (`move left|right`) swaps neighboring
tiles and keeps focus. Option+Shift+K/J (`move up|down`) inserts after the
remembered tile of the adjacent rail, creating a rail beyond an end unless the
moving tile is already alone there. Empty rails disappear.

Closing focus selects the left neighbor, or the right if it was first. An empty
rail selects the rail below, or the one above if it was last. Minimize/hide
retains the workspace experiment's most-recent-focus policy. Restoring a tile
uses its former rail and left neighbor when available. Native-tab replacement
retains tile identity, nominal width, learned limits and focus. Dialogs keep
their frames, sheets follow their parents, and native fullscreen stays outside
workspace management. Workspace switching and sends remain instant.

Numeric workspace/send shortcuts retain their meanings. `focus next|previous`
are bindable aliases for horizontal traversal. `[keys]` overrides merge with
defaults; an empty string disables a binding. Directional and width commands
are validated with the experiment off, but registered only when it is active.

```toml
[experiments]
carousel = true

[animation]
duration = 80

[keys]
alt-r = "cycle width"
```

`duration` accepts TOML integers from 0 through 1000 and defaults to 250 ms.
`status --json` reports `workspaces.layout: "carousel"`, `animationDuration`
(the effective duration, zero when motion is off), `motion` (`"on"`, or
`"off: "` and why: duration 0, Reduce Motion or a missing Screen Recording
grant), the nullable one-based `rail` and `railCount`. `windows --json` includes nullable one-based `rail` and `slot`.
The status item shows the workspace number and one bar per rail.

Animated layout changes run on the stage
([ADR 0006](adr/0006-move-carousel-windows-through-captures-on-a-stage.md)).
`MotionStagePort` captures windows with ScreenCaptureKit, sized from their live
bounds, and animates them with Core Animation in a click-through overlay at
floating level, below the menu bar. The policy:

1. Requests focus, and captures every seen window and what lies under the
   area at once.
2. Shows each seen window's capture where the window is: its observed frame
   on screen, its unclamped strip position when parked or closeted. The stage
   reports it shown once WindowServer has drawn it.
3. Moves the stand-ins to the layout, and runs the ordinary instant presenter
   underneath. The presenter closets, shows, positions, sizes and focuses each
   real window once.
4. Once the stand-ins have settled and every placement is confirmed, asks the
   stage to reveal the accepted frames; the stage waits until WindowServer
   lists them, fades into them, and the policy clears it. In any case it
   clears 300 ms after settling.

Further commands retarget the stand-ins from where they are on screen, keeping
their speed, and cancel the earlier settle, reveal and linger. A window first
seen by a retarget is captured then and joins at its start. A command while a
wall bounce prepares replaces the bounce. A window that closes loses its
stand-in. A
resize crossfades the stand-in to a new capture once the app accepts the
size. An accepted size the app chose is learned as before and retargets the
strip. A rail change slides the leaving and entering rails as one sheet, one
rail height apart. A wall bounce moves the stand-ins away from the wall and
back, 70 ms each way, and moves no real window.

A pointer press, native fullscreen entry, disabling the experiment and a
layout change clear the stage at once; the pointer case keeps the user's
geometry. A failed capture clears it and places the windows at once. A
placement that supersedes an unconfirmed focus request carries that focus
forward. A window focused while still in the closet can lose key when AppKit
finishes the app's activation after AXMain and AXRaise: the app's previous key
window becomes key again. The app's worker selects the requested window once
more when that activation arrives, within 1 s of the request, so the rail does
not follow the previous window back. A native selection reported during the motion is still followed: the
placement that carries out the motion does not invalidate external focus
decisions. A command that arrives while such a decision waits its 50 ms first
follows the selection, so it acts on the window the user just chose. The stage
answers `available` from its last Screen Recording preflight, which takes about
10 ms, and refreshes it off the main thread. Workspace switches and sends stay instant, and so does every
change when motion is off. No capture or timer remains at rest; the overlay
stays ordered in, empty and transparent, so the next show draws at once.

Fixture-only development status adds `testMotion.stageCaptures` and
`testMotion.stageShows`. The app's real stage adapter increments them, and the
signed development CLI preserves them. The resource suite samples them only
outside its measured idle window. Daily builds contain neither the counters
nor this status field.

A manually moved tile stays where released until the next layout change. A
busy AX presentation retries after 100, 200, 400 and 800 ms unless superseded.
Completely off-screen tiles live in the closet; they are shown before sizing.
Disabling the experiment or quitting returns managed windows inside the desktop.
Crash recovery uses the same closet boundary without persisted membership.

### Native motion contracts and E21 capture

[ADR 0005](adr/0005-animate-tiled-windows-through-accessibility.md) records the
native AX facts that placement relies on, and
[ADR 0006](adr/0006-move-carousel-windows-through-captures-on-a-stage.md) why
motion runs on a stage. The signed contracts in `ContractsMotion.swift` pin:

- vertical menu-bar/32-point clamps;
- horizontal one-point edges and 40-point snapback;
- AXMain/AXRaise across apps;
- retained closet handles and lossy hidden size writes;
- resize anchoring at the current x;
- Reduce Motion notifications;
- pointer-down delivery.

`ContractsStage.swift` pins:

- the Screen Recording preflight;
- whole-window captures on screen, as a sliver and in the closet, without
  moving or activating the window;
- a click-through floating overlay listed above windows and below the menu bar
  that reads back drawn from its own window within the stage's 150 ms wait;
- AX sizes bounded by the current x and by the current top against the screen
  bottom, so a window moves before it grows.

Listed is not drawn. On the owner's Mac, WindowServer drew the overlay within a
frame of its commit about half the time and 40–65 ms later otherwise, whatever
its content, mostly while another app redrew busily. The stage therefore reads
one point of its own window, which needs no Screen Recording and leaves the
recording indicator alone, and places the real windows only once the overlay
is drawn, waiting at most 150 ms. Likewise, Accessibility accepts a placement
before WindowServer moves the window, so the stage clears only once
WindowServer lists every placed window at its accepted frame and every
closeted one off screen, then fades into them over 40 ms.

The stage contracts need Screen Recording granted to the signed fixture
observer; without it they fail and say so.
ScreenCaptureKit can also show a separate capture acknowledgement even with
that grant. See [Screen capture permission diagnosis](screen-capture-permissions.md)
for the evidence, the remaining consent decision and the bounded confirmation
commands. A preflight alone does not settle that acknowledgement.
The Reduce Motion contract changes the preference through HIServices' private
setter, which affects only the observer's own process: it pins how NSWorkspace
reads and announces the interface preference, not a desktop-wide change.
A window ID lookup on a notified element can fail mid-fullscreen with
cannotComplete. The observer records that error and attributes the element by
AX equality instead, as the catalog does during motion: `ax-notifications`
requires the handle it registered, and other contracts accept a retained window
handle equal to the notified element (such as the auxiliary fullscreen root
that `transient-window-lists` watches at application level).
The timeout contract also proves that configuring AX messaging timeouts is local
client state, even while the target app is stopped; it consumes no simulated
remote-delivery time. The simulator declares the corresponding assumption IDs;
these native facts must be verified before changing its behavior.

E15 now checks a mixed-app rail change by its landing: focus, both rails, and
only the two fixture apps activating. When motion is on, it also checks that
the stage captured and showed. Its observer uses fixture-owned WindowServer
bounds. The primary-screen contract exercises that display sampler while its
fixture is stopped: geometry must remain valid without an AX reply. Native
focus is read before geometry and CG order afterward, so a slow focus answer
cannot pair earlier frames with later stacking. Missing CG metadata still
falls back to AX; an unanswered read remains invalid.

The display link runs on the observer's own sampler thread, never on the main
thread that serves observation commands. A full observation waits on AX replies
from busy fixtures, and such commands have held the main thread for over
300 ms. E15 drains the samples while it waits.
The busy frontmost app answers the sampler's focused-application read, so that
read uses the 20 ms focused-only bound; an unanswered read reports zero.

E21's recording predates the stage. It samples WindowServer bounds of the real
windows, which now move once under the stage, so it no longer shows the motion
the owner sees. It needs a pixel recording of the overlay before it can be
reviewed again. Until then it records the E1, E3, E7, E10 and E14 journeys at
both 80 and 400 ms with:

```sh
TESSEL_CAPTURE_CAROUSEL=1 scripts/verify captureCarouselMotionForOwnerReview
```

The independent signed observer samples each fixture's WindowServer rectangle
and CG order on delivered display callbacks, plus answered AX focus. It validates
fixture identities and discovers the E10 arrival through fixture-owned CG IDs.
The primary-screen contract pins CG bounds against accepted AX geometry, even
while the fixture is stopped. Missing CG descriptions use short AX reads. No Screen
Recording, screenshots, real titles or app contents are captured. Every sample
carries its display timestamp and raw-clock start/end around the reads;
callback gaps and read spans remain visible. Batches drain within the bounded
socket buffer and the capture requires a complete callback sequence.

Outputs are ignored `.build/captures/carousel/carousel-motion.json` and
`.build/captures/carousel/index.html`. The self-contained HTML replays measured
rectangles with invented numbered titles, provides frame stepping, a geometry
timeline and filmstrips, and holds samples without interpolation. The fixed
recording window includes bounce and a settled tail; final states use the usual
5 s margin. Only latency judges speed. Copy the HTML and JSON to the owner's
review destination when requested. E21 remains pending until the owner compares
it with the accepted prototype; generating the recording does not accept it.

## Floating layer experiment (#19)

`[experiments] layer = true` enables the carousel and a floating layer for each
workspace. Existing floats start hidden in the closet while the rail keeps
focus. If startup focus is already on a float, tessel enters the whole layer.
The layer's visibility and pinning belong to its workspace; switching away
hides all its windows and returning restores its selection.

Option+Z (`toggle layer`) shows the workspace's floats and selects the most
recently used one, or the first arrival before any has been used. Pressing it
again returns to the remembered rail tile and hides the layer. Tiles retain
their geometry and scroll position. Inside the layer, Option+H/K cycles backward
and Option+L/J forward in arrival order, wrapping at either end. Option+R and
Option+Shift+H/J/K/L do nothing there.

Option+Shift+Z (`pin layer`) keeps the floats visible above the rails while rail
navigation continues. Option+Z still enters and leaves the layer. Unpinning on
the rails hides it; unpinning inside leaves it shown. During rail motion, the
stage captures each visible pinned float once, excludes it from the background,
and draws it above the moving tiles. No layer animation, polling or recurring
timer is added.

A new float takes focus and, when the layer was hidden, appears alone. Another
new float replaces that single view. Closing it or pressing Option+Z returns to
the rails; directional navigation expands to the whole layer, and pinning shows
it all while retaining float focus. In an entered layer, closing focus selects
the surviving most recently used float; the final close returns to the rails.
Sheets stay with their parent and do not enter the layer independently. External
focus on a hidden float enters the whole layer; external tile focus leaves it,
hiding floats unless pinned. Focus moves away before a float enters the closet.
A hidden modal can leave its app waiting until the dialog is shown again.

Option+F (`toggle float`) moves a tile to the layer, centered at half the area's
width and two thirds its height. It becomes the newest float arrival, and the
rail closes its gap and remembers the left neighbor. Moving a resizable float
back inserts it to the right of the remembered tile, creating a rail if needed.
Its current width selects the nearest rail preset; a tie chooses the wider one.
A fixed-size float bounces and stays floating. Manual choices last for that
window's lifetime, including catalog refreshes, and reset on restart. Sending a
float with Option+Shift+N follows it into the destination workspace's layer.

The three commands are accepted and rebindable in `[keys]` even with the flag
off, but are registered only while the layer is enabled. Toggling an empty layer
does nothing. Disabling a layer-only config, removing it, or quitting returns
all floats. With `carousel = true` explicitly retained and `layer = false`,
active-workspace floats remain visible above the rails and inactive workspaces
stay in their closet, as in the carousel experiment. Enabling the layer again
starts hidden.

With the layer enabled, `status --json` adds
`workspaces.layer: {"state":"hidden","focused":false}`. State is `hidden`,
`single`, `shown`, or `pinned`; `focused` says whether focus is in the layer.
Hidden floats retain `state: "floats"`, workspace membership, null `rail` and
`slot`, and `visible: false` in `windows --json`. Manual classifications report
`floats` / `moved to the layer` or `tiled` / `moved to a rail`.

Classification is fixed independently of the flag: tessel manages windows at CG
layer 0 or the floating level 3 with subrole `AXStandardWindow`, `AXDialog`,
`AXSystemDialog`, or `AXFloatingWindow`. Layer 3 includes apps' own floating
utility panels, inspectors and palettes. Every other layer is `ignored` with
reason `window level <n>`, checked before the subrole. Other subroles are
`ignored` with that subrole as the reason. Ignored records have null `workspace`,
`rail` and `slot`; their
appearance or removal changes neither focus history nor layouts. Native
fullscreen remains detected through `AXFullScreen`, including a transient
`AXUnknown` fullscreen root. The catalog reads CG levels only for the IDs it
inspects, alongside their other facts.

## Journeys and latency (#24)

`scripts/verify --journeys` runs eleven journeys. The signing-and-permission
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
| Enable | #1 E9; #2 E1 |
| Switch | #2 E31, E32 |
| Send | #2 E35 |
| Rail scroll and elevator | Wiring regression (no policy example IDs) |
| Carousel rail change | #26 E15 |
| Floating layer | #19 E29 |
| Reduce Motion | Wiring check that Reduce Motion makes a carousel move instant (E18 belongs to P) |
| Reload | File watcher wiring for save, atomic replace, chmod and delete |
| Crash, quit and disable | #2 E28, E29, E34 |
| CLI and config files | #1 E10, E12; #1 U-cli-args, U-private-transport, U-read-only-transport, U-stalled-clients, U-observer-identity, U-cpu-oracle, U-notification-retries |
| Signing and permission | #1 E13, E15, E16 |

Latency owns #2 U-switch-budget in `Tests/Acceptance/Latency.swift`.
It records 100 workspace switches and 100 rail moves (50 scrolls and 50 elevator
trips between apps). Four half-width windows traverse the complete pairs
[1|2] → [2|3] → [3|4], then back, without wrapping. Crossing an already complete
pair to select its outward tile is setup outside the measured scroll. The
second rail contains a full-area singleton in another app. Every measured
scroll advances a stop; every elevator changes apps.
Each sample starts at the trusted fixture's real key `postedAt` and ends at the
independent observer's `sampledAt` when destination frames, focus and CG
visibility all match. Full observations read focus and CG visibility after AX
geometry, so moving frames are not paired with an earlier preparation state. Samples must finish within the final-state margin.
Only this suite judges elapsed time. Both workspace and carousel nearest-rank
p95 remain at most 200 ms. The carousel latency suite explicitly configures
`[animation] duration = 0`; E16/E17 independently prove the stage's timing
against the simulator's clock at the policy boundary. This preserves the existing
CI processing/observation budget without adding intentional display waiting.
A local-only proposal to raise the animated total to 280 ms was withdrawn:
recalibration requires evidence of its spread on CI's runner. Sample counts,
percentiles, final-state predicates and resource limits remain unchanged.
Timing ends at
observed final WindowServer geometry, AX main/focus and CG visibility, including
native completion and observation overhead. The signed primary-screen contract
pins CG window bounds against accepted AX geometry, including the one-point
edge and a stopped fixture. Rail samples read those bounds, then a focused-only
AX/CG observation; its `sampledAt` dates the latest input. This avoids repeated
AX reads of hidden windows and unrelated controls while measuring final geometry. The deterministic E17
bound covers the stage's landing after the last command; it does not claim
when a slow app finishes its own placement.
It prints p50, p95 and maximum, and writes `.work/latency.json` (schema 2) with
the samples, counts, percentiles, configured animation duration, completion
definition and nonpersonal run metadata. CI uploads that artifact even on failure; incomplete runs retain their partial counts and the
failed sample index. No window listings or titles reach the artifact.

## Acceptance example layers (#24)

This table is the maintained example-to-layer map for issues #1, #2, #19 and #26.
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
| #19 E1 | P |
| #19 E2 | P |
| #19 E3 | P |
| #19 E4 | P |
| #19 E5 | P |
| #19 E6 | P |
| #19 E7 | P |
| #19 E8 | P |
| #19 E9 | P |
| #19 E10 | P |
| #19 E11 | X |
| #19 E12 | P |
| #19 E13 | P |
| #19 E14 | P |
| #19 E15 | P |
| #19 E16 | P |
| #19 E17 | P |
| #19 E18 | P |
| #19 E19 | P |
| #19 E20 | P |
| #19 E21 | P |
| #19 E22 | P |
| #19 E23 | P |
| #19 E24 | P |
| #19 E25 | P |
| #19 E26 | P |
| #19 E27 | P |
| #19 E28 | R |
| #19 E29 | J |
| #19 E30 | X |
| #19 E31 | P |
| #19 E32 | X |
| #26 E1 | P |
| #26 E2 | P |
| #26 E3 | P |
| #26 E4 | P |
| #26 E5 | P |
| #26 E6 | P |
| #26 E7 | P |
| #26 E8 | P |
| #26 E9 | P |
| #26 E10 | P |
| #26 E11 | P |
| #26 E12 | P |
| #26 E13 | P |
| #26 E14 | P |
| #26 E15 | J |
| #26 E16 | P |
| #26 E17 | P |
| #26 E18 | P |
| #26 E19 | P |
| #26 E20 | P |
| #26 E21 | X |
| #26 E22 | P |
| #26 E23 | P |
| #26 E24 | R |
| #26 E25 | P |

E21 has an opt-in executable capture in `CapturesCarousel.swift`; it needs a
pixel recording of the stage before the owner can review it again. All mapped
rows have executable coverage. E15 owns J: the native mixed-app landing and
activation assertions. E14 and E16 own P; their untagged journey steps check
wiring.

All deterministic carousel examples run directly against the simulated stage:
rail slides, captures, placement under the stage, retargets, interrupts,
Reduce Motion, a missing Screen Recording grant, closet timing and bounce.
Retained membership and AX-retry scenarios use duration zero; CarouselMotion
proves the animated path. E4's command matrix checks settled invariants at
duration zero, while E16 checks the stage at 80 and 250 ms.


## Deterministic checks (#24)

Run these commands from the repository root. They use SwiftPM tooling only;
they do not launch the app or fixtures. Child test processes remove
`TESSEL_ACCEPTANCE` and the purity-test override from their environment.

```sh
swift test
swift run tessel-check layers
swift run tessel-check determinism --runs 20
swift run tessel-check simulator-evidence --base origin/main --body-file pr-body.txt
```

`layers` lists tests without entering their execution scopes, and rejects
Acceptance compilation or discovery. `determinism` requires successful runs and one identical SHA-256
`trace digest:` line per run, printing the digest and each run's time.
`simulator-evidence` checks `<base>...HEAD`: a change under `Tests/Simulator/`
needs either a changed `Tests/Acceptance/Contracts*.swift` file or a PR-body
line starting exactly `Simulator-evidence:` with non-empty text after it.
CI passes the body through an environment variable into a file, then runs
the guard; it never treats the body as shell source.
