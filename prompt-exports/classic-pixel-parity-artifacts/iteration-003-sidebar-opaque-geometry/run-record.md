### Iteration 0 — `iteration-003-sidebar-opaque-geometry`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-003-sidebar-opaque-geometry`
- Aggregate score: **77.296284/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.081446 | 0.628777 | 77.366560 | 0.000000000000 |
| sidebar | 0.123897 | 0.543491 | 70.979718 | 0.000000000000 |
| top | 0.058593 | 0.652501 | 79.695411 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956337 | 0.000000000000 |
| builder_bottom | 0.062408 | 0.687859 | 81.272566 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
