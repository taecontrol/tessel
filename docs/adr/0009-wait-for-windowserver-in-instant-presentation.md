# ADR-0009: Wait for WindowServer in instant presentation

Date: 2026-10-23
Status: Proposed

## Context

Accessibility readback confirms geometry an app accepted, before WindowServer
lists the app's next commit. Native fixture measurements on macOS 27 found
4–22 ms between acceptance and listing, with none of 60 placements listed at
the readback boundary. Stopping the app immediately after its reply kept the
old listing in all 12 trials, for up to 500 ms. Resuming it produced the new
listing 1–17 ms later. A window in the SkyLight closet also acquired its new
listing before being shown.

Instant presentation used AX acceptance to retire departing windows and show
returning ones in the same main-queue turn. Closet visibility changed before
the replacement's geometry commit, exposing desktop or an old frame for one
or two display frames. The simulator hid this gap by serving AX geometry
immediately. An 8 ms app commit exposed stop, close and layer-exit handoffs.
WindowServer drawing what it lists on its next frame is already the stage's
working assumption in [ADR-0006](0006-move-carousel-windows-through-captures-on-a-stage.md).

## Decision

Keep AX readiness and add a bounded WindowServer confirmation before changing
visibility. A departure waits for every covering replacement to be in place
and listed on screen within one point of its AX-accepted frame. A return waits
for the same geometry confirmation on any Space, including the closet.
Unchanged returns follow the same rule. Focus follows the show.

Recheck only waiting windows, in one batch every 4 ms, and release each wait
at 100 ms even if the listing is missing or stale. The limit accommodates
measured live-app commits, including the 30–60 ms delays in pixel evidence,
without leaving windows indefinitely in the closet when an app stops
committing. Cancellation and completion leave no listing work at rest.

This amends #33 E18 to judge the app-committed view and attribute exposure after
the limit to the app until it commits. A geometry burst excuses only its own
listed intermediate frames while listed, never its initial frame. #35 accepts
the remaining right-tile width-change and opening residue: AppKit's separate
AX position and size writes can each commit while the window is visible, and
`AXFrame` is not settable. Waiting cannot make those app commits atomic.

## Consequences

- Stop crossings, close and layer exit no longer retire their covering view
  merely because AX answered. Returns can be prepared and confirmed hidden.
- A normal handoff adds at most the next 4 ms recheck after an app commit;
  a noncommitting app pays the 100 ms limit. Existing latency and idle resource
  budgets remain unchanged.
- A single window wait costs at most 26 batched listing rechecks; serial
  placement dependencies can require more in one transition. There is no public
  notification for this WindowServer state, so bounded polling follows the
  stage's precedent rather than introducing a private notification dependency.
- The simulator must maintain an app-committed view separately from AX facts.
  Its default 8 ms commit, 0/20 ms variants and hung/busy deferral are pinned by
  the `window-server-listing` signed native contract, following
  [ADR-0004](0004-verify-policy-against-a-simulated-macos.md). Real pixel,
  latency and resource evidence remains local under
  [ADR-0008](0008-gate-real-system-changes-on-local-evidence.md).

## Alternatives considered

- **Keep the AX-only handoff:** measurements and the served-view oracle expose
  the visibility gap it cannot observe.
- **Require confirmation without a limit:** a stopped app never commits, so
  departures or returns can remain stranded indefinitely.
- **An atomic AX frame write:** native AppKit windows do not support it. The
  accepted visible intermediate-frame residue remains a platform constraint.
