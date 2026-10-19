# Coding standards

## Review rules

- Each acceptance example is proven in exactly one layer: deterministic
  policy, macOS contract, end-to-end journey, or latency measurement. A
  decision checked through the real app, or a macOS behavior checked only
  through the simulator, is in the wrong layer. A change that adds or moves an
  example updates the map in `docs/development.md`.
- Every behavior the simulated macOS assumes about AX, AppKit, CG, SkyLight or
  LaunchServices has a contract test on the real system. A change that adds or
  alters such an assumption adds or updates its contract in the same change.
- The simulator is never changed to make a failing scenario pass. A change to
  what the simulator does arrives with the evidence of its contract on the
  real system.
- A change to what a scenario expects names the accepted example it changes.
- A fixed policy bug keeps a deterministic scenario that fails without its
  fix. The pull request that fixes it shows that failure.
- A check on the real system waits for a final state within a generous margin
  stated where the wait is declared. Only the latency measurement judges
  elapsed time, as a percentile over many samples rather than a deadline per
  check.
