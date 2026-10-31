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
(`CLOCK_MONOTONIC_RAW`, the clock `clock_gettime_nsec_np` reads) when Tessel
read the state it reports. `status --json` has it at the top level, and each
`windows --json` record repeats it. Text output is unchanged.

Development uses `com.taecontrol.tessel.dev`; `scripts/build --variant daily`
uses `com.taecontrol.tessel`. Keep the signing identity stable across rebuilds.
Never launch an unsigned or ad-hoc-signed bundle with either ID. Doing so can
revoke the existing Accessibility grant. Bundles must stay outside `/tmp`,
where LaunchServices cannot register them reliably.

The development build never reads or changes login items, including in the
fixture harness, and has no **Open at Login** menu item. The daily build registers
on its first launch from `/Applications` or `~/Applications`, even without the
Accessibility permission. Turn it off with **Open at Login** in the menu bar;
later launches preserve that choice. An off in System Settings shows
**Open at Login…**, which opens Login Items so the user can turn it back on.
A daily copy outside Applications has a disabled item explaining where to move
it and never reads or changes login items.

`status --json` includes `openAtLogin` with `state` (`enabled`, `off`,
`offInSettings` or `unavailable`) and `reason` (a string or null). Text status
includes `Open at login: on`, `off`, `off in System Settings` or
`unavailable (<reason>)`. A refused change keeps the state macOS reports and
shows `macOS refused: <message>` in the menu and JSON reason until the state
changes. Login-item state is read only at launch, when the menu opens, after a
click and for each status request; no timer or background polling reads it.
This lifecycle default has no experiment flag, as explicitly agreed in
[issue #55](https://github.com/taecontrol/tessel/issues/55).

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
Tessel's own delays; enumerated schedules expose races without depending on
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
other Tessel instance managing windows. Use an awake, unlocked desktop:

```sh
scripts/build
scripts/verify --contracts
scripts/verify --journeys
scripts/verify --latency
scripts/verify --resources
```

With no arguments, `scripts/verify` runs every real-system suite except the
disposable-runner permission steps. Before the first suite, it runs
`scripts/build --if-needed`: a content manifest checks app, CLI, fixture and
build-tool sources, compiler, signing settings and installed bundle bytes.
Any mismatch rebuilds the signed bundles; unchanged inputs avoid compilation.
Plain `scripts/build` still forces a rebuild for the permission journey.
`--journeys` includes those steps on CI;
`--permission` selects just those steps. The signing-and-permission journey has
separate signing and permission tests so the default can skip only the latter. Captures
run only with their opt-in flag: `TESSEL_CAPTURE_WORKSPACES=1` for AppKit views,
`TESSEL_CAPTURE_CAROUSEL=1` for E21 geometry recordings, or
`TESSEL_CAPTURE_INSTANT=1` for #33's fixture-only 120 Hz pixel recordings, or
`TESSEL_CAPTURE_LAYER=1` for layer recordings, the automated E30 fidelity
walkthrough and E32 owner-session preparation, or `TESSEL_CAPTURE_ARRIVAL_WIDTH=1`
for #49 E15's standard and maximum-width arrival geometry, or `TESSEL_CAPTURE_MAP=1`
for #18 E28's light and dark map views. Select a suite or pass a test
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
Tessel is observed through its bundled CLI. The harness cleans up its own
processes and data. It always passes `--test-fixture-only`, so only fixture
processes are observed or managed, including crash recovery. The daily build
rejects that argument. Another Tessel instance can contaminate these fixtures.

The harness owns the Reduce Motion Given rather than inheriting the desktop's
setting; GitHub's macOS images turn Reduce Motion on, which made every carousel
move instant on CI. Each launch passes Tessel `-reduceMotion NO`, or `YES` where
a journey asks for it. That argument domain precedes the user's preference in
Tessel's process only. macOS protects the persistent preference, and the private
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

Application launch and termination come only from KVO on
`NSWorkspace.runningApplications`, including accessory apps that never activate.
The main-thread adapter diffs the previous and current complete PID sets,
independent of KVO change kind, so an array replacement preserves surviving
apps. It does not replay the initial list: the catalog already enumerates it
at startup and settles early AX reads. Activation, hide and unhide retain their
NSWorkspace notifications; prohibited apps retain the catalog's metadata guard.

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
not turn an earlier observer sample into Tessel latency (issue #21). The script
prints its scheduling priority and relaunches a clamped process tree as an
`Interactive` launchd job in the user's GUI session, forwarding environment,
output and exit status. Priority below 31 indicates a utility/background clamp
that child QoS changes cannot lift. Interrupting verification removes the job.

### Resources

`Resources.swift` keeps foundation E22's twenty default-config windows, workspace
E36's twenty windows across ten workspaces, and carousel E24's twenty windows
across five workspaces and multiple rails, plus one hidden float in the layer (also #19 E28). The two IDs share one resource test and the
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

Never use `lsappinfo send` (or `setinfo`) to generate LaunchServices traffic.
On macOS 27, broadcasting `kLSNotifyApplicationTypeChanged` with no target
application restarted WindowServer and loginwindow, which ended the GUI session
and killed every app in it. To study LaunchServices load, observe passively and
let real app switches produce the traffic.

### CI

Pull requests run Policy (bare `swift test`, `tessel-check layers`, and
`determinism --runs 3`), Simulator evidence, and Permissions. Policy has a fifteen
minute timeout ([ADR 0010](adr/0010-give-the-policy-job-fifteen-minutes.md)), the evidence job five, and Permissions seven. Permissions signs
and builds once, then selects only `signingAndPermission` and `--permission`:
signed rebuild, denied Accessibility and permission recovery/restart. Its seven
minute limit leaves margin over the measured 99 s build, 50 s signing journey
and 3 s permission steps. There are no scheduled or diagnostic CI runs.

Contracts, ordinary journeys, latency and resources run locally. A change under
`Sources/`, `Tests/Acceptance/`, `Tests/Fixture/`, `Tools/Build/` or `scripts/`
requires this block in the PR description, with the exact PR head SHA:

```tessel-verification
head: <40-character head SHA>
suites: contracts journeys latency resources
```

A successful no-argument `scripts/verify` prints the block only if the checkout
is clean and HEAD has not changed during the run. A subset run never prints it.
An edit to the description reruns both evidence guards. Documentation and
simulator-only changes require no new real-system verification. Simulator
changes still require a changed contract or `Simulator-evidence:` explanation.
The existing 200 ms p95, wakeup, CPU and footprint budgets are unchanged; the
resource suite has no elapsed-time budget. See
[ADR 0008](adr/0008-gate-real-system-changes-on-local-evidence.md).

Only `CI=true` together with `GITHUB_ACTIONS=true` enables Accessibility denial
and restart steps. The runner creates an ephemeral signing identity and grants
the signed harness permissions on its disposable desktop. Local runs retain
the owner's signing identity and never provision the TCC database.

## Configuration and observation

The config is `$XDG_CONFIG_HOME/tessel/tessel.toml`, defaulting to
`~/.config/tessel/tessel.toml`. An absent or empty file uses the carousel,
workspaces and floating layer with their normal shortcuts. The kept experiments
have no flags. Legacy `workspaces`, `carousel` and `layer` booleans in
`[experiments]` are accepted and ignored; unknown keys still report their line.
`[experiments] map = true` enables the rails map experiment (off by default).
`[map] duration` is its fully visible time after the last effective key, an
integer from 100 to 5000 ms (default 1000). It is accepted without the flag and
reported in `config.effective.map.duration`. A change applies to the next key;
invalid edits keep the last valid configuration. Other map keys are rejected.

```toml
[gaps]
outer = 10

[animation]
duration = 250

[experiments]
map = true

[map]
duration = 1000

[keys]
alt-r = "cycle width"
alt-tab = "focus recent"
```

Unknown keys and invalid TOML preserve the last valid configuration. Saving,
replacing or deleting a file reloads automatically. Status reports the effective
configuration, revision, source state and error. `[keys]` overrides merge with
the layer defaults; an empty command disables a binding. Keys use lowercase ANSI
letters, digits and `tab` with `alt`, `shift`, `ctrl` and `cmd` modifiers. Numeric
workspace/send bindings cover 1…10, using 0 for 10. Directional traversal never
wraps on a rail; `focus next|previous` remain bindable horizontal aliases.

`alt-tab` defaults to `focus recent`, which selects the most recently selected
available window other than the current selection, across workspaces and
including floats. Sheets and child dialogs count as their root window.
Minimized, hidden and native fullscreen windows are skipped. Only windows
selected since launch enter the history; without another available window in
that history, the command does nothing. Changes within a workspace animate like
directional focus; workspace switches are instant. This command needs no
experiment flag.

The primary display is managed; Stage Manager and other displays remain outside
this scope. Inactive windows live in the SkyLight closet. Quitting returns
managed windows, and startup recovers orphans after the first successful AX
snapshot. Native fullscreen is never closeted. Missing Accessibility or hiding
mechanics disable management with an explicit reason. Titles are never queried.

Window JSON includes ID, app, bundle ID, classification and reason, tab count,
workspace, visibility, rail, slot and `answeredAt`. Ignored surfaces have no
membership and are never placed, hidden or focused. Status includes the active
workspace, carousel layout, rail counts, gaps, effective keys, motion and layer.

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

## Rails map (#18)

With the experiment enabled, effective keys and wall hits show a small map of
the active workspace. External changes refresh a shown map without extending
its hold. Motion follows animation duration and Reduce Motion, independently
of Screen Recording. The panel passes clicks through, takes no focus, joins all
Spaces and orders out after its 120 ms fade (instantly with motion off).

Bare `swift test` proves E1–E23 through the recording port and pure layout.
The signed `mapOverlayPreservesFocusAndPassesClicks` contract proves E24;
`carouselKeyShowsAndRetiresMap` proves E25. Resources and latency run their
existing carousel scenarios with the map enabled for E26–E27. Fixture-only
development status exposes `testMap`; public status does not.

```sh
TESSEL_CAPTURE_MAP=1 scripts/verify captureRailsMap
```

This opt-in E28 capture adds `--test-capture-ui` to the signed fixture-only
app. It exports the app's own map view in light and dark for Long rail,
Three rails, Floats visible, Crowded, a wall with motion off and a workspace
switch. Images go to `.work/captures/rails-map` for owner review; no desktop
pixels are exported. The capture facility is absent from the daily build.
Before copying images, the capture checks the real adapter's rendered tile
counts per rail and every fixture's intended workspace, rail and slot. A wrong
setup fails with fixture-only details instead of exporting it for review.

## Carousel (#26)

Each workspace owns a stack of rails (rows). Existing windows enter one rail in
ID order, independent of which app finishes its first AX enumeration, retaining their observed widths; an exact preset is recognized.
New windows enter at full width immediately right of the focused tile, receive
focus, and are revealed with the smallest scroll (#49). An app that rejects
full width keeps the exact width it accepted on arrival. Presets are one third, one
half, two thirds and full width, measured as `p * (area.width + outer) - outer`.
The area is the primary display's visible frame inset by the outer gap.

Option+R (`cycle width`) chooses the next preset, keeping the tile's left edge
still unless a minimal scroll is needed to show it completely. AX readback
learns rejected minimum and maximum widths; later cycles skip them. Mouse
widths remain exact until cycling. Short rails keep their nominal widths and
align to the left, leaving empty space to the right.
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
retains the workspace's most-recent-focus policy. Restoring a tile
uses its former rail and left neighbor when available. Native-tab replacement
retains tile identity, nominal width, learned limits and focus. Dialogs keep
their frames, sheets follow their parents, and native fullscreen stays outside
workspace management. Workspace switching and sends remain instant.

Numeric workspace/send shortcuts retain their meanings. `focus next|previous`
are bindable aliases for horizontal traversal. `[keys]` overrides merge with
defaults; an empty string disables a binding. Directional and width commands
are always available with their layer defaults.

```toml
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

A pointer press or native fullscreen entry clears the stage at once. Duration
zero and Reduce Motion also clear an animation already in flight and place its
final layout immediately. Duration zero never queries Screen Recording. A failed
or unreadable capture clears it and places the windows at once, including a
window first captured by a retarget after the stage has shown. The stage reports
a final drawn-window capture failure to policy, which renders the current focus
instantly. An unreadable window capture is attempted once per move; nothing
remembers it between moves. An unreadable background prevents the stage from
showing, and an unreadable resize refresh keeps the previous capture. A screenshot
that has not returned after 1 s also makes the move instant. A window that WindowServer
lists off screen outside the closet is ordering out or hidden: the stage never
captures it and shows no stand-in for it
([ADR 0007](adr/0007-capture-only-windows-that-are-drawn.md)). A
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

SIGTERM, the Quit menu and permission relaunch clear the stage at once, then
drain outstanding ScreenCaptureKit requests for at most 500 ms before asking
AppKit to terminate. Cleanup then returns managed windows and exits. Exiting
during a capture can leave replayd checking a dead client's audit token
and showing an approval alert. The capture-settled callback or one-shot deadline,
whichever arrives first, completes the drain exactly once; repeated quit requests
do not extend it or repeat cleanup. The limit leaves margin over normal
15–100 ms captures and the measured 230 ms cold start, without letting a stuck
capture block quit.
It bounds capture draining before cleanup, excluding window-return work.

`applicationShouldTerminate` always returns `terminateNow`, including for
external requests such as logout. Draining inside AppKit's `terminateLater`
wait can hang: when SIGTERM calls terminate from the main dispatch queue, the
nested modal loop cannot reenter that queue to deliver capture continuations
or its dispatch deadline. Deterministic CarouselShutdown scenarios prove drain
ordering, the deadline and exactly-once completion; they do not model AppKit's
termination loop. Real-system journeys exercise SIGTERM teardown after each
test and must confirm process exit.

Fixture-only development status adds `testMotion.stageCaptures` and
`testMotion.stageShows`, plus `stageSettles` and `stageClears` to distinguish
normal completion from an instant fallback. `stageMove` identifies the current
or last staged move; `stageScreenshots` counts screenshot requests by window ID
within that move, including failures and resize refreshes. `stageCapturesPending`
counts outstanding native capture work, including work from a cleared move.
The app's real stage adapter updates them, and the signed development CLI
preserves them. The resource suite samples its work counters only
outside its measured idle window. Daily builds contain neither the counters
nor this status field.

While a pointer button is held, no geometry, focus, main, raise or capture work
runs. Mouse-up reads fresh frames, adopts the accepted width and released left
edge, and restores rail height once while moving neighbors. Left alignment wins
if the first tile would leave a leading gap. An accepted width beyond a learned
limit releases that obsolete limit. Commands arriving during the release read
are carried forward rather than lost.

A pointer move stays where the user released it until the next layout change.
An app's or macOS's move of a rail tile is placed back instantly at Tessel's
last accepted readback, or the pointer's drop point. Only tiles with their
entire layout target on screen are watched, outside gestures and resizes and
without a write of Tessel's in flight for that tile. Two corrections are
allowed; a third move concedes until a layout placement or pointer drag resets
the allowance. An unchanged click preserves other tiles' allowances.
Correction retries keep their count; an unfinished layout placement remains
a layout placement on retry, even if its write succeeded before its readback
failed. That reason also survives the placement queue and a superseding render.
A late completion of a superseded write cannot replace its retry's readback.
At rest a correction uses no stage or captures; during motion it retargets the
existing stage. Repairs preserve pending keyboard and native focus decisions.

Instant presentation computes one layout. It prepares returning windows while
hidden, shows them when WindowServer confirms their accepted frames, places
visible windows, transfers focus only to a shown destination, then hides
departing windows once their covering replacements are in place and confirmed.
The oracle judges the app-committed view WindowServer lists, separately from
AX acceptance (#33 E18). External changes expose what they would at rest; their
exposure ends at the first recheck after the app commits the placements of the
render their snapshot triggers. AX writes temporarily disable an app's enhanced
UI flag and restore its value. No stage or capture is involved. Busy writes
retain their bounded retries.

A replacement is **in place** when Tessel has no write of its own
outstanding for it, and its last observed frame is within one point of its
target on each of x, y, width and height. The presenter uses the same
tolerance to decide that a window needs no placement, so a tile it leaves
alone is never waiting for a placement that will not come. A scheduled window
is judged only when its own placement ends, because its cached frame can
predate an earlier write of Tessel's that has not been confirmed; such a write
stays pending until a readback succeeds, so the next render schedules the
window again. A placement that returns a frame supplies its accepted geometry.
One that ends without a frame says why:

- It found the window withdrawn: minimized, hidden, fullscreen, behind another
  native tab, or gone. The window is not in place, whatever its cached frame.
  The withdrawal's own event starts the snapshot that renders the next layout,
  and departing windows over the window stay visible until that layout covers
  them.
- Its app did not answer through every retry, about 1.5 s of backoff plus five
  rounds of 50 ms timeouts. The last observation decides. This is the one
  place where coverage rests on geometry that may be stale: if that app moved
  the window before it stopped answering, a departing window over the target
  hides and exposes desktop there until the app resumes and its move snapshot
  triggers an instant correction, subject to the two-correction allowance.
- A newer render, or its app's hide or quit, superseded it. The request is
  checked again as it ends, so a cancellation that arrives during any AX call,
  the readback or the last unanswered attempt included, still supersedes it.
  It carries no frame and decides nothing; whatever superseded it decides.

A replacement is **confirmed** when WindowServer lists it on screen within one
point of its AX-accepted frame on x, y, width and height, or its 100 ms limit has
passed. A returning window uses the same comparison on any Space, so its frame
can be confirmed while it is still in the closet. Unchanged returns use this
gate too: their accepted frame can still await an earlier app commit. The
comparison uses the accepted frame rather than the requested one because AX
can clamp geometry. A departure waits for every covering replacement to be in
place and confirmed; a return waits for confirmation before showing, and focus
waits for the show. Prepared returns also hold their existing sweep dependencies
until shown. A dependent visible placement also waits for every predecessor to
be in place and confirmed on screen, even when that predecessor covers no
departing window. This preserves shared coverage across apps with unequal
commit delays throughout a sweep, rather than just at its visibility changes.

The listing wait starts when policy receives the accepted frame, or tracks the
last observation of an unchanged or unanswered window. One gate owns each
transition's shared recheck, at most once every 4 ms while any window waits,
and each window's independent 100 ms limit. Each recheck batches waiting IDs
into at most one listing read. A newly accepted wait gets its initial read
without rereading existing waits; coinciding expiries release together without
reading the other windows or restarting their polling cadence. A single wait
needs at most 26 rechecks (100 / 4 + 1); the budget is per wait, so serial waits
can require more in one handoff. A new transition, pointer press, disable or
quit cancels it; completion leaves no listing timer or query at rest. The gate
runs under the stage too. A coverage dependency serializes one app commit per
dependent link, plus up to 4 ms to confirm it; disjoint placements remain
parallel. Latency can therefore grow by more than one recheck over a whole
sweep. The latency suite ends at final WindowServer geometry; its 200 ms p95
and all resource limits remain unchanged.

The `window-server-listing` assumption and signed contract (#40 E12) pin the
separate views: a stopped app keeps its old listing after accepting AX, an app
commits a hidden window's new frame before it is shown, and a closet hide lists
it off screen. Positive checks wait for final states within the harness margin;
only the stopped-app negative samples a 200 ms interval. The simulator serves
committed geometry with an 8 ms app commit by default, deferred while an app is
hung or busy. Its 0 and 20 ms variants exercise current and slower views. App
commits are native timed events, separate from Tessel's scheduling timers.

A window still in the closet is never in place, so the old view stays until its
replacement returns. A tile under a departing window whose last observation
is more than a point from its target position, such as one its app moved,
gets a position placement, so its own placement decides the handoff. Layer
exits, workspace switches, rail handoffs and placement under the stage share
this rule; focus and closet guards still apply.
An app move read at rest also triggers an instant correction, with the same
two-correction allowance. A pointer move waits for the next layout change.

Quitting returns managed windows inside the desktop. Crash recovery uses the
same closet boundary without persisted membership.

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
- a protected video's BGRA window capture returning a surface that locks but
  has no base address, while a display capture including it is readable and
  removing protection restores a readable window capture;
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

## Floating layer (#19)

Each workspace has a floating layer. Existing floats start hidden in the closet while the rail keeps
focus. If startup focus is already on a float, Tessel enters the whole layer.
The layer's visibility belongs to its workspace; switching away
hides all its windows and returning restores its selection.

Option+Z (`toggle layer`) shows the workspace's floats and selects the most
recently used one, or the first arrival before any has been used. Pressing it
again returns to the remembered rail tile and hides the layer. Tiles retain
their geometry and scroll position. Inside the layer, Option+H/K cycles backward
and Option+L/J forward in arrival order, wrapping at either end. Option+R and
Option+Shift+H/J/K/L do nothing there.

A shown layer raises its visible background-app floats with AXRaise
alone, serially from least to most recently used. Untouched floats favor the
first arrival. The raise changes neither AXMain nor activation. The pass is a
function of observed state rather than of the render that preceded it: one is
owed after every placement and whenever the native frontmost app differs from
the one the last pass was computed for, including an app with no managed
window. It runs once Tessel's own focus write has answered and native focus is
not on another managed window, since that means a selection is still on its
way. Every catalog publication and focus result re-checks this; with nothing
owed and the same frontmost app the check does nothing. Tessel skips frontmost-app floats:
raising a root there can take keyboard focus from the tile, as
[`ax-focus`](../Tests/Acceptance/ContractsAccessibility.swift) proves. The focused
float is selected normally when entering or navigating the layer.

A background raise must not finish an activation either.
[`deferred-ax-activation`](../Tests/Acceptance/ContractsScenarios.swift)
allows AX to accept AXFrontmost while the app is not yet active. A main or
raise write can then complete that activation. A newer selection cancels the
focus writes that follow a request, but it does not cancel the request. Each
app worker therefore remembers its latest request until it is resolved. A
request is resolved when Tessel's own AXMain and AXRaise have followed it and
the app is later read frontmost. It is also resolved when the frontmost read
taken where its focus writes stopped already finds the app active. Only the
presentation that issued the request takes that read; a later one that only
moves windows says nothing about it, even when it finds the app active. The
contract does not say whether activating the app another way, such as with
Cmd-Tab, consumes the request, so that does not resolve it. While a request
is unresolved, the worker declines to raise that app's floats and reports the
raise as deferred. The app's first publication after resolution owes another
pass. After a request whose focus writes never ran, that app's floats wait
for Tessel's next selection in it.

This is best effort on macOS 27. Every raised float is above background apps'
tiles, but the frontmost app's focused window can remain above another app's
float. [`ax-raise-across-applications`](../Tests/Acceptance/ContractsMotion.swift)
pins this limit; `ax-frontmost-activation` in the same file pins activation
bringing the app's windows forward. CG on-screen membership (`visible`) includes
covered windows; it cannot prove stacking. The supplementary #19 E7 and #38 E6
scenarios check the simulator's front-to-back `cg-on-screen-order` list and
keyboard focus instead. A seeded sweep replays command sequences under
deferred activation and stage retargets and checks that rule after each settle.
It and a second sweep, of superseded activations, native selections and
geometry-only relayouts, also check that no passive float raise moves
keyboard focus into the float's app.
The randomized order sweep excludes only floats whose app still has a native
activation request pending in the simulator; the safety guard deliberately
declines those raises. All other callers retain the full order rule. The
activation-resolution scenarios separately require the deferred pass to run
once that request resolves. Both sweeps print their comparison counts and
retain their existing coverage thresholds.

Rail motion with a shown layer retains the ordinary tile and background
captures, and waits for the serial background raise pass before revealing the
placed windows. The stage carries no float stand-ins or ordering API.
ADR-0006's capture and placement method is unchanged. No layer animation,
polling or recurring timer is added.

Pinning was rejected in #38 because the owner did not use its best-effort
result. Its command, shortcut and state are removed; Option+Shift+Z is unbound.
Existing configs that name the removed command receive the usual line-numbered
unknown-command error.

E30 runs the surviving prototype walkthroughs for U1 B, U2 B, U3 B and U4 A,
plus four-direction wrap and a 0.62-area width that must return at two-thirds
rather than half. It posts real keys and
uses signed fixture selection for the prototype's external focus actions. It
writes frames as fractions of the usable area, focus, layer state and visibility
to `.work/captures/layer/E30-fidelity.md`, retaining the last observation and
failing on mismatch. E30 requires no owner interaction:

```sh
TESSEL_CAPTURE_LAYER=1 scripts/verify captureOwnerPrototypeComparison
```

A new float takes focus and, when the layer was hidden, appears alone. Another
new float replaces that single view. Closing it or pressing Option+Z returns to
the rails; directional navigation expands to the whole layer. In an entered
layer, closing focus selects the surviving most recently used float; the final close returns to the rails.
Sheets stay with their parent and do not enter the layer independently. External
focus on a hidden float enters the whole layer; external tile focus leaves it,
hiding its floats. Focus moves away before a float enters the closet.
A hidden modal can leave its app waiting until the dialog is shown again.

Option+F (`toggle float`) moves a tile to the layer, centered at half the area's
width and two thirds its height. It becomes the newest float arrival, and the
rail closes its gap and remembers the left neighbor. Moving a resizable float
back inserts it to the right of the remembered tile, creating a rail if needed.
Its current width selects the nearest rail preset; a tie chooses the wider one.
A one-shot read on the app's AX worker publishes its current frame before the
float joins the rail. Earlier resize snapshots therefore arrive while it still
floats, and cannot replace the chosen preset with an exact mouse width during
the focus-before-hide handoff. A failed read leaves it floating; a newer layout
or selection decision cancels the pending transfer.
A fixed-size float bounces and stays floating. Manual choices last for that
window's lifetime, including catalog refreshes, and reset on restart. Sending a
float with Option+Shift+N follows it into the destination workspace's layer.

The two commands are always registered and rebindable through `[keys]`.
Toggling an empty layer does nothing. Removing a config restores defaults;
quitting returns all floats. `status --json` reports
`workspaces.layer: {"state":"hidden","focused":false}`. State is `hidden`,
`single`, or `shown`; `focused` says whether focus is in the layer.
Hidden floats retain `state: "floats"`, workspace membership, null `rail` and
`slot`, and `visible: false` in `windows --json`. Manual classifications report
`floats` / `moved to the layer` or `tiled` / `moved to a rail`.

Classification is fixed: Tessel manages windows at CG
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

The pin-only #19 E9/E10 scenarios and E11 capture are retired by #38. Surviving
raise-pass and deferred-activation scenarios now use the shown layer and are
tagged #38 E6. The hidden-float capture case is #38 E4. E30 no longer contains
pinning or remembered-tile return while pinned; its 0.62-area width check stays.

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
| Startup | #1 E9 |
| Switch | #2 E31, E32 |
| Send | #2 E35 |
| Rail scroll and elevator | #57 E18; otherwise wiring regression |
| Carousel rail change | #26 E15 |
| Floating layer | #19 E29 |
| Reduce Motion | Wiring check that Reduce Motion makes a carousel move instant (E18 belongs to P) |
| Reload | File watcher wiring for save, atomic replace, chmod and delete |
| Crash, quit and unavailable mechanics | #2 E28, E29, E34 |
| CLI and config files | #1 E10, E12; #55 E12; #1 U-cli-args, U-private-transport, U-read-only-transport, U-stalled-clients, U-observer-identity, U-cpu-oracle, U-notification-retries |
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
local processing/observation budget without adding intentional display waiting.
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
definition and nonpersonal run metadata. Incomplete local runs retain partial counts and the
failed sample index. No window listings or titles reach the artifact.

### Issue 33 example amendments

The removed off/stack examples are retired explicitly:

- #2 E1: Management off is removed by #33 E1–E4.
- #2 E3: Floating visibility now follows #19 E6 and E12.
- #2 E13: Mixed stack cycling is replaced by rail traversal and layer navigation.
- #2 E14: New rail arrivals follow #26 E10–E11, rather than append to a stack.
- #2 E19: One-window fill is replaced by #33 E5–E6 nominal widths.
- #2 E20: Failed-fill floating is removed; carousel learns intrinsic size bounds (#26 E8).
- #2 E21: Mouse reconciliation follows #33 E11–E14.
- #2 E22: Stack centering and stack gap layout are removed; rail gap checks remain.
- #2 E23: New dialogs follow #19 E12 single-layer entry.
- #26 E5: Proportional stretching is replaced by #33 E5–E6.

Native-tab identity from #2 E12 remains covered, with rail neighbor selection
replacing stack wrap/MRU assumptions. #2 E28 and #19 E24 retain quit cleanup;
flag disable/re-enable cases are retired. #19 E5–E6 retain bindings and startup
visibility. #1 E17 now starts managed, and #1 E7 no longer expects a new arrival
to leave the old tile focused. The hung-app classification oracle excludes
policy-owned visibility and membership fields.

E18 was amended during delivery to permit show-before-hide, scrolling and
visible-before-focus. AX origin clamping requires a growing right tile to move
before resizing: size-first is clamped, while position-first can list an
intermediate frame. Independent apps may have geometry bursts in flight
together, so a hung neighbor cannot block a responsive placement. Bursts stay
serial within each app. Hidden preparation, one write per attribute,
replacement-before-retirement and visible-before-focus remain required.

#40/#35 amend #33 E18 with this accepted text:

> Tessel's ordering never exposes the desktop, judged by what WindowServer
> lists. Tessel retires a window only when WindowServer lists at its destination
> every replacement covering its area, and shows a returning window only when
> WindowServer lists it at its final frame; each wait lasts at most 100 ms. An
> app that does not commit its accepted geometry within the limit exposes what
> it would expose at rest, until its commit. A burst excuses only the
> intermediate frames WindowServer lists for its own window, while it lists
> them; never that window's initial frame.

The pointwise old/final ownership and shared-coverage assertions run after every
port call and app commit against the served view. Only a window's own listed
intermediate frame excuses its geometry and affected points; its listed start
frame never excuses a gap while a commit is pending. A returning window must
be final when first shown. The matrix covers fourteen operations in all three
schedulers, with one app, two apps, delayed AX replies to either app, and 0, 8
and 20 ms commits (504 scenarios). Gap changes require reply completion to
reorder when the delayed app changes.

#38's external-change clause still compares minimize, close, hide and resize
during a layer exit with the same change at rest. Their exposure ends at the
first recheck after the app commits the placements of the render their snapshot
triggers (#40 E13). The main-lane job that delivers that snapshot identifies the
render independently of coverage; native app commit records and policy timer
records identify its end. Missing or malformed evidence fails the arm. A
recheck may finish in the main job its timer makes runnable. No later state may
expose the point, and the handoff arm may expose it no longer than the at-rest
arm. A change Tessel has already observed is not external: a tile it read as
moved gets a placement, and a withdrawn placement never counts as in place. A
placement cancelled at any point, including readback or the last attempt,
is superseded and carries no frame.
#39 adds the move case. An app's move of a rail tile during a layer exit or
at rest ends its exposure the same way, and so does a move read after an
unanswered app resumes: an on-screen rail tile returns instantly to its
accepted point, up to two corrections, while pointer moves wait for the next
layout change. An existing stage is retargeted instead of cleared by the
correction, and the correction's placement waits for WindowServer like any
other.

E20 (#35) requires zero intermediate and gap frames for workspace, rail,
left-tile `alt-r`, both stops (halves and mixed), and close. Right-tile `alt-r`
and open report their residue without asserting zero. The accepted platform
residue comes from independent AX position and size commits: AppKit does not
accept an atomic `AXFrame` write. Waiting for the final listing prevents Tessel
from retiring or returning windows too early; it cannot remove an intermediate
frame the app itself commits while visible. #35 accepts this residue.

Close comparison starts at the first frame excluding the destroyed window.
Opening still records native birth geometry, intermediate frames, returns to
the initial bounds after landing, and final overlap; its intermediate count is
reported. Final overlap remains an assertion. Independent native geometry,
visible palette centers and pixel movement reject a frozen or incorrectly
filtered recording. The capture reports left/right widths and both stops
separately; AX bursts have no exception in the operations that require zero.

The old #2 E16 failure-recovery assertion that immediately hid the outgoing
window now retains the old view while a hung app cannot prepare its replacement
(#33 E18). Its native-focus and external-activation assertions are preserved.
The retry measurement excludes later focus-confirmation reads while still
requiring exactly the four original retry delays. Initial-enumeration race
setups now hold the startup AX list rather than entering a removed mode.

#41 ends an instant handoff as failed once a branch has failed and no placement
or focus request remains in flight or can start. It releases placement so the
shown layer can restack, retaining unsafe covers and all outgoing windows until
focus completes. A failed focus request keeps its native-focus and external-app
activation observations: either can still complete visibility truthfully.
The stage expires through its existing linger; failure neither reveals success
nor checks deliberately retained covers as failed hides. Recovery waits for the
next command's render, which retries pending placements without an automatic
retry or desktop activation.

Retained native scenes also follow the kept rail policy. Failed-hide injection
uses initially in-bounds windows whose widths force overflow. The latency
elevator's singleton keeps its nominal half width. Resource setup waits for
workspace sends to finish before opening the next fixture. The foundation idle
scene discovers twenty existing windows at startup; a live burst of twenty
arrivals can still be animating after the one-second setup settle. It now also
proves zero stage activity during the measured idle window. The hidden-layer
scene finishes the new float's single-layer arrival before hiding it with
alt-z. Sample counts, the one-second settle, twenty-second idle windows and all
latency/resource limits are unchanged.

The #1 E9 restart oracle retains IDs, classification, reasons and tab counts;
it excludes policy-owned visibility and rail membership, which can change when
cleanup returns windows and startup follows native focus. Mixed-app rail setup
uses rail navigation to reveal a closeted destination before selecting it,
preserving #19 E26.
The layer-key wiring scene creates its panel before startup to establish the
hidden-layer Given; a live new panel would enter its single-window layer.

## App icon (#59)

`scripts/build` compiles the variant's Icon Composer source with `xcrun actool`
into the app bundle's `Assets.car` and merges the keys actool assigns, including
`CFBundleIconName`, into `Info.plist`: `Sources/App/Tessel.icon` for the daily
build and `Sources/App/TesselDev.icon` for the development build. macOS 27
renders an Icon Composer icon natively; a legacy `.icns` is framed in a gray
squircle at 16 and 32 px. The sources live under `Sources/App`, so they are
build inputs. The fixture bundle has no icon. See [the brand assets](brand/README.md)
for the mark and how to edit the sources.

Bare `swift test` proves E1–E3 with the real actool, and E11–E14 by reading
the repository. The signing journey proves E4 and the unchanged idle budget
proves E5. This opt-in capture renders both signed bundles' icons as the
system resolves them, at 256, 128, 32 and 16 px on light and dark, for E6–E7:

```sh
scripts/build --variant daily && scripts/build
TESSEL_CAPTURE_APP_ICON=1 scripts/verify captureAppIcons
```

Images go to `.work/captures/app-icon`. The owner checks E8 (the dark, clear
and tinted icon styles) on their own Mac, E9 on the pushed README, and uploads
`docs/brand/social-preview.png` in the repository settings for E10. No
screenshot of a real machine is committed.

## Acceptance example layers (#24)

This table is the maintained example-to-layer map for issues #1, #2, #18, #19, #26, #33, #36, #38, #39, #40, #41, #49, #51, #55, #57, #59, #62 and #63.
Its format is exactly `Example | Layer`, one literal ID per row, with no
description in either cell. Numbered IDs use `#1 E9`; unnumbered IDs use
`#1 U-cli-args`. P means deterministic policy, J journey, L latency,
R the unchanged resource suite, C a native assumption contract, T tooling,
and X an owner-reviewed capture.
Foundation E13 belongs to J; supplementary visual permission evidence does
not assign it to a second layer.

An ID appears literally in its `@Test` name or a journey's `step` name.
P files live in `Tests/PolicyTests/Scenarios/`, J in
`Tests/Acceptance/Journeys*.swift`, L in `Tests/Acceptance/Latency.swift`,
and R in `Tests/Acceptance/Resources.swift`. X tests use `capture*` function
names in Acceptance, or live in `Tests/Acceptance/Captures*.swift`.
C tests live in `Tests/Acceptance/Contracts*.swift`; T in `Tests/CheckTests/` or
`Tests/BuildTests/`.
Contracts declare their assumption IDs as well as any mapped native example. The E20 integrity check
rejects missing tags, unmapped tags, duplicate map rows and tags in another
layer. Every mapped ID must have a tagged test in its own layer.

For #63, `JourneysApplications.swift` checks accessory quit, crash and discovery
without activation (E1–E3), plus a regular exit's exact surviving windows,
contiguous slots and single-key traversal (E5). The native `application-lifecycle`
contract counts each regular and accessory KVO arrival and departure once (E4);
the journey checks their published effect without adding production event
counters. E6 tags the existing three resource scenes with unchanged budgets.

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
| #2 E2 | P |
| #2 E4 | P |
| #2 E5 | P |
| #2 E6 | P |
| #2 E7 | P |
| #2 E8 | P |
| #2 E9 | P |
| #2 E10 | P |
| #2 E11 | P |
| #2 E12 | P |
| #2 E15 | P |
| #2 E16 | P |
| #2 E17 | P |
| #2 E18 | P |
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
| #18 E1 | P |
| #18 E2 | P |
| #18 E3 | P |
| #18 E4 | P |
| #18 E5 | P |
| #18 E6 | P |
| #18 E7 | P |
| #18 E8 | P |
| #18 E9 | P |
| #18 E10 | P |
| #18 E11 | P |
| #18 E12 | P |
| #18 E13 | P |
| #18 E14 | P |
| #18 E15 | P |
| #18 E16 | P |
| #18 E17 | P |
| #18 E18 | P |
| #18 E19 | P |
| #18 E20 | P |
| #18 E21 | P |
| #18 E22 | P |
| #18 E23 | P |
| #18 E24 | C |
| #18 E25 | J |
| #18 E26 | R |
| #18 E27 | L |
| #18 E28 | X |
| #19 E1 | P |
| #19 E2 | P |
| #19 E3 | P |
| #19 E4 | P |
| #19 E5 | P |
| #19 E6 | P |
| #19 E7 | P |
| #19 E8 | P |
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
| #19 U-quit-capture-drain | P |
| #26 E1 | P |
| #26 E2 | P |
| #26 E3 | P |
| #26 E4 | P |
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
| #33 E1 | P |
| #33 E2 | P |
| #33 E3 | P |
| #33 E4 | T |
| #33 E5 | P |
| #33 E6 | P |
| #33 E7 | P |
| #33 E8 | C |
| #33 E9 | P |
| #33 E10 | P |
| #33 E11 | P |
| #33 E12 | P |
| #33 E13 | P |
| #33 E14 | P |
| #33 E15 | J |
| #33 E16 | P |
| #33 E17 | P |
| #33 E18 | P |
| #33 E19 | C |
| #33 E20 | X |
| #33 E21 | T |
| #33 E22 | T |
| #33 E23 | T |
| #33 E24 | T |
| #36 E1 | C |
| #36 E2 | J |
| #36 E3 | J |
| #36 E4 | J |
| #36 E5 | J |
| #36 E6 | J |
| #36 E7 | J |
| #36 E8 | X |
| #38 E1 | P |
| #38 E2 | P |
| #38 E3 | P |
| #38 E4 | P |
| #38 E5 | P |
| #38 E6 | P |
| #38 E7 | T |
| #38 E8 | X |
| #38 E9 | T |
| #39 E1 | P |
| #39 E2 | P |
| #39 E3 | P |
| #39 E4 | P |
| #39 E5 | P |
| #39 E6 | P |
| #39 E7 | P |
| #39 E8 | P |
| #39 E9 | P |
| #39 E10 | P |
| #39 E11 | P |
| #39 E12 | P |
| #39 E13 | P |
| #39 E14 | P |
| #39 E15 | P |
| #40 E1 | P |
| #40 E2 | P |
| #40 E3 | P |
| #40 E4 | P |
| #40 E5 | P |
| #40 E6 | P |
| #40 E7 | P |
| #40 E8 | P |
| #40 E9 | P |
| #40 E10 | P |
| #40 E11 | P |
| #40 E12 | C |
| #40 E13 | P |
| #40 E14 | X |
| #41 E1 | P |
| #41 E2 | P |
| #41 E3 | P |
| #41 E3a | P |
| #41 E3b | P |
| #41 E4 | P |
| #41 E5 | P |
| #41 E6 | P |
| #41 E7 | P |
| #41 E8 | P |
| #49 E1 | P |
| #49 E2 | P |
| #49 E3 | P |
| #49 E4 | P |
| #49 E5 | P |
| #49 E6 | P |
| #49 E7 | P |
| #49 E8 | P |
| #49 E9 | P |
| #49 E10 | P |
| #49 E11 | P |
| #49 E12 | P |
| #49 E13 | P |
| #49 E14 | P |
| #49 E15 | X |
| #51 E1 | P |
| #51 E2 | P |
| #51 E3 | P |
| #51 E4 | P |
| #51 E5 | P |
| #51 E6 | C |
| #51 E7 | P |
| #55 E1 | P |
| #55 E2 | P |
| #55 E3 | P |
| #55 E4 | P |
| #55 E5 | P |
| #55 E6 | P |
| #55 E7 | P |
| #55 E8 | P |
| #55 E9 | P |
| #55 E10 | P |
| #55 E11 | P |
| #55 E12 | J |
| #57 E1 | P |
| #57 E2 | P |
| #57 E3 | P |
| #57 E4 | P |
| #57 E5 | P |
| #57 E6 | P |
| #57 E7 | P |
| #57 E8 | P |
| #57 E9 | P |
| #57 E10 | P |
| #57 E11 | P |
| #57 E12 | P |
| #57 E13 | P |
| #57 E14 | P |
| #57 E15 | P |
| #57 E16 | P |
| #57 E17 | P |
| #57 E18 | J |
| #59 E1 | T |
| #59 E2 | T |
| #59 E3 | T |
| #59 E4 | J |
| #59 E5 | R |
| #59 E6 | X |
| #59 E7 | X |
| #59 E8 | X |
| #59 E9 | X |
| #59 E10 | X |
| #59 E11 | T |
| #59 E12 | T |
| #59 E13 | T |
| #59 E14 | T |
| #62 E1 | J |
| #62 E2 | J |
| #62 E3 | P |
| #62 E4 | P |
| #62 E5 | P |
| #62 E6 | P |
| #62 E7 | P |
| #62 E8 | P |
| #62 E9 | P |
| #62 E10 | J |
| #62 E11 | X |
| #62 E12 | J |
| #62 E13 | J |
| #62 E14 | J |
| #62 E15 | P |
| #62 E16 | R |
| #62 E17 | J |
| #62 E18 | P |
| #63 E1 | J |
| #63 E2 | J |
| #63 E3 | J |
| #63 E4 | C |
| #63 E5 | J |
| #63 E6 | R |
<!-- Pending capture: #33 E20 -->
<!-- Pending capture: #36 E8 -->
<!-- Pending capture: #59 E8 -->
<!-- Pending capture: #59 E9 -->
<!-- Pending capture: #59 E10 -->
<!-- Pending capture: #62 E11 -->

E21 has an opt-in executable capture in `CapturesCarousel.swift`; it needs a
pixel recording of the stage before the owner can review it again. All mapped
rows have executable coverage. E15 owns J: the native mixed-app landing and
activation assertions. E14 and E16 own P; their untagged journey steps check
wiring.

All deterministic carousel examples run directly against the simulated stage:
rail slides, captures, placement under the stage, retargets, interrupts,
Reduce Motion, a missing Screen Recording grant, closet timing and bounce.
Retained membership and AX-retry scenarios use duration zero; CarouselMotion
proves the animated path. #26 E16 also covers an unfinished layout placement
after a hung app resumes, retried by focus or another tile's app-move correction:
the real window moves under the stage, even when the layout's target frames
have not changed.
E4's command matrix checks settled invariants at
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

### Instant pixel evidence (#33 E20)

`TESSEL_CAPTURE_INSTANT=1 scripts/verify captureInstantOperations` records twelve
fixture-only operations each for workspace, rail, resize, stop crossing, open
and close. The signed observer excludes non-fixture applications from the
ScreenCaptureKit display stream, requests 120 Hz and persists only palette owner
masks. Capture windows have uniform content through their transparent titlebars,
with titlebar buttons hidden, so their interiors carry constant palette content. The opt-in run compiles its pixel analyzer with release optimization;
ordinary verification keeps its existing build configuration. It checks pixel movement against independent native geometry and checks
visible palette centers before accepting a recording. Outputs remain ignored
under `.work/captures/instant/`, including the per-frame masks, analysis and
operation table. It costs no time in ordinary verification and has no CI job.
A recording that does not reflect the native movement is inconclusive, not a
zero-glitch result. Delivery still requires the owner's authorized desktop to
collect this evidence and run the full signed verification suites.
