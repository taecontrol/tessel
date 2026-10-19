# ADR-0005: Animate tiled windows through Accessibility

Date: 2026-10-19
Status: Accepted

## Context

The carousel experiment needs short, interruptible motion of other apps' tiled
windows while SIP stays enabled and Accessibility remains the only permission.
A local signed-fixture spike on macOS 27, Apple silicon M1 Pro, at 1728×1117
and 120 Hz measured 10–11 AX position steps in 80 ms. Three to five windows
cost 1–3 ms of AX work per tick; the target app displayed every requested
frame and landed exactly. Size plus position cost 5–7 ms per tick, with up to
about 17 ms overrun. These are fixture measurements, not third-party app
performance guarantees.

SkyLight transforms and alpha writes on other apps' windows from a non-Dock
process returned zero but had no effect; SLSMoveWindow returned 1000. AX moves
work, but macOS clamps a window's top below the menu bar and keeps 32 points
visible at the bottom. A desktop-style vertical slide cannot follow that path.
Horizontally, AX accepts a one-point sliver; a wholly off-screen write snaps back
to 40 points visible.

The closet from ADR-0002 preserves AX identity and accepts position writes,
but hidden size writes can return with reduced height. Returning windows keep
an earlier z-order. AXRaise can reorder background apps without activation,
but cannot reliably outrank the active app's window. AXMain can also change
selection when siblings are raised. Resizing on screen has another constraint:
AX can limit growth against the window's current positive x.

## Decision

Animate tiled windows by stepping AX geometry on demand-driven display frames.
Use one display link while motion needs frames, then invalidate it. Retarget
from confirmed native geometry without queuing animations. Keep at most one
intermediate batch per app, skip late intermediate frames, and always write
and read back the exact landing. Short intermediate AX timeouts keep a busy
app from blocking other apps; preparation and final retries retain normal
AX timeouts. Idle cost remains unchanged: zero display callbacks at rest and
ADR-0003's wakeup, CPU and footprint budgets.

Use a card stack for vertical rail changes. Down brings the incoming rail up
from the 32-point bottom edge, over the current rail, then hides the old rail.
Up reveals the previous rail underneath, lowers the leaving card, then hides
it. Prepare native selection and ordering before moving. Down activates the
incoming focus app first; Up keeps the leaving app active until hide. Select
background windows with AXMain and raise the moving card's windows, with the
active key last; restore AXMain after sibling raises without another activation
or raise. Each moving window gets at most one AXRaise per rail change.

Keep entering and leaving horizontal windows one point on screen until the
landing's closet operation. Place returning windows before showing, size only
on screen, and order resize/position writes according to which origin accepts
the target size. Native readback determines accepted geometry; clipping at a
screen edge must not become an app's intrinsic width limit. Pointer-down
notifications cancel motion before a drag; Reduce Motion makes subsequent
commands instant.

## Consequences

- Real windows and their live contents move without snapshots, Screen Recording,
  Dock injection or another permission. Other apps must service AX calls during
  motion, so busy apps can skip intermediate frames and require final retries.
- Cards fit the native vertical constraints. A vertical desktop translation or
  compositor-only spring is unavailable under the measured process boundary.
- Geometry, selection and CG ordering need distinct confirmation. Preparation
  can consume part of the configured motion duration; final AX completion is
  measured independently of display delivery by native latency. Both workspace
  and carousel retain the 200 ms p95 allowance. The latency suite configures
  carousel duration zero; E16/E17 prove animation timing deterministically.
  A proposed 280 ms animated total based only on local measurements was
  withdrawn during review because recalibration needs the spread on CI's
  runner. Percentiles still cover 100 commands per kind, from key post to final
  visible geometry, AX main/focus and CG visibility; no time is subtracted.
- The private closet dependency remains isolated as in ADR-0002. Demand-driven
  animation adds no periodic idle work. Supported macOS changes must continue
  to satisfy the native contracts below.

## Evidence

The rejected SkyLight operations and AX timing numbers above are the spike's
observations. Maintained signed contracts in
[ContractsMotion.swift](../../Tests/Acceptance/ContractsMotion.swift) pin the
native behavior used by the simulator and presenter:

- `ax-vertical-clamping` and `ax-horizontal-sliver`: menu bar, 32-point bottom,
  one-point horizontal edge and 40-point snapback.
- `closet-ax-identity` and `closet-size-loss`: retained handles, hidden position
  writes, and the need to size after showing.
- `ax-raise-across-applications`: active-app restriction, background AXMain,
  sibling closet return and active-key ordering without stray activation.
- `ax-resize-anchoring`: move left before growing to avoid a false maximum.
- `display-frame-demand`, `reduce-motion-notifications` and
  `pointer-press-notifications`: demand lifecycle and native input notifications.

The mixed-app card journey pins wiring and ordering during motion; the carousel
resource suite verifies zero idle display callbacks and the unchanged resource
limits. Deterministic motion examples pin the spring, retargeting, write/raise
budgets, exact landing and visibility sequencing.

## Alternatives considered

- **SkyLight transforms, alpha or direct moves:** ignored or refused for foreign
  windows by the non-Dock process in the signed spike.
- **Snapshot animation:** requires Screen Recording and stops showing live app
  contents during the transition.
- **Continuously running display link:** adds recurring work at rest without
  helping demand-driven motion.
- **Vertical translation or off-screen parking:** conflicts with AX clamps;
  parking also keeps windows visible to occlusion-aware drawing (ADR-0002).
