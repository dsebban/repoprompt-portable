### Iteration 0 — `iteration-004-instructions-card-corrected-trial`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-004-instructions-card-corrected-trial`
- Aggregate score: **77.198220/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.086629 | 0.629516 | 77.144374 | 0.000000000000 |
| sidebar | 0.120155 | 0.546890 | 71.336780 | 0.000000000000 |
| top | 0.052668 | 0.678343 | 81.283790 | 0.000000000000 |
| instructions | 0.104728 | 0.589936 | 74.260439 | 0.000000000000 |
| builder_bottom | 0.059549 | 0.702094 | 82.127255 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
