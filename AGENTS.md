# Project instructions

## Purpose

tessel is a keyboard-first tiling window manager for macOS 27 and later on
Apple silicon. It is driven entirely from the keyboard. When a window is moved
with the mouse, tessel adapts to it, but it offers no mouse or trackpad
interaction of its own.

Existing window managers are references, not limits, and matching them is
not a goal. tessel should be the window manager its owner loves to use, so
question what other tools take for granted, including ideas in this
repository's roadmap that only repeat them. When a new idea would serve the
work better than the familiar one, propose it, even if no tool does it yet.
Before adopting how another tool solves a problem, list other ways, including
ones no tool uses yet, test the promising ones on the real system, and choose
by evidence.

The `tessel` CLI is mainly for agents: it lets them observe and test tessel,
and later operate it on the user's behalf.

## How to decide

- tessel works well without a config file. Every setting has a default that
  suits most people; the config changes a default, it never completes the
  setup. An experiment's flag is the only setting a feature may require.
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

CI verifies pull requests and nothing else, in under ten minutes until every
check is green. Before adding CI work that would break that limit, bring the
owner its cost. Diagnose, profile, compare variants, and run exploratory
mutation plans on the local machine. Never dispatch a
workflow or push temporary commits to try something on CI: each run adds noise
to the branch's checks and costs paid runner minutes. When only CI can answer,
such as recalibrating a resource budget, ask the owner first.
