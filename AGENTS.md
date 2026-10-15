# Project instructions

## Purpose

tessel is a keyboard-first tiling window manager for macOS 27 and later on
Apple silicon. It is driven entirely from the keyboard. When a window is moved
with the mouse, tessel adapts to it, but it offers no mouse or trackpad
interaction of its own.

## How to decide

- Add only what the roadmap asks for. A new feature starts as an experiment
  behind a config flag, and its issue records whether it is kept. A kept
  feature loses its flag. A rejected one loses its code.
- tessel must feel instant and use as little CPU and memory as it can. Prefer
  reacting to system notifications over polling, and do nothing while nothing
  changes.
- Use Swift with Apple's frameworks. Add a dependency only for a concrete
  reason, recorded in an ADR.
- Window classification must be predictable and explainable. The same window
  is classified the same way every time, and tessel can always say why a
  window tiles or floats.

## Privacy

This repository is public. Never commit:

- personal configuration, or a list of the apps someone uses
- signing identities, team IDs, certificates, or provisioning profiles
- logs, Accessibility dumps, or screenshots taken on a real machine, unless
  window titles and other personal content have been removed

Examples and fixtures use generic apps and invented titles. Local signing
settings live in ignored files.
