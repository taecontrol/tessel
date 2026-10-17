# Features

A comparison of the window managers that inspired tessel, and where each idea
stands. "Idea" means not planned yet: it becomes an issue only when someone
decides to try it.

Sources: [AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide),
[TrellisWM docs](https://trelliswm.app/docs/),
[TileMyMac](https://tilemymac.app/) and the engine it is built on,
[Paneru](https://github.com/karinushka/paneru), and Omarchy's
[hotkeys](https://learn.omacom.io/2/the-omarchy-manual/53/hotkeys) and
[Hyprland config](https://github.com/basecamp/omarchy/tree/master/default/hypr),
as of October 2026.

## Lessons from AeroSpace

- It decides once, when a window appears, whether it floats, partly from
  whether the window's full-screen button is enabled. Apps that enable that
  button late can float one time and tile the next.
- macOS reports each native tab as its own window. Without tab handling, every
  tab gets its own tile, and background tabs leave empty space.

tessel keeps checking a new window for a moment, counts native tabs as one
window, and can explain every classification (#1, #2). Paneru already handles
native tabs.

macOS moves a window that sits entirely off screen onto another display, so
AeroSpace and Paneru hide windows by leaving a thin sliver of each one visible
at a screen edge.

tessel's workspace experiment (#2) instead keeps inactive windows in one hidden
Space, with no sliver. It brings them to the current native desktop when shown.
This uses private SkyLight operations; see [ADR 0002](adr/0002-hide-inactive-windows-in-a-skylight-space.md).
Paneru combines native Spaces with virtual rows whose inactive windows are
parked in a strip. TileMyMac uses Paneru's engine and exposes numbered rows.

## Comparison

| Feature | AeroSpace | TrellisWM | TileMyMac / Paneru | Omarchy (Hyprland) | On macOS | tessel |
|---|---|---|---|---|---|---|
| Tiling model | Manual i3-style tree | Docking by dragging | Scrolling strip | Dwindle: automatic spiral splits | Accessibility API | #3 |
| Scrolling columns layout (niri-style) | — | — | Yes, one strip per display | Per workspace | Feasible | #7 |
| Floating workspace | — | "Float all" | — | Per workspace | Feasible | Idea |
| Accordion or tabs | Accordion | Tab groups across apps | Stack windows in a column | Groups with a tab bar | Tab bar needs its own overlay | #5 |
| Nested groups, step in and out | Nesting by hand | Nested spaces with a camera | Stacked rows (experimental, Paneru) | — | Feasible | #5 |
| Zoom into one window | Full screen | Frame window | Fill the screen | Tiled full screen | Feasible | #4 |
| Directional focus, move, swap | Yes | — (mouse) | Left and right | Yes | Feasible | #3 |
| Resize from the keyboard | Smart resize | — | Cycle ½, ⅔, full | Three step sizes | Feasible | Idea |
| Balance sizes | Yes | — | — | — | Feasible | Idea |
| Numbered workspaces | Yes, emulated | Nested spaces | Native Spaces plus virtual rows parked in a strip | 1–10 | Hidden Space or off-screen parking | Hidden Space (#2) |
| Send window to workspace | Yes | — | Native Spaces and virtual rows | With or without following | Feasible | #2 |
| Previous workspace, next and previous | Back and forth | Back and forward history | Native Spaces | Both | Feasible | Idea |
| Move workspace to another monitor | Yes | Per display | — | By direction | Feasible | Idea |
| Pin a workspace to a monitor | Yes | — | — | Through rules | Feasible | Idea |
| Scratchpad | — | — | — | Yes | Feasible | Idea |
| Pop out: float and show on every workspace | — | — | — | Yes | Feasible | Idea |
| Full screen, full width | Full screen | Frame window | Fill the screen | Both | Feasible | Idea |
| Toggle floating and tiling | Yes | Green button | — | Yes | Feasible | Idea |
| Per-app rules (workspace, floating) | Yes | Exclude an app | Yes (Paneru) | Yes | Feasible | Idea |
| Gaps | Yes | — | — | Yes, with a toggle | Feasible | #2 |
| Active window border | — | — | — | Gradient border | Needs its own overlay | Idea |
| Layout animations | — | 460 ms, drawn from snapshots | — | Bezier curves | Hard: moving windows through Accessibility is slow | Idea |
| Overview of everything | — | Yes | — | — | Needs Screen Recording | Idea |
| Saved views | — | Nine | — | Saved window width | Feasible | Idea |
| Layout survives restarts | — | Yes | Yes (Paneru) | Per workspace | Feasible | Idea |
| Cycle windows in a workspace | — | — | — | Alt+Tab | Feasible | #2 |
| Transparency for other apps' windows | — | — | — | Yes | Not without disabling SIP | No |
| Modifier plus drag to move or resize | — | Plain dragging | Swipe to slide the strip | Yes | Event tap | No: keyboard only |
| Binding modes | Yes | — | — | — | Feasible | Idea |
| CLI, socket, events | Yes | URL commands | — | hyprctl | Feasible | CLI (#1); events: Idea |
| Layout chosen per workspace | — | — | — | Yes | Feasible | #3, #7 |
| Center a window | — | — | Yes | — | Feasible | Idea |
| Copy a rule for the focused window | — | — | Yes (Paneru) | — | Feasible | Idea |
| Native macOS tabs as one window | — | — | Yes (Paneru) | — | Feasible | #2 |
| Configuration | TOML, reloads on save | Settings window | Settings window; Lua in Paneru | Lua | — | TOML (#1) |
