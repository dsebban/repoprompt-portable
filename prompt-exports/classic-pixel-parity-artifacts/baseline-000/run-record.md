### Iteration 0 — `baseline-000`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/baseline-000`
- Aggregate score: **76.005800/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.095929 | 0.617165 | 76.061784 | 0.000000000000 |
| sidebar | 0.189663 | 0.469280 | 63.980866 | 0.000000000000 |
| top | 0.053939 | 0.670998 | 80.852925 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956316 | 0.000000000000 |
| builder_bottom | 0.059826 | 0.700010 | 82.009158 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
