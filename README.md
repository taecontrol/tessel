# tessel

A keyboard-first tiling window manager for macOS.

tessel is an experiment. It grows one feature at a time: each feature starts
behind a config flag, gets used for real, and is then kept or removed. It aims
to stay fast and light, so it only gains what it actually needs.

## Status

The current foundation is a menu bar observer and a read-only `tessel` CLI.
It lists windows with their classification and reason, preserves Accessibility
across signed rebuilds, and reloads its TOML config on save. The
[roadmap](https://github.com/taecontrol/tessel/issues) tracks the tiling experiments;
[docs/features.md](docs/features.md) compares the window managers that inspired them.

The optional `[experiments] workspaces = true` experiment adds ten keyboard-driven
workspaces, one tiled window at a time, with configurable gaps and shortcuts.
Inactive windows live in a hidden Space; disabling the flag or quitting returns
them to the current desktop. The CLI remains read-only.

The optional `[experiments] carousel = true` experiment arranges each workspace
as remembered rows of windows. Option+H/L visits edge stops without wrapping;
Option+K/J moves between rows. Add Shift to move the window instead.
Option+R cycles widths through one third, one half, two thirds and full.
Short rows stretch to fill the area. A window keeps its width at either end of
a row. Fully off-screen windows use the same hidden Space.
Carousel enables workspaces by itself. Layout changes animate for 250 ms by moving
window captures while the windows are placed underneath, which needs Screen
Recording; without it, or with macOS Reduce Motion, changes are instant.
`[animation] duration` accepts 0–1000 ms. Workspace switches and sends remain instant.

The optional `[experiments] layer = true` experiment enables carousel with a
floating layer per workspace. Option+Z enters or leaves it, Option+Shift+Z pins
it above the rails, and Option+F moves a window between rail and layer. Floats
start hidden; a new dialog shows alone. Independently of this flag, tessel now
ignores non-window surfaces such as popups, system alerts, widgets and
status-level windows.

Build from source with Xcode 27 using [the development guide](docs/development.md).

## Requirements

- Apple silicon
- macOS 27 or later
- The Accessibility permission
- Screen Recording, only for the carousel experiment's animations

## License

[MIT](LICENSE)
