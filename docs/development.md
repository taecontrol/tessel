# Development

Use macOS 27 or later on Apple silicon, with Xcode 27 selected by `xcode-select`.
The build and acceptance harness use Swift, AppKit, and Python's standard library;
there are no package dependencies.

## Signing and launching

Create `Signing.local.xcconfig` in this worktree, containing
`CODE_SIGN_IDENTITY =` followed by the name or SHA-1 fingerprint of an available
code-signing identity from your keychain. Use your Apple Development identity.
The file is ignored; never commit its contents, a certificate, or a team ID.

Run `scripts/build`. It compiles optimized binaries and installs signed bundles
in `.build/apps`. It refuses missing, unavailable, or ad-hoc signing identities
before building a bundle. Every rebuild changes the app binary's build version,
so the permission-preservation test exercises a real signature change.

Open the development bundle and grant Accessibility in System Settings:

```sh
open ".build/apps/Tessel Dev.app"
".build/apps/Tessel Dev.app/Contents/MacOS/tessel" status --json
```

The CLI accepts `windows [--json]` and `status [--json]`.
You can symlink this bundled CLI into a directory on your `PATH`.
With a custom `XDG_CONFIG_HOME`, pass the same value to `open --env` and the CLI.
The bundle ID and config path select the instance the CLI observes.

Development uses `com.taecontrol.tessel.dev`; `scripts/build --variant daily`
uses `com.taecontrol.tessel`. Keep the signing identity stable across rebuilds.
Never launch an unsigned or ad-hoc-signed bundle with either ID. Doing so can
revoke the existing Accessibility grant. Bundles must stay outside `/tmp`,
where LaunchServices cannot register them reliably.

## Verification

Stop this worktree's development app before running the harness. Run:

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
CLI, and cleans up its processes and data. No real user window is an assertion
target. Full window listings, real window titles, and personal configs are never
printed or saved. The independent fixture AX probe refuses any other bundle ID.

`scripts/verify` runs both suites. Individual functional tests can be selected
by method name from `Tests/Acceptance/foundation.py`. The functional suite covers
E1–E12 and E15–E21; E13/E14 require visual evidence of the permission journey.
The resource suite covers E22 with 20 fixture windows and ten 60-second idle
measurements. CPU time comes from `proc_pid_rusage`, not elapsed wall time;
resident memory must stay under 50 MB. Resource calibration runs only on CI.
Mach ticks are converted with `mach_timebase_info`. The committed CPU budget is
41.319498 ms per idle minute: three times the maximum of ten CI measurements
(13.773166 ms). The largest resident measurement was 47.071232 MB. The budget
file records the measurements and the source run; later CI runs enforce it.

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

CI runs the same commands on `xcode-27` (macOS 27). Its short-lived certificate
is created in a temporary keychain; no signing material is stored in GitHub.
Only the disposable runner provisions its Accessibility database. Local
verification uses the permission granted to the signed development bundle.

## Configuration and observation

The config is `$XDG_CONFIG_HOME/tessel/tessel.toml`, defaulting to
`~/.config/tessel/tessel.toml`. Foundation accepts an empty document or an empty
`[experiments]` table. There are no experiment keys in #1. Unknown keys and invalid
TOML produce a line-numbered error; the last valid configuration stays active.
Saving, replacing, or deleting the file reloads it automatically. `status --json`
reports the effective config, its revision, its source state, and any error.

Window records contain only an ID, app name, bundle ID, state, reason, and native
tab count. Titles are never queried. The foundation only observes; it does not
move, hide, or resize other apps' windows.

Before the first public release (#6), revisit the bundle IDs, config schema,
and read-only CLI contract. A command that changes state or exposes titles needs
an architecture decision before implementation.
