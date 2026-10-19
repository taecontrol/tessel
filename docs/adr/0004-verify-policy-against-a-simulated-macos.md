# ADR-0004: Verify policy against a simulated macOS

Date: 2026-10-18
Status: Accepted

Amends [ADR-0001](0001-swift-for-build-and-verification-tooling.md).

## Context

Every acceptance example of issues #1, #2 and #17 ran end to end: the signed
app, real AppKit fixtures and an independent AX/CG observer, judged by about
2,700 timed waits per run. Each wait mixed three questions: what tessel
decides, how macOS behaves, and how fast it happens. Runs failed at random, a
different wait each time (#21, #23), and fixing one distortion only moved the
failure. A real policy bug, the stale focus raise fixed in 6b80843, appeared
only when a run's timing produced its order of events.

A spike ran the production `Workspaces` and `Rails` against a simulated macOS
with a virtual clock. It reproduced 6b80843's race on every run, ran 12,000
schedules in 0.8 s with identical results, and found an order CI never showed.
Two further spikes settled packaging and scheduling: the policy compiles as an
internal SwiftPM library and in the app's flat build alike, and a scheduler
that gives each serial queue its own thread but lets one run at a time keeps
GCD's ordering and `sync` semantics, where a single-thread scheduler broke 26
of 28 `sync` points.

## Decision

Prove each acceptance example in exactly one layer:

- **Deterministic policy.** The production catalog, `Workspaces`, `Rails`, the
  closet's recovery decision and config reload run unchanged behind small
  ports for AX, application lifecycle, CG order, screen geometry, SkyLight
  mechanics and scheduling. Under `swift test` they run against a simulated
  macOS whose scheduler interleaves work at every port call and whose clock is
  virtual. Races are enumerated or written as explicit orders. tessel's own
  delays are asserted in virtual time.
- **Contracts.** Every behavior the simulator assumes about macOS has an ID and
  a contract on the real system, through the signed observer. The simulator
  never depends on the policy and offers only user and app actions.
- **Journeys.** Eight end-to-end journeys through the signed app confirm the
  pieces are wired together.
- **Latency.** Workspace switches and rail moves are measured from the real key
  post to the observer's sample, and gated on the 95th percentile of 100
  samples each (200 ms). Six CI runs of 20 samples gave p95 81 ms for switches
  and 96 ms for rails.

Real-system checks wait for a final state within one 5 s margin; only the
latency measurement judges elapsed time. The resource suite (ADR-0003) is
unchanged.

This amends ADR-0001: the root package also holds internal `Ports` and
`Policy` libraries and test-only targets. tessel-build still compiles the same
sources into the signed app; no SwiftPM product is the app. The real-system
suites are compiled only when `scripts/verify` sets `TESSEL_ACCEPTANCE=1`, so a
bare `swift test` never launches anything.

## Consequences

- A decision bug fails on every run, in seconds, with a trace of the schedule
  that produced it; CI no longer depends on the runner's timing for policy.
- The simulator can be wrong where nobody modeled macOS. Contracts pin each
  assumption, a registry requires one contract per assumption, every fixed bug
  keeps a scenario that fails without its fix, and a pull request that
  changes the simulator without a contract change must state its evidence.
  Their first runs on macOS 27 contradicted 10 of 35 assumptions; the
  simulator and its scenarios were corrected with that evidence.
- Once a race is reproduced as a schedule, it fails on every run. Correcting
  the simulator exposed one such policy race, a dying app's survivor taking the
  rail selection; a stale startup focus raise, first seen as an intermittent
  journey, became a permanent scenario the same way.
- Policy code may reach macOS only through the ports: no direct GCD, locks,
  wall clock or system calls, enforced by a purity check.
- The simulator is a second model of macOS to maintain, about as large as the
  policy it drives.
- Timing promises of tessel's own code are proven in virtual time; how long
  macOS takes is covered only by the latency measurement and the margin.

## Alternatives considered

- **Keep end-to-end tests and tune their waits:** each fix moved the failure;
  one failure in 4,000 waits already halves the green runs.
- **Rewrite the policy as a pure event-and-intent core:** rewrites about a
  thousand verified decision lines in the change that deletes their tests.
- **A stub above the catalog:** duplicates catalog rules; the spike's copy was
  wrong twice.
- **A single-thread scheduler:** wrong `sync` semantics at 26 of 28 points.
