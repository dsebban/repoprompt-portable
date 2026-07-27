### Iteration 0 — `iteration-007-precondition`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-007-precondition`
- Aggregate score: **78.378540/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.073910 | 0.641523 | 78.380637 | 0.000000000000 |
| sidebar | 0.097700 | 0.574424 | 73.836161 | 0.000000000000 |
| top | 0.053825 | 0.671657 | 80.891588 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956316 | 0.000000000000 |
| builder_bottom | 0.060460 | 0.696894 | 81.821710 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
