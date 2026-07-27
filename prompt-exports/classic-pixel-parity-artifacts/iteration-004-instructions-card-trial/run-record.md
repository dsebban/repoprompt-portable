### Iteration 0 — `iteration-004-instructions-card-trial`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-004-instructions-card-trial`
- Aggregate score: **76.824024/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.086038 | 0.626127 | 77.004446 | 0.000000000000 |
| sidebar | 0.119996 | 0.548487 | 71.424557 | 0.000000000000 |
| top | 0.065232 | 0.638516 | 78.664195 | 0.000000000000 |
| instructions | 0.103249 | 0.568746 | 73.274859 | 0.000000000000 |
| builder_bottom | 0.055666 | 0.719882 | 83.210796 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
