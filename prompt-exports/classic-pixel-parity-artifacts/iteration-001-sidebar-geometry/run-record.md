### Iteration 0 — `iteration-001-sidebar-geometry`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-001-sidebar-geometry`
- Aggregate score: **74.590130/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.104930 | 0.599039 | 74.705415 | 0.000000000000 |
| sidebar | 0.221014 | 0.420515 | 59.975067 | 0.000000000000 |
| top | 0.058593 | 0.652501 | 79.695411 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956337 | 0.000000000000 |
| builder_bottom | 0.062408 | 0.687859 | 81.272566 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
