### Iteration 0 — `iteration-005-dense-fixture`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-005-dense-fixture`
- Aggregate score: **75.928980/100**
- Worst region: `instructions`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.086518 | 0.601798 | 75.764002 | 0.000000000000 |
| sidebar | 0.111658 | 0.554664 | 72.150270 | 0.000000000000 |
| top | 0.054334 | 0.669154 | 80.740990 | 0.000000000000 |
| instructions | 0.105835 | 0.518966 | 70.656590 | 0.000000000000 |
| builder_bottom | 0.063529 | 0.680088 | 80.827981 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
