# tessel

A keyboard-first tiling window manager for macOS.

tessel is an experiment. It grows one feature at a time: each feature starts
behind a config flag, gets used for real, and is then kept or removed. It aims
to stay fast and light, so it only gains what it actually needs.

## Status

tessel manages ten keyboard-driven workspaces, remembered rails of tiled
windows and a floating layer per workspace. They are active without a config
file. Inactive windows live in a hidden Space; quitting returns them to the
current desktop. The read-only CLI lists windows, their classification and
reason, workspace and rail membership.

Option+H/L visits edge stops without wrapping; Option+K/J moves between rails.
Add Shift to move the window instead. Option+R cycles widths through one third,
one half, two thirds and full. Short rails keep their nominal widths and leave
space to the right. While a mouse button is held, tessel leaves the windows
alone; releasing a resized edge adopts its width and restores the rail height.

Option+Z enters or leaves the floating layer, Option+Shift+Z pins it above the
rails, and Option+F moves a window between rail and layer. Floats start hidden;
a new dialog shows alone. tessel manages standard windows, dialogs, system
dialogs and floating windows at CG layer 0 or the floating level 3, including
utility panels, inspectors and palettes. Other levels and subroles are ignored.

Layout changes animate for 250 ms by moving captures while the windows are
placed underneath. Animations need Screen Recording; without it, with macOS
Reduce Motion, or with `[animation] duration = 0`, changes are instant.
`duration` accepts 0–1000 ms. Workspace switches and sends remain instant.
The former `workspaces`, `carousel` and `layer` experiment keys are accepted
and ignored; future experiments can still use the `[experiments]` table.

Build from source with Xcode 27 using [the development guide](docs/development.md).

## Requirements

- Apple silicon
- macOS 27 or later
- The Accessibility permission
- Screen Recording, only for animations

## License

[MIT](LICENSE)
