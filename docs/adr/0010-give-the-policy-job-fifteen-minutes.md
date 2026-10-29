# ADR-0010: Give the policy job fifteen minutes

Date: 2026-10-29
Status: Accepted

Amends [ADR-0008](0008-gate-real-system-changes-on-local-evidence.md).

## Context

ADR-0008 gave every CI job a timeout below ten minutes, and Policy had nine.
Policy builds the package, runs bare `swift test`, checks the layers, and
repeats the suite three times for the trace digest. Its duration varies with
the shared xcode-27 runner much more than with the suite's size. From 24 to
28 October, green runs took between 5 min 51 s and 8 min 38 s. The test step
alone took between 2 min 18 s and 3 min 46 s, and the digest repetition between
3 min 14 s and 5 min 6 s.

On 29 October, the run for #58 was cancelled at nine minutes. All 475 tests had
passed, and the digest repetition was still running. The suite took 155 s on
CI against 105 s on the previous pull request, although the 19 tests that #58
added take 0.43 s locally. The job had no margin left for the runner's spread.

## Decision

Policy has a fifteen-minute timeout. Every other job keeps a timeout below ten
minutes, and the Permissions job keeps its seven. Fifteen minutes covers the
slowest observed test step followed by the slowest observed digest repetition,
with margin. A delivery check enforces both limits.

## Consequences

A pull request can wait up to fifteen minutes for every check to turn green,
and AGENTS.md states that limit. A cancelled Policy run now points to a hang or
to real growth, not to the runner's spread. Reducing Policy's cost, for
example by building once or repeating the digest fewer times, remains possible
and would change how much confidence the digest check gives.
