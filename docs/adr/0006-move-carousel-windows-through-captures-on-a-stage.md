# ADR-0006: Move carousel windows through captures on a stage

Date: 2026-10-20
Status: Accepted

## Context

ADR-0005 animated the carousel by stepping other apps' windows through
Accessibility on display frames. On the owner's Mac (macOS 27, M1 Pro, 120 Hz
built-in display), it did not look natural. The owner measured it against the
native Space switch, which moves at display rate with no ease-in. Two attempts
failed:

- **The 80 ms spring:** a single 120 Hz frame crosses about 28% of the travel,
  so nothing can make it look continuous.
- **A 600 ms native-fit curve through AX:** the owner judged it worse than
  80 ms, with every app. The four symptoms:
  - jerks;
  - windows out of step, because each app applies writes on its own schedule;
  - content relayout while moving;
  - the wrong rhythm.

A longer motion only exposed those flaws for longer.

**The demo.** A separate signed process animated window captures in its own
overlay and moved the real windows once underneath, using the owner's real
windows. The owner called it "natural and fast" and, after iterating on it,
chose:

- 250 ms;
- a launched curve that settles within the duration;
- for a resize, the old capture kept at its scale, cropped or uncovered at the
  edge, then crossfaded to the new capture once the app has redrawn;
- a vertical slide of both rails as one sheet for a rail change, over cards.

Measured with the demo on the owner's Mac:

- **Every capture method lights the menu bar's recording indicator.** That
  includes the private SkyLight capture. It is a privacy control and is not to be
  hidden. After the last capture, ScreenCaptureKit's indicator goes out in about
  4 s; `CGWindowListCreateImage` and SkyLight's take about 11 s. The owner did
  not notice the ScreenCaptureKit indicator.
- **ScreenCaptureKit returns the whole window from wherever it is**, including
  partly off screen and in the SkyLight closet. SkyLight's capture returns only
  the on-screen part.
- **ScreenCaptureKit captures are serial**, about 14 ms apart. For a strip of
  four windows plus the background, motion began 93–140 ms after the key. A
  rail change began 100–130 ms after it, and up to 230 ms on the first,
  cold capture.
- **App activation takes 10–27 ms.**
- **ScreenCaptureKit returns YCbCr (`420v`) unless asked for BGRA**, without
  the window's transparent corners.
- **A full-resolution capture is large:** about 14 MB per 849×1064 pt window at
  2×, and about 31 MB for the display. That is above tessel's idle footprint
  budget (ADR-0003).

## Decision

The carousel moves windows on a stage, tessel's own click-through overlay at
floating level, below the menu bar.

**What moves.**

- An animated layout change captures, with ScreenCaptureKit, every window seen
  at its start or end, plus what lies under the area without them.
- It shows those captures where the windows are, then moves them along the
  curve over the configured duration, 250 ms by default.
- Under the stage, the ordinary presenter places each real window once: closet,
  position, size and focus. No app has to keep up with the motion.

**When the real windows move.** Only once WindowServer has drawn the overlay,
read from one point of tessel's own window, and at most 150 ms after the
commit. Listing the overlay is not drawing it: on the owner's Mac the draw
took 40–65 ms about half the time.

**When the stage clears.** It clears when every stand-in is within 1.5 pt of
rest, every placement is confirmed, and WindowServer lists each placed window
at its accepted frame and each closeted one off screen. It then fades into the
real windows over 40 ms. In any case it clears 300 ms after settling.

**Focus.**

- Focus is requested first.
- The focus look changes when the stage fades into the real windows; the
  captures are not retaken for it.
- A placement that supersedes an unconfirmed focus request carries that focus
  forward.

**Repeated commands** retarget the stand-ins from where they are on screen and
keep their speed: toward the new rest, the faster of the speed they have and
the launch; away from it, the launch turns them around. A window first seen by
a retarget joins the motion when its capture arrives.

**Stand-ins look like their windows.** Captures are BGRA, so each carries the
window's transparent corners; the stand-in measures its corner radius from
them and draws its shadow along a path of that radius.

**Resizing.** A stand-in keeps its capture's scale, anchored top-left. When
the window grows, the band it uncovers takes the window's edge colour. Once
the app accepts the new size, the stand-in crossfades to a capture at that
size. An app's accepted size is learned as before, and the stand-ins retarget
to it.

**Parked tiles.** A tile shown by less than a point rests in the closet: AX
accepts a position a rounding error inside the edge, and macOS later pulls the
window back to show 40 points.

**Other changes.**

- **Rail changes** slide both rails as one sheet, one rail height apart.
- **A wall bounce** moves the stand-ins a short distance away from the wall and
  back, 70 ms each way. Real windows do not move.
- **A pointer press, fullscreen entry, disabling, or a layout change** clears
  the stage at once.

**Motion is off, and every change is instant,** when:

- the duration is zero;
- Reduce Motion is on;
- Screen Recording is not granted. tessel asks for it once, the first time a
  change would animate.

`status --json` reports the reason in `workspaces.motion`.

**Nothing at rest.** No pixels are kept: every capture is taken at the command
and released when the stage clears. The overlay stays ordered in at rest, empty
and transparent, so a show draws without ordering it in again.

## Alternatives considered

- **AX stepping, ADR-0005:** the owner rejected it twice on the real system. The
  window desync and relayout are properties of the technique.
- **Paneru's approach:** AX every tick, `AXEnhancedUserInterface` turned off
  around writes, an exponential ease-out. It is the same technique.
- **`CGWindowListCreateImage` or SkyLight captures:** faster to start, about
  60–70 ms. The recording indicator then stays about 11 s after each move, and
  the owner preferred ScreenCaptureKit.
- **Captures kept at rest for a faster start:** above the idle footprint budget.
- **Stretching or proportional scaling while resizing:** the owner preferred
  cropping, which never distorts text.
- **Cards for rail changes, as in ADR-0005:** the owner preferred the slide,
  which AX could not do because of the vertical clamps.
- **A stand-in for every window from the start:** costs a capture each, about
  14 ms, for windows that are never seen.

## Consequences

- The carousel's motion needs Screen Recording. Without it, the carousel works
  with instant changes. macOS may ask to confirm the grant monthly.
- Motion starts about 100 ms after the key, and up to about 230 ms on the
  first, cold capture. That is the cost of ScreenCaptureKit's serial captures.
- Content is frozen while it moves, for about 250 ms. The real window appears
  when the stage clears.
- Window shadows are drawn by the stage, not by WindowServer.
- The primary display only, as before. A Space change during motion is not
  handled yet beyond the pointer, fullscreen and disable cases.
- The 300 ms limit bounds how long a slow app's frozen capture can stay on
  screen.
- New simulator assumptions, each pinned by a signed contract:
  `screen-recording-preflight`, `stage-whole-window-capture` and
  `stage-overlay`. `display-frame-demand` is retired with the display link.
  The stage contracts need Screen Recording for the signed fixture observer.
- This supersedes ADR-0005's animation, vertical cards and display-link
  decisions. Its findings about AX clamps, closet identity, resize anchoring
  and pointer interruption still hold, and the presenter still relies on them.
