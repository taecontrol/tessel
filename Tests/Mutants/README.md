# Policy mutants

Run `swift run tessel-check mutants` from the repository root. Each `.patch`
is one mutant, applied independently to a fresh copy of tracked working-tree
contents. A patch header names the bug and fixing commit. Add only real fixed
bugs with an existing P scenario that demonstrably fails when the patch is
applied. Compilation failures do not kill a known-bug mutant.

- `stale-focus-enable.patch` semantically reverts 6b80843 against the extracted
  `Sources/Policy/Workspaces.swift`. The #2 E2 / #17 E2 enabling scenarios must
  reject the stale focus raise in both layouts.
- `guards/simulator-import-policy.patch` plants an undeclared Policy import
  into Simulator. The compiler's module-client boundary must reject it (E10).
- `guards/policy-wall-clock.patch` plants a compilable `Date()` in Policy.
  The purity integrity test must reject it (E13).

Candidates found in `git log --all -- Sources/App` and inspected with
`git show`, not included in this initial patch set:

| Fix | Bug | Reason rejected |
| --- | --- | --- |
| 1a3b9c5 | A stale or timed-out read after destruction retains a closed window | No migrated #1 E8 scenario in this checkout proves the delayed retirement path. |
| 5549050 | Switching layouts reasserts an old native selection | Existing #17 E2 scenarios enable a layout; they do not switch between already-enabled layouts. |
| c38ae75 | A busy app drops a rail geometry write permanently | No migrated #17 E22 scenario in this checkout proves the bounded geometry retry. |
| 9783347 | A queued focus raise selects a former native tab | No migrated native-tab P scenario in this checkout exercises that queued write. |

The enabling patch is the required minimum. Expand this set when migrated
scenarios independently kill the corresponding historical bugs.
