<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/tessel-lockup-dark.svg">
    <img src="docs/brand/tessel-lockup.svg" alt="Tessel" width="385" height="91">
  </picture>
</h1>

<p align="center">A keyboard-first tiling window manager for macOS</p>

Tessel arranges your windows for you and lets you move between them with the
keyboard. You never drag a window into place or hunt for one behind the
others. Each window sits in a row next to its neighbors, and a key press takes
you to the next one.

Tessel is young and grows one feature at a time. A new feature starts as an
experiment you turn on in the config file. It stays only if it proves useful
in daily work, and then it's on for everyone.

## How Tessel arranges windows

Tessel organizes windows with three ideas.

**Workspaces.** You have ten workspaces, numbered 1 to 10. Only one is on
screen at a time. Tessel doesn't minimize the windows of the other
workspaces or push them off screen. It moves them to a hidden macOS Space, and
brings them back when you switch to their workspace.

**Rails.** Inside a workspace, windows sit side by side in a horizontal row
called a rail. A rail can be wider than the screen. When it is, it scrolls
sideways like a carousel, and windows at the edges may be cut off. A workspace
can have several rails stacked one above the other. You see one rail at a
time, and switching rails slides the screen up or down, much like switching
macOS Spaces.

**The floating layer.** Dialogs, panels, and windows that can't be resized
don't belong on a rail. They float instead, in a layer above the rails. Each
workspace has its own floating layer. It stays hidden while you work on the
rails, and you show it with a key.

Here is one workspace with two rails. The screen shows part of rail 1:

```
          ┌──────── screen ────────┐
rail 1   [│ Editor    │ Browser    │ Terminal ]
          └────────────────────────┘
rail 2   [ Mail      │ Calendar ]
```

From the editor, Option+L focuses the browser, and pressing it again scrolls
the rail to bring the terminal on screen. Option+J slides down to rail 2.

## Getting started

Tessel needs Apple silicon and macOS 27 or later.

There is no download yet. To use Tessel, build it from source with Xcode 27.
[The development guide](docs/development.md) explains how to set up code
signing and run `scripts/build --variant daily`, which produces `Tessel.app`.
Move it to `/Applications` or `~/Applications` and open it.

On first launch, macOS asks you to give Tessel the Accessibility permission,
which lets it move and resize other apps' windows. Grant it in System Settings
under Privacy & Security. Tessel can't manage any window without it.

Screen Recording is optional. Tessel uses it only to animate layout changes:
it slides pictures of your windows while it moves the real ones underneath.
Without it, windows jump to their new places instead of sliding.

When Tessel starts, it puts every window you already have open on the first
rail of workspace 1, at the width each window already had. From then on, each
new window joins the rail you're on, to the right of the focused window, at
full screen width, or as wide as its app allows.

The first time you open Tessel from Applications, it adds itself to your
login items. To turn that off, use **Open at Login** in its menu bar menu.
Choose **Quit Tessel** in the same menu to quit. When Tessel quits, it brings
every window from every workspace back to your current desktop, so no window
stays hidden.

## Keys

Tessel works without a config file. These are the default keys. The Shift
version of a key usually moves the focused window instead of only moving
focus.

| Key | What it does |
|---|---|
| Option+H, Option+L | Focus the window to the left or right on the rail |
| Option+Shift+H, Option+Shift+L | Swap the focused window with its left or right neighbor |
| Option+K, Option+J | Go to the rail above or below |
| Option+Shift+K, Option+Shift+J | Move the focused window to the rail above or below |
| Option+R | Change the focused window's width |
| Option+1 … Option+0 | Go to workspace 1 to 10, where 0 means workspace 10 |
| Option+Shift+1 … Option+Shift+0 | Send the focused window to workspace 1 to 10, and go with it |
| Option+Tab | Go back to the window you used before this one |
| Option+Z | Show or hide the floating layer |
| Option+F | Move the focused window between its rail and the floating layer |

Keys refer to key positions on a US keyboard, so they stay in the same place
with any keyboard layout.

### Moving along a rail

Option+L focuses the next window to the right that is fully on screen. When
no fully visible window is left in that direction, the rail scrolls until the
next window's edge lines up with the edge of the screen. Keep pressing to work
through the rail. At the end of the rail, the rail bounces to show there's
nothing further, and focus stays where it is. Rails don't wrap around to the
other end. Option+H works the same way to the left.

Each rail remembers where it was scrolled and which window had focus, so
going to another rail and back returns you to the same place.

### Widths

Option+R cycles the focused window through one third, one half, two thirds,
and the full width of the screen. If an app refuses a width, Tessel skips to
the next width the app accepts. If the windows on a rail don't fill the
screen, they start at the left edge and leave empty space on the right.

### Making and removing rails

There's no command to create a rail. Move a window past the last rail with
Option+Shift+J, or above the first with Option+Shift+K, and Tessel makes a
new rail for it. When a rail loses its last window, the rail goes away.

### The floating layer

Option+Z shows the floating windows of the current workspace over the rails
and focuses the one you used last. While the layer is showing,
Option+H/J/K/L cycles through its windows, and wraps around at the end.
Press Option+Z again to hide the layer and return to the rail, where you left
it. If the workspace has no floating windows, Option+Z does nothing.

A new dialog appears on its own, over the rails, and takes focus. When you
close it, you're back on the rail. If you reach a hidden floating window
another way, with Cmd+Tab or the Dock for example, Tessel shows the layer.

Option+F on a window on a rail moves it to the floating layer, centered at
half the screen's width and two thirds of its height. Option+F on a floating
window puts it on the current rail, at the width closest to its size. Tessel
remembers that choice for as long as the window exists.

### Going back with Option+Tab

Option+Tab takes you to the window you used before the current one. It
crosses workspaces, and it includes floating windows. Press it again to
return. Use it to go back and forth between two windows, like an editor and a
browser that sit on different workspaces.

### Using the mouse

Tessel has no mouse commands of its own, but you can still use the mouse.
While you hold a mouse button down, Tessel leaves windows where they are and
ignores its own keys. If you resize a window by dragging its edge, Tessel
keeps the new width when you let go, and restores the rail's height.

## What tiles and what floats

Tessel decides with the same rules every time, so the same window always ends
up in the same place:

- A standard, resizable window goes on a rail.
- Dialogs, system dialogs, floating panels, and windows that can't be resized
  float. Floating panels include inspectors, palettes, and similar utility
  windows.
- Everything else, such as menus, popovers, notifications, and desktop
  widgets, is ignored. Tessel doesn't move it.

An app's native tabs count as one window.

To find out why a window tiles, floats, or is ignored, ask Tessel with
`tessel windows`. See [The `tessel` command](#the-tessel-command).

## Configuration

You don't need a config file. To change a default, create
`~/.config/tessel/tessel.toml`. If you set `XDG_CONFIG_HOME`, Tessel looks for
`$XDG_CONFIG_HOME/tessel/tessel.toml` instead. Tessel reloads the file each
time you save it, so there's nothing to restart. If the file has an error,
Tessel keeps the last configuration that worked, and `tessel status` shows
the line that's wrong.

This example shows every setting. The values under `[gaps]`, `[animation]`,
`[experiments]` and `[map]` are the defaults. Under `[keys]`, list only the
keys you want to change; the others keep their defaults.

```toml
[keys]
# Rebind a key: "modifiers-key" = "command".
# Modifiers are alt, which is Option, shift, ctrl and cmd.
# Keys are letters, digits and tab.
alt-r = "cycle width"
# An empty command turns a default key off.
alt-tab = ""

[gaps]
# Space between windows and around the screen's edges, in points.
outer = 10

[animation]
# How long layout changes take, in milliseconds, from 0 to 1000.
# 0 turns animations off.
duration = 250

[experiments]
# Show a small map of the workspace's rails after each Tessel key.
map = false

[map]
# How long the map stays on screen, in milliseconds, from 100 to 5000.
duration = 1000
```

The commands you can bind are:

- `focus left`, `focus right`, `focus up`, `focus down`
- `move left`, `move right`, `move up`, `move down`
- `focus next` and `focus previous`, which move focus along the rail
- `focus recent`, the Option+Tab command
- `workspace 1` to `workspace 10`
- `send 1` to `send 10`
- `cycle width`
- `toggle layer`, the Option+Z command
- `toggle float`, the Option+F command

Animations also turn off when you turn on Reduce Motion in macOS. Switching
or sending to another workspace never animates.

Settings under `[experiments]` turn on features that are still being tried.
Each one may be kept and turned on for everyone, or removed. Older versions
had `workspaces`, `carousel`, and `layer` experiments. Those features are now
always on, and Tessel ignores those keys.

## The `tessel` command

The `tessel` command line tool reads Tessel's state. It doesn't change
anything. It lives inside the app at `Tessel.app/Contents/MacOS/tessel`. To
type `tessel` from anywhere, link it into a folder on your `PATH`, for
example:

```sh
ln -s /Applications/Tessel.app/Contents/MacOS/tessel ~/.local/bin/tessel
```

`tessel windows` lists every window Tessel sees, whether it tiles, floats, or
is ignored, and why. `tessel status` shows Tessel's version, whether it has
the Accessibility permission, whether it opens at login, and which config file
it loaded. Add `--json` to either command for the full details, including
each window's workspace and rail.

`tessel log` prints what Tessel did recently and why: the keys it received,
the windows it placed, config reloads, errors, and crash reports. It shows the
last hour by default. Use `--last` to choose another span in minutes, hours,
or days, such as `--last 30m`, `--last 6h`, or `--last 2d`. Add `--json` for
structured entries. The log works even after Tessel has quit or crashed, which
makes it the first place to look when something went wrong.

The log names apps but never records window titles. Still, read a log before
you share it publicly, and remove anything personal.

## Development

To build Tessel, run its tests, or work on it, follow
[the development guide](docs/development.md).

## License

The code is licensed under [MIT](LICENSE). The Tessel name and logo are not
covered by the MIT license; see [the brand assets](docs/brand/README.md).
