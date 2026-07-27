### Iteration 0 — `iteration-004-retained-preflight`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-004-retained-preflight`
- Aggregate score: **77.941216/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.078475 | 0.637569 | 77.954729 | 0.000000000000 |
| sidebar | 0.116961 | 0.556380 | 71.970952 | 0.000000000000 |
| top | 0.053810 | 0.671677 | 80.893384 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956316 | 0.000000000000 |
| builder_bottom | 0.060210 | 0.698013 | 81.890156 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
