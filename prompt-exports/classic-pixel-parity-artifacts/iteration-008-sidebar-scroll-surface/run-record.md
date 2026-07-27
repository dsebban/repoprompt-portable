### Iteration 0 — `iteration-008-sidebar-scroll-surface`

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/iteration-008-sidebar-scroll-surface`
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

## Iteration 8 decision

- Candidate source SHA-256:
  `4df0dc11386a74dfded1094c76821e8266c6cd25f8408818f81e74055ce19ea4`.
- Change: one calibrated
  `Color(red: 0.086810246, green: 0.092231961, blue: 0.097734573)`
  background modifier on the first sidebar file-inventory `ScrollView`.
- Activation-matched control:
  `iteration-008-activation-control`; activation watcher returned
  `activated=true`; raw SHA-256
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`.
- Activation-matched candidate: activation watcher returned `activated=true`;
  all three captures have the same raw SHA-256 as control. Normalized SHA-256
  is also identical:
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`.
- Aggregate and every regional metric are exactly unchanged; the
  control-to-candidate diff has zero changed pixels.
- A prior inactive-window capture is retained separately at
  `iteration-008-sidebar-scroll-surface-contaminated-inactive-window`. Its
  apparent improvement is non-authoritative because it removed the active
  titlebar state and Context Builder focus ring.
- Decision: `revert_no_effect`. The modifier failed the required strict
  aggregate and sidebar improvement gates and is not retained.
