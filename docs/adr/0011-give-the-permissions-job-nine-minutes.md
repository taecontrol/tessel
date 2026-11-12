# ADR-0011: Give the Permissions job nine minutes

Date: 2026-11-12
Status: Accepted

Amends [ADR-0008](0008-gate-real-system-changes-on-local-evidence.md) and
[ADR-0010](0010-give-the-policy-job-fifteen-minutes.md).

## Context

ADR-0008 gave the Permissions job seven minutes, from a measured 99 s build,
50 s signing journey and 3 s of permission steps. ADR-0010 kept that limit.
The job builds the signed bundles, then builds the test target and runs the
signing and permission journey. Its duration follows the shared xcode-27
runner. From 29 October to 2 November, seven green runs took between 216 s
and 381 s; the slowest spent 175 s on the first build alone.

On 12 November, the run for #70 was cancelled at seven minutes. Every step had
passed, and the job was completing. It spent 174 s building the bundles and
235 s in the signing and permission step, 436 s in all. That pull request adds
a few files to the build and no permission test. The job had no margin left
for the runner's spread.

## Decision

Permissions has a nine-minute timeout, the most the rule of ADR-0008 allows:
every job but Policy keeps a timeout below ten minutes. The delivery check
that enforces that rule does not change.

## Consequences

Nine minutes leave 104 s over the slowest run observed. A pull request still
turns green within Policy's fifteen minutes. A run that reaches nine minutes
asks for a cheaper job, for example one build instead of two, before another
limit: ten minutes would break the rule that AGENTS.md states.
