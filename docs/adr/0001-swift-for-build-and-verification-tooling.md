# ADR-0001: Use Swift for build and verification tooling

Date: 2026-10-16
Status: Accepted

## Context

tessel is written in Swift with Apple's frameworks, and the project's agent
instructions ask for that. The foundation (#8) nonetheless shipped its build
script and acceptance harness in Python's standard library, about a thousand
lines, with no recorded reason. That left contributors and agents working in two
languages. The harness reached system calls such as `proc_pid_rusage` and
`mach_timebase_info` through `ctypes` and hand-written struct layouts. Swift
calls those directly, and its compiler would have checked them.

The tooling has hard constraints whatever its language. It must build, sign,
and launch real bundles through LaunchServices. It must observe tessel only
through its CLI, and it must keep window listings out of failure output. Running
an unsigned build product as the app can revoke the Accessibility permission.

## Decision

Build and verification logic is written in Swift. A Swift package at the
repository root holds only development tools: the build tool, and the
acceptance suites as Swift Testing tests. The app, CLI, and fixture stay
outside that package. The build tool compiles and signs them, so no SwiftPM
product is ever the app. Shell is limited to thin entry points and CI
provisioning steps that only call system tools. Python is not used.

## Consequences

- The project has one language. The harness uses the same types, system calls,
  and compiler checks as the app.
- The first verification run compiles the tooling package, which takes tens of
  seconds.
- SwiftPM locks its build directory while `swift test` runs. The tests therefore
  call a separately built build tool directly, never through SwiftPM.
- When an expectation fails, Swift Testing prints the values it captured.
  Harness code must keep raw CLI output out of expectations, so that a failure
  cannot print other apps' windows.
- A root `Package.swift` can suggest that SwiftPM builds the app. It must stay
  tools-only.
- One-off scripting is more verbose than in Python.

## Alternatives considered

- **Keep Python.** It is concise for process and socket scripting and ships
  with Xcode. It was rejected because it adds a second language for no
  capability Swift lacks, and its system calls go through untyped `ctypes`.
- **Shell only.** It is enough for glue, but the harness needs sockets, JSON,
  precise timing, and system calls. Shell would need helpers in yet another
  language.
