# ADR-0007: Capture only windows that are drawn

Date: 2026-10-22
Status: Accepted

## Context

ADR-0006 moves carousel windows through ScreenCaptureKit screenshots on a
stage. It measured captures about 14 ms apart and motion starting 93–140 ms
after the key. A day later, on the same macOS build (27.0.1), motion started
about 500 ms after the key.

Measured on the owner's Mac:

- **replayd takes screenshots one at a time.** Each one makes two TCC checks.
  It then marks the client as recording and waits for systemstatusd to publish
  that to the menu bar's recording indicator. Only then does it capture, in
  about 3 ms.
- **Publishing got slower all day.** The median time per screenshot rose from
  45 ms to 140 ms. The publish part rose from 21 ms to 76 ms.
- **The cause was leaked attributions.** Over the day, ControlCenter's list of
  apps actively recording grew from 4 to 10 entries for the development
  build. None of those processes was still running. Each publish carries the
  whole list.
- **Every leak had the same trigger.** A screenshot was taken of a window that
  stopped drawing, and it closed 90–200 ms later. The SkyLight stream inside
  replayd never delivered a frame or stopped. The screenshot never completed,
  and its attribution never ended.
- **The leak reproduces.** A screenshot of a window that has ordered out, as
  AppKit does first when it closes a window, never returns. Its attribution
  outlives the client and the window. One leaked entry raised three captures
  from about 155 ms to 205 ms.
- **Only a replayd restart clears the leak.** After a restart the list was
  empty, and three captures took about 155 ms again, down from 480 ms.
- **ScreenCaptureKit gives no way to cancel a screenshot.** Killing the client
  does not end the attribution.

Window managers close windows mid-move all the time: the next window takes
focus as one closes, and the carousel moves to it.

## Decision

The stage captures a window only while WindowServer draws it: when
WindowServer lists it on screen, or when it rests in tessel's closet. A window
listed off screen in an ordinary Space is ordering out or belongs to a hidden
app. The stage does not capture it, and it needs no stand-in, because nothing
of it shows.

The stage stops waiting for any screenshot after 1 s and places the windows at
once. It does not retry a window whose screenshot timed out.

The check cannot close two remaining races:

- **A window closes while its capture waits.** It passes the check and then
  closes while its capture is queued in replayd.
- **The window's app does not answer.** A screenshot makes the window's app
  update its window-sharing state, so a busy app can keep the frame from
  arriving until the window closes.

Both were seen once in the fixture journeys after this change. Before it,
fixture teardowns leaked about six attributions a day.

## Alternatives considered

- **One short-lived `SCStream` per capture:** it is leak-proof, because tessel
  stops it. But a window stream makes the captured app's AppKit start sharing
  the window. It creates an `NSLocalWindowSharingWindow` and a sharing button
  in the title bar, then closes them, and the stage contract's AX reads of the
  window failed intermittently. Screenshots do none of this.
- **One stream retargeted for each image:** each update still pays TCC, and
  three images took about 290 ms.
- **`CGWindowListCreateImage`:** about 18 ms per capture, and it returns at
  once for a window that has ordered out. But Swift hides it since macOS 15,
  and the recording indicator lingers about 20 s after the last capture.
  The owner preferred ScreenCaptureKit for that reason (ADR-0006).
- **Taking the screenshots one at a time, each checked just before its
  request:** this would narrow the first race. But it doubled the capture phase
  of a four-image move, from about 120 ms to about 230 ms, because tessel's
  share of each request no longer overlaps replayd's.
- **Keeping the screenshots and only adding the timeout:** tessel stays
  responsive, but every closed window could still leak an attribution, so
  motion starts later each day until the Mac restarts.

## Consequences

- A window closing during a move gets no stand-in. The move still animates
  the others.
- A screenshot that never completes delays the move by at most 1 s, and that
  move is instant.
- The stage needs to know which windows are in the closet, so it asks the
  SkyLight closet. That is still tessel's only SkyLight boundary.
- Any attributions leaked before this change stay until replayd restarts or
  the Mac logs out.
- The stage contract pins the closet and off-screen facts this check relies
  on. It never takes a screenshot of a window that is not drawn, because that
  would leak an attribution on the test machine.
- The remaining race and replayd's per-capture cost are macOS behaviors to
  report to Apple. Removing them depends on macOS changing.
