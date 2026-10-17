# Development

Use macOS 27 or later on Apple silicon, with Xcode 27 selected by `xcode-select`.
The app, its build tool, and the acceptance harness are Swift with Apple's
frameworks; there are no package dependencies. `Package.swift` describes only
the development tools ([ADR 0001](adr/0001-swift-for-build-and-verification-tooling.md)).
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

Development uses `com.taecontrol.tessel.dev`; `scripts/build --variant daily`
uses `com.taecontrol.tessel`. Keep the signing identity stable across rebuilds.
Never launch an unsigned or ad-hoc-signed bundle with either ID. Doing so can
revoke the existing Accessibility grant. Bundles must stay outside `/tmp`,
where LaunchServices cannot register them reliably.

## Verification

Stop this worktree's development app and any other tessel instance managing
windows before running the harness. Another instance can manage the fixture
windows and contaminate verification. Run:

```sh
scripts/build
scripts/verify --functional
scripts/verify --resources
```

Use an awake, unlocked macOS desktop. The harness checks that precondition and
holds a temporary `caffeinate` assertion until its processes are cleaned up.
AX can expose incomplete application elements when the display sleeps.

The harness launches the signed development bundle with `open`, an isolated
temporary `XDG_CONFIG_HOME`, and real AppKit fixture processes. It drives those
processes through a test-only local socket, observes tessel through its bundled
CLI, and cleans up its processes and data. The harness always passes
`--test-fixture-only`: only fixture processes are observed or managed, including
startup crash recovery. This argument exists only in the signed `.dev` build and
is rejected by the daily build. Before activating Finder for an empty workspace
in fixture-only mode, tessel requires a successful AXWindows read without
ordinary windows. Finder's desktop scroll area is allowed; unknown entries and
failed reads block activation. A failed read is retried twice off the main
thread, because a busy Finder or one answering its first AX client can miss a
short timeout; only the render that requested it may then activate Finder.
Tessel inspects no window content. Local tests still check that managed
windows disappear and report
when the Finder desktop assertion is skipped. CI requires the full assertion.
Full window listings, real window titles, and personal configs are never
printed or saved. The independent AX probe verifies the running code's signed
fixture identifier before reading a window or posting a key. It revalidates the
running signature on every operation, retaining audit-bound Security code
objects to avoid repeating signature construction during timed observations.
The audit binding rejects exec and PID reuse; denied task-name access keeps
the stateless validation path. A fixture that replaces itself with a short-lived
system process verifies that the observer rejects it while its PID is still alive.
The oracle reads the frontmost application through AX; cached LaunchServices metadata can be absent
briefly during activation. Fixtures cooperate with AppKit's activation handoff
without ordering a window during the external-activation assertions.
The fixture protocol reserves 64 KiB per-socket reply buffers: twenty-window AX
observations exceed macOS's default 2 KiB datagram limit. It changes no system
socket settings.

`scripts/verify` runs both suites with Swift Testing. To select tests, pass part
of a test name from `Tests/Acceptance`, such as `scripts/verify e08`. The
functional suite covers foundation E1–E12 and E15–E21; foundation E13/E14 require visual evidence of
the permission journey.
The resource suite covers foundation E22 with the default config and workspace
E36 with 20 fixture windows across ten workspaces. Each keeps its existing setup
and one-second settle, then measures one 20-second idle window from outside the
app with `proc_pid_rusage` (`rusage_info_v0`). Interrupt wakeups
(`ri_interrupt_wkups`) must not exceed 11 and user + system CPU must not exceed
100 ms. Mach ticks are converted with `mach_timebase_info`. Physical footprint
(`ri_phys_footprint`) must be below 30 MB both at the start and at the end of the
window; a start failure stops without waiting. Each test prints its measurements
and limits, and failures identify the exceeded limit.

The wakeup limit targets work recurring every two seconds or less; the CPU cap
also catches work that never sleeps. The footprint limit accounts for the app's
own memory. The limits, spike measurements, and their rationale live in
`Tests/Acceptance/resource-budget.json` and
[ADR 0003](adr/0003-verify-idle-work-with-wakeups-cpu-and-footprint.md).
Changing these limits requires an owner decision backed by new evidence.
LaunchServices notifications can increase local CPU while the workspace
experiment is idle (issue #15). Keep the desktop awake and stop other tessel
instances before interpreting an outlier. Do not run `sample` during a measured
window: it suspends the process and changes its counters.

CI runs permission, functional, and resource verification sequentially in one
acceptance job. The resource command has a 90-second budget, and the whole job
has an eight-minute (480-second) timeout. The workspace switch timing artifact
is still uploaded.

For minimize and restore, the 500 ms observation deadline begins at AppKit's
completion notification, after the Dock animation. macOS sends the AX event
at that point; the animation itself can take longer than 500 ms. The fixture
acknowledges those commands on completion, without changing the assertion's
deadline. Other window operations use the ordinary command acknowledgement.

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
a tab that is no longer its group's front, and a classification change
reasserts focus only when the app reports another window, so a raise cannot
select the former tab again over the user's choice.
Minimized tab entries continue to follow AppKit's published list.
The catalog carries a native front's replacement relationship into Workspaces,
which preserves membership, arrival position, and focus history. Its next render
reconciles visibility for the replacement CG window, including hidden groups.
The group's last fill result also follows its front; an ordinary show retries
that result without resizing the group merely because another tab was selected.
The close fixture can retain a closed NSWindow object to verify that revalidation
still retires its AX window.

CI runs the same commands on `xcode-27` (macOS 27). Its short-lived certificate
is created in a temporary keychain; no signing material is stored in GitHub.
Only the disposable runner provisions its Accessibility database, for the
denial and restart checks in `scripts/verify --permission`; elsewhere that
suite is skipped. Local verification uses the permission granted to the signed
development bundle.

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
count, `workspace` (1…10 or null), and `visible` (CG on-screen membership).
`state` includes `fullscreen`. Titles are never queried. `status --json` adds
`workspaces.enabled`, `reason`, `active`, `gaps`, and the effective `keys`.
With the experiment disabled, tessel observes without managing ordinary windows.

`Tests/Acceptance/Workspaces.swift` covers issue #2 E1–E35 at the CLI and
independent AX/CG boundary. The trusted fixture posts the real Carbon shortcuts
as CGEvents only after confirming a fixture window is frontmost and on screen.
Transient safety refusals are retried before posting, for at most one second;
transport failures and posted events are never retried. Switch timing still
starts at the actual event post. CI checks Finder desktop focus throughout the
existing switch deadline rather than requiring its first AX sample to succeed.
Only empty-workspace observations inspect Finder, so unrelated AX reads do not
consume the fixture's timed visibility, frame, and focus checks.
Timed checks read `AXFocusedWindow` directly, including a focused sheet's parent:
`AXWindows` can temporarily omit a live window during a Space move. CG membership
supplies fixture visibility independently, including the empty-workspace check.
The focused window's frame and main state are read together in one AX request;
ordinary focused-only observations omit unrelated child controls. Sheet and full
observations retain their parent and child relationships.
Cached LaunchServices activation metadata is read only by setup observations;
timed checks retain the live system-wide AX focus check.
The active number is observed through the signed app's status-item AX label
inside the switch deadline; CLI fields are checked afterward so process startup
does not consume that deadline. The blocked-initial-AX regression deliberately
suspends the fixture, checks that its orphan stays hidden, and times recovery from
resume. The ordinary crash-recovery test retains its one-second restart deadline.
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

Switch completion means visible, filled, and focused, measured from posting the
event. The functional suite records 20 switches in `.work/switch-calibration.json`.
`Tests/Acceptance/switch-budget.json` enforces three times the maximum of the
delivery's 20 CI measurements, capped at 200 ms. Recalibrate on `xcode-27`, retain
its run ID and measurements in that file, and rerun against the resulting budget.
The delivery calibration recorded a 114.393042 ms maximum in run 38947144837,
giving the 200 ms cap. Missing or inconsistent calibration data fails verification.
Workspace E36 enforces the same idle wakeup, CPU, and footprint limits as E22.

Before the first public release (#6), revisit the bundle IDs, config schema,
and read-only CLI contract. A command that changes state or exposes titles needs
an architecture decision before implementation.

## Rails experiment (#17)

`[experiments] rails = true` enables workspaces in rail layout, independently
of the `workspaces` flag. Without it, the workspace experiment keeps its
one-window layout and shortcuts. With both flags absent, tessel only observes.
Reloading into rails forms one row per existing workspace in arrival order.
The active workspace and focused window remain selected. Membership and rail
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
`[keys]` overrides merge with the layout's defaults. `windows --json` adds
nullable one-based `rail` and `slot` fields, and `status --json` reports
`workspaces.layout`, the nullable current `rail`, and `railCount`. The status
item shows the workspace number and one bar per rail, highlighting the current
one; its AX label includes the current rail and total. The map overlay belongs
to #18, and the floating layer to #19.

`Tests/Acceptance/Rails.swift` exercises #17 at the same signed CLI and
independent AX/CG boundary as #2. The fixture accepts width fractions of the
usable area, keeping fitting and overflowing scenarios independent of screen
size. Run `scripts/verify FunctionalRails`; resource E29 is included in
`scripts/verify --resources` with the unchanged ADR 0003 limits. Rails E28
records 20 completed scrolls and elevator trips in `.work/rails-calibration.json`;
`Tests/Acceptance/rails-budget.json` retains the authorized xcode-27 run and
uses three times its maximum, capped at 200 ms. Timing starts at the real key
post and ends after independent AX position, size, focus and CG visibility
checks. Capture the app's own status button, without desktop content, with:

```sh
TESSEL_CAPTURE_WORKSPACES=1 scripts/verify captureRailsStatusItem
```

The PNGs are written to `.work/captures/E26-workspace-1-rail-{1,2}.png`.
