# Screen capture permission diagnosis

Screen Recording permission and ScreenCaptureKit's capture acknowledgement are
separate. A successful `CGPreflightScreenCaptureAccess` does not establish that
a subsequent capture will leave focus undisturbed. Verification needs both the
development app and the independent signed fixture observer to capture content;
they have separate identities and consent state.

## Evidence and limits

A read-only investigation of the 2026-10-21 verification interval found:

- At 10:06:52, `replayd` allowed the observer's ScreenCaptureKit request,
  completed a screenshot, then ran `SCAlertStatsManager` and created a user
  acknowledgement alert.
- At 10:07:28, a development-app screenshot followed the same sequence with
  TCC access allowed. Another development process generated an alert at
  10:07:57 after a successful capture, when the later authorization-record
  lookup failed to resolve its binary path and audit token. The logs do not
  establish why that lookup failed.
- All attributed ScreenCapture requests that returned an authorization result
  for these two identities were allowed. Every non-preflight request was
  mediated by `replayd`. The alerts later reported refusal or cancellation;
  the logs do not distinguish a person's response from process cleanup.
- Both signed bundles had certificate-based designated requirements, without
  a cdhash pin. A signed rebuild during the investigation changed both code
  hashes and preserved both designated requirements. This comparison does not
  test a running process's grant, but gives no basis for changing the signer.

The app calls `CGRequestScreenCaptureAccess` only on the first eligible carousel
render with a missing grant, once per `Workspaces` instance. It does not request
access unconditionally at launch. The observer checks preflight and fails its
capture contract if the grant is missing; it never calls the request API.
The harness launches the signed bundles from the same `.build/apps` paths;
its temporary directory contains configuration and sockets, not app copies.

The observed interruption is ScreenCaptureKit's acknowledgement path after
capture, rather than repeated initial grant requests. The logs establish this
mechanism for the recorded alerts, but do not establish the cause of every
previously reported prompt, an acknowledgement's retention interval, or the
audit-token failure's cause. Raw machine logs are not versioned.

Production and the overlay contract also use `CGWindowListCreateImage` to read
one pixel of their own overlay. Apple's [macOS 15 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes)
say deprecated capture APIs can cause additional alerts. That remains a
separate candidate to isolate; removing the overlay's drawn-pixel check would
weaken the stage contract, and the recorded ScreenCaptureKit alerts do not
justify doing so.

## Owner decision before a repair

The existing capture callbacks returned before acknowledgement was answered in
the recorded interval. A successful capture or preflight is therefore
insufficient for an automatic "ready without prompts" gate. The consent,
entitlement, capture and indicator behavior is unchanged pending this decision.

1. **Explicit verification preparation, recommended first.** Authorize a
   bounded preparation flow that captures once through each signed identity
   and lets the owner settle any OS acknowledgement before focus-sensitive
   checks begin. Confirm persistence across process restarts and a signed
   rebuild before implementing a gate. This preserves the independent observer,
   existing checks and recording indicator. Preparation may require an
   acknowledgement for each identity; it cannot promise that macOS will never
   require another one.
2. **System picker consent.** Apple's [ScreenCaptureKit documentation](https://developer.apple.com/documentation/screencapturekit)
   recommends `SCContentSharingPicker`. Adopting it changes the keyboard and
   consent journey and needs a feasibility check for dynamically selected
   windows, closet captures and the independent observer. It is not a drop-in
   repair to the accepted stage behavior.
3. **Persistent Content Capture entitlement.** Apple's [entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture)
   describes it for VNC apps and requires Apple's approval and a provisioning
   profile. It is not an entitlement to add speculatively to a window manager
   or its test observer. Eligibility and the permission implications would need
   an owner decision first.

Changing `CGRequestScreenCaptureAccess` alone cannot remove the observed
acknowledgement path. Disabling motion, removing pixel assertions, sharing the
app's capture result with the observer or suppressing the recording indicator
would not meet the verification contract.

## Bounded confirmation

Follow [the desktop prerequisites](development.md#verification) first. Do not
run these while a daily or development tessel instance manages windows. Use the
existing signed development bundles; no permission database reset is needed.

```sh
scripts/verify screenRecordingPreflight
scripts/verify stageCapturesWholeWindows
scripts/verify stageCapturesWholeWindows
scripts/verify carouselCardsKeepCrossAppOrderAndFocus
scripts/verify carouselCardsKeepCrossAppOrderAndFocus
```

The first command checks only a non-prompting read. On each identity's first
capture, record whether an OS acknowledgement appears and settle it manually
before proceeding. The second invocation for that identity tests persistence
after its process exits, with the same bundle and signature. It must retain all
existing assertions and show no new alert. A repeat prompt needs a narrow
`replayd`/TCC log around that invocation before changing code.

To isolate the legacy pixel read, run
`scripts/verify stageOverlayShowsWithoutFocus` before any capture suite. An alert
here implicates the overlay-only path; the whole-window contract never calls
the legacy API.
After the restart comparison, `scripts/build` followed by the same two capture
tests isolates rebuilding from restarting. Compare designated requirements
locally without printing signing identities or certificate material.
