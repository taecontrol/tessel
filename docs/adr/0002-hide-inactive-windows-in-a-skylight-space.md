# ADR-0002: Hide inactive windows in a SkyLight Space

Date: 2026-10-16
Status: Accepted

## Context

The workspace experiment needs to hide individual windows instantly while SIP
stays enabled. An off-screen sliver still counts as visible to macOS and lets
occlusion-aware apps keep drawing. Local fixture measurements found about
117 ms of CPU per second for such a window. Minimizing takes about 600 ms;
hiding an app cannot separate its windows. A virtual display accepts the cursor
and can attract the Dock. Direct SkyLight writes to foreign windows returned
success without changing them.

## Decision

Use one invisible native Space as a closet for inactive windows. SkyLight's
bridged operations move individual windows into it and return them to the
currently visible Space without switching native desktops. Local probes with
SIP enabled measured roughly 2.5 ms per move and confirmed that the windows
become occluded while remaining accessible through AX. Signed fixture probes
also verified the operations on the macOS 27 CI runner.

This private system framework is accepted only for the experiment. Its use is
isolated behind a hide/show boundary, resolved dynamically, and gated by the
workspaces or carousel flag. Both experiments use the same hiding boundary; rail
windows that are fully outside the display enter the closet instead of being
parked off screen. The floating layer, which requires the carousel, hides the
active workspace's floating windows through the same boundary. Missing classes or methods disable the experiment with a
visible reason; there is no automatic alternative hiding mechanism.

## Consequences

- Inactive windows have no visible strip and can throttle drawing when occluded.
- macOS may change or remove this undocumented API. Compatibility must be
  verified on supported OS updates, and the adapter may need replacement.
- Normal shutdown or disabling the experiment returns managed windows and
  destroys the closet. Startup recovers orphaned windows without persisted IDs,
  even with the experiment disabled. A crash can leave one empty invisible Space;
  finding and removing that empty Space is outside the experiment.
- Native fullscreen windows must never enter the closet. Other monitors are
  outside this experiment's management scope.
- Accessibility remains the only required permission. No package dependency,
  Dock injection, SIP change, or screen recording permission is introduced.

## Alternatives considered

- **Off-screen parking:** leaves a sliver and keeps windows visible to occlusion.
- **Minimize:** incurs the native Dock animation and changes minimized state.
- **App hide:** cannot hide one window while showing another from the same app.
- **Virtual display:** exposes another display to the cursor, Dock, and system UI.
- **Direct foreign-window writes:** had no effect with SIP enabled in the probes.
