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

Build from source with Xcode 27 using [the development guide](docs/development.md).

## Requirements

- Apple silicon
- macOS 27 or later
- The Accessibility permission

## License

[MIT](LICENSE)
