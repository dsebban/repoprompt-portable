### Iteration 0 — `iteration-005-precondition`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-005-precondition`
- Aggregate score: **77.999798/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.078145 | 0.638543 | 78.019891 | 0.000000000000 |
| sidebar | 0.116169 | 0.557404 | 72.061720 | 0.000000000000 |
| top | 0.053825 | 0.671657 | 80.891588 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956316 | 0.000000000000 |
| builder_bottom | 0.059826 | 0.700010 | 82.009196 | 0.000000000000 |

- Decision: `continue`.
- Tests: metric unit suite passed; capture hashes were byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.
