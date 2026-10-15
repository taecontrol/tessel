# Features

A comparison of the window managers that inspired tessel, and where each idea
stands. "Idea" means not planned yet: it becomes an issue only when someone
decides to try it.

Sources: [AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide),
[TrellisWM docs](https://trelliswm.app/docs/), and Omarchy's
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
window, and can explain every classification (#1, #2).

## Comparison

| Feature | AeroSpace | TrellisWM | Omarchy (Hyprland) | On macOS | tessel |
|---|---|---|---|---|---|
| Tiling model | Manual i3-style tree | Docking by dragging | Dwindle: automatic spiral splits | Accessibility API | #3 |
| Scrolling columns layout (niri-style) | — | — | Per workspace | Feasible | Idea |
| Floating workspace | — | "Float all" | Per workspace | Feasible | Idea |
| Accordion or tabs | Accordion | Tab groups across apps | Groups with a tab bar | Tab bar needs its own overlay | #5 |
| Nested groups, step in and out | Nesting by hand | Nested spaces with a camera | — | Feasible | #5 |
| Zoom into one window | Full screen | Frame window | Tiled full screen | Feasible | #4 |
| Directional focus, move, swap | Yes | — (mouse) | Yes | Feasible | #3 |
| Resize from the keyboard | Smart resize | — | Three step sizes | Feasible | Idea |
| Balance sizes | Yes | — | — | Feasible | Idea |
| Numbered workspaces | Yes, emulated | Nested spaces | 1–10 | Emulated, windows parked off screen | #2 |
| Send window to workspace | Yes | — | With or without following | Feasible | #2 |
| Previous workspace, next and previous | Back and forth | Back and forward history | Both | Feasible | Idea |
| Move workspace to another monitor | Yes | Per display | By direction | Feasible | Idea |
| Pin a workspace to a monitor | Yes | — | Through rules | Feasible | Idea |
| Scratchpad | — | — | Yes | Feasible | Idea |
| Pop out: float and show on every workspace | — | — | Yes | Feasible | Idea |
| Full screen, full width | Full screen | Frame window | Both | Feasible | Idea |
| Toggle floating and tiling | Yes | Green button | Yes | Feasible | Idea |
| Per-app rules (workspace, floating) | Yes | Exclude an app | Yes | Feasible | Idea |
| Gaps | Yes | — | Yes, with a toggle | Feasible | Idea |
| Active window border | — | — | Gradient border | Needs its own overlay | Idea |
| Layout animations | — | 460 ms, drawn from snapshots | Bezier curves | Hard: moving windows through Accessibility is slow | Idea |
| Overview of everything | — | Yes | — | Needs Screen Recording | Idea |
| Saved views | — | Nine | Saved window width | Feasible | Idea |
| Layout survives restarts | — | Yes | Per workspace | Feasible | Idea |
| Cycle windows in a workspace | — | — | Alt+Tab | Feasible | Idea |
| Transparency for other apps' windows | — | — | Yes | Not without disabling SIP | No |
| Modifier plus drag to move or resize | — | Plain dragging | Yes | Event tap | No: keyboard only |
| Binding modes | Yes | — | — | Feasible | Idea |
| CLI, socket, events | Yes | URL commands | hyprctl | Feasible | Idea |
| Configuration | TOML, reloads on save | Settings window | Lua | — | TOML (#1) |
