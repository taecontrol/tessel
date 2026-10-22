# ADR-0008: Gate real-system changes on local evidence

Date: 2026-10-22
Status: Accepted

Amends [ADR-0003](0003-verify-idle-work-with-wakeups-cpu-and-footprint.md)
and [ADR-0004](0004-verify-policy-against-a-simulated-macos.md).

## Context

The deterministic simulator reliably exposed a policy regression across every
execution order. Real-system checks on the shared macOS runner instead varied
with scheduling: the same code produced latency medians of 38 and 108 ms, and
the test process was descheduled for up to 709 ms. Of forty recent Verify runs,
eleven passed, twenty-two failed and seven were cancelled. At most five failures
suggested product defects; none was established by CI. Increasing wall-clock
budgets left the workflow exceeding twelve minutes without making it a reliable
product signal.

The owner's Mac can verify native contracts, journeys and the unchanged latency
and idle-work promises. It cannot safely test permission denial against the
owner's Accessibility database. The disposable runner's signing and permission
journey never failed in those forty runs and measured about 152 seconds before
setup overhead.

## Decision

Pull requests are gated by deterministic policy, simulator evidence, evidence of
local real-system verification, and a disposable-runner Permissions job. CI does
not judge product latency, CPU, footprint or suite execution time. Every job has
a timeout below ten minutes; Permissions allows seven minutes based on its
measured build and journey cost.

Changes to real-system code or its harness require successful local contracts,
journeys, latency and resources for the exact pull-request head. The verification
script emits that evidence only after all four suites pass on a clean checkout
whose head has not changed during verification. Editing the description reruns
the evidence guard. Documentation and simulator-only changes require no new
real-system run; the separate simulator evidence rule still applies.

Retain the 200 ms latency p95 and ADR-0003's inclusive eleven wakeups, inclusive
100 ms CPU and exclusive 30 MB footprint limits, with the same twenty-second
observation window. Remove the resource suite's wall-clock budget and the
combined acceptance job. This replaces ADR-0003's 90/200-second resource and
480-second combined-job budgets and ADR-0004's latency gate on CI.

## Consequences

A real-system change costs one local verification, about eight to nine minutes,
for each head submitted for review. A later commit invalidates the evidence.
CI checks the attestation's revision and suite names; the owner remains
responsible for running the signed harness on a supported desktop. The permission
job continues to protect signed rebuilds and recovery from denied Accessibility
without changing the owner's permissions. There are no scheduled main-branch
runs or diagnostic workflow dispatches.
