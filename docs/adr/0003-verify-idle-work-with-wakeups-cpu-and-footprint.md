# ADR-0003: Verify idle work with wakeups, CPU, and footprint

Date: 2026-10-17
Status: Accepted

Amended 2026-10-20: the owner raised the resources budget to 200 seconds
after the carousel stage put the suite at 91 seconds on CI.

## Context

tessel promises to do nothing while nothing changes. The former CPU-only check
missed cheap recurring work: an empty main-thread 1 Hz timer used about 17 ms
per minute and a background timer about 5.5 ms, both below its 41.3 ms budget.
Ten one-minute observations for the default config and another minute for
workspaces made the resource job take 680–796 seconds. Two acceptance jobs
also paid for two runners and repeated signing, building, and permission checks.

A signed fixture spike on macOS 27 compared interrupt wakeups, CPU time, and
physical footprint. Each observation started after the existing one-second
settle. The tables preserve its aggregate results; MB is decimal, W10/W20/W30
are seconds, and each wakeup/CPU pair is a count and milliseconds. Ranges cover
four local baseline runs and three CI baseline runs. Only fixture windows were
used, with 20 windows in the default config (E22) or across ten workspaces (E36).

Local measurements:

| Scenario | Footprint MB | W10 wakeups / CPU ms | W20 wakeups / CPU ms | W30 wakeups / CPU ms |
| --- | --- | --- | --- | --- |
| E22 baseline ×4 | 13.2–13.6 | 5 / 2.2–2.9 | 6 / 2.4–2.9 | 7 / 2.9–3.4 |
| E36 baseline ×4 | 13.4–13.8 | 6 / 2.6–3.8 | 7 / 2.6–3.9 | 8 / 3.0–4.1 |
| R01: 0.2 s timer, 2 ms spin | 13.4 | 57 / 118 | 108 / 240 | 160 / 346 |
| R03: empty main-thread 1 Hz timer | 13.6 | 18 / 15 | 29 / 16 | 40 / 21 |
| R04: empty background 1 Hz timer | 13.6 | 14 / 3.0 | 24 / 4.0 | 34 / 5.1 |
| R02: 60 MB retained | 73.6 at setup end | — | — | — |

CI measurements on `xcode-27`, [run 39042890419](https://github.com/taecontrol/tessel/actions/runs/39042890419):

| Scenario | Footprint MB | W10 wakeups | W20 wakeups / CPU ms | W30 wakeups |
| --- | --- | --- | --- | --- |
| E22 baseline ×3 | 11.7 | 4–6 | 5–7 / 1.9–2.8 | 6–8 |
| E36 baseline ×3 | 11.6–11.8 | 4–7 | 4–8 / 1.4–3.4 | 5–9 |
| R03: empty main-thread 1 Hz timer | 11.7 | 17 | 28 / 3.8 | 39 |

The system leaves a bounded wakeup tail near +5, +10, +15, and +30 seconds
after setup, on both machines. Setup itself produces about 180 wakeups. The
baseline reaches at most eight interrupt wakeups within W20. Local workspace
CPU can rise independently of interrupt wakeups: LaunchServices notifications
produced 309 ms over five idle minutes, with bursts reaching about 72 ms per
20 seconds (issue #15). Physical footprint remained stable while local resident
size drifted from 55 to 25 MB; CI resident size stayed near 50 MB against about
11.7 MB of footprint.

## Decision

Keep the existing two fixture configurations and one-second settle, then use
one 20-second window. The primary signal is interrupt wakeups from
`proc_pid_rusage`, with an inclusive maximum of 11. This leaves three above the
observed CI maximum of eight and about three below the predicted minimum of
14 for an empty two-second timer. Detecting work recurring every two seconds
or less is the chosen target; it is not a guarantee about longer periods.

Retain an inclusive 100 ms user + system CPU cap for work that never sleeps.
It covers the observed CI baseline of at most 3.4 ms and local notification
bursts near 72 ms while rejecting heavy work such as R01's 240 ms. Use physical
footprint below 30 MB at both window boundaries. The observed baseline was
11.6–13.8 MB, while the retained-allocation mutant reached 73.6 MB. Check the
start immediately so excess retained memory does not incur the idle wait.
All three signals are available through `rusage_info_v0`.

These limits express a detection target supported by recorded evidence, rather
than a multiple of whichever baseline a runner last produced. Remove resource
calibration. A later limit change requires an owner decision and new evidence.
Run permission, functional, and resource verification in one acceptance job,
with budgets of 90 seconds for resources and 480 seconds for the whole job.

## Consequences

- Cheap timers that passed CPU-only verification become observable without
  waiting ten minutes. CPU still covers busy work without timer wakeups.
- Physical footprint avoids shared-page and memory-pressure variation and
  catches retained memory before and after idle observation; it does not
  measure transient peaks inside the window.
- The wakeup threshold includes the observed system tail. A materially changed
  OS schedule or a longer window needs evidence and a new decision.
- LaunchServices notification cost remains a separate issue (#15). The CPU
  margin accommodates observed local bursts, not arbitrary background load.
- One CI job removes duplicate setup and runner use. Functional verification
  remains the largest part of the job and is outside this change's scope.

## Alternatives considered

- **Shorter CPU-only checks, fewer windows, or a separate long calibration:**
  none makes cheap recurring work detectable. Keeping both configurations
  catches work introduced only when the workspace experiment is enabled.
- **Resident size:** counts shared pages and changes with memory pressure;
  runner differences already forced its limit from 50 to 60 MB.
- **Instructions or cycles:** both read zero in the CI VM, so they cannot
  provide a portable assertion across local and CI verification.
- **Package-idle wakeups (`ri_pkg_idle_wkups`):** zero locally but nonzero in
  CI; this signal does not consistently observe the work being rejected.
- **Keep the former check:** preserves a 680–796 second resource job that
  misses the empty-timer regressions contrary to the idle-work promise.
