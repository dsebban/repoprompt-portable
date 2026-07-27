### Iteration 0 — `baseline-001`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/baseline-001`
- Aggregate score: **76.009331/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.095794 | 0.616895 | 76.055027 | 0.000000000000 |
| sidebar | 0.188560 | 0.470913 | 64.117685 | 0.000000000000 |
| top | 0.053825 | 0.671657 | 80.891588 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956316 | 0.000000000000 |
| builder_bottom | 0.060221 | 0.698000 | 81.888950 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
