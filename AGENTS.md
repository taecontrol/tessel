# Project instructions

## Purpose

tessel is a keyboard-first tiling window manager for macOS 27 and later on
Apple silicon. It is driven entirely from the keyboard. When a window is moved
with the mouse, tessel adapts to it, but it offers no mouse or trackpad
interaction of its own.

AeroSpace is a reference, not a target. Do not aim for parity with it or copy
a behavior only because it has it.

The `tessel` CLI is mainly for agents: it lets them observe and test tessel,
and later operate it on the user's behalf.

## How to decide

- Add only what the roadmap (the open issues) asks for. A new feature starts
  as an experiment behind a config flag, and its issue records whether it is
  kept. A kept feature loses its flag. A rejected one loses its code.
- tessel must feel instant and use as little CPU and memory as it can. Prefer
  reacting to system notifications over polling, and do nothing while nothing
  changes.
- Use Swift with Apple's frameworks. Add a dependency only for a concrete
  reason, recorded in an ADR.
- Window classification must be predictable and explainable. The same window
  is classified the same way every time, and tessel can always say why a
  window tiles or floats.

## Signing

Never build or launch an ad-hoc-signed or unsigned app bundle with a tessel
bundle ID (`com.taecontrol.tessel` or `com.taecontrol.tessel.dev`). That
includes Xcode's "Sign to run locally" and running a plain `swift build`
product as the app. One such launch revokes the Accessibility permission, and
macOS may refuse to grant it again. Sign with the identity configured in an
ignored local file, use the `.dev` bundle ID for development, and keep
bundles out of `/tmp`, where LaunchServices does not register them.

## Privacy

This repository is public. Never commit:

- personal configuration, or a list of the apps someone uses
- signing identities, team IDs, certificates, or provisioning profiles
- logs, Accessibility dumps, or screenshots taken on a real machine, unless
  window titles and other personal content have been removed

Examples and fixtures use generic apps and invented titles. Local signing
settings live in ignored files. Everything committed is in English, even when
the conversation is not.

## Verification

For building, launching, or verifying tessel, follow [docs/development.md](docs/development.md).
Use the signed development bundle and isolated fixture harness described there;
keep the local signing identity stable so rebuilds preserve Accessibility.
