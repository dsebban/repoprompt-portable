### Iteration 6 — `iteration-006-sidebar-srgb-calibration` (retained)

- Candidate: `classic-sidebar-srgb-calibration` — change only the opaque sidebar
  background's normalized SwiftCrossUI color channels from source
  `29/255, 31/255, 33/255` to the Oracle Primary's exact calibrated values
  `0.086810246, 0.092231961, 0.097734573`.
- Source file:
  `LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/RootShellView.swift`.
- Fresh current-source control:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-006-precondition`.
- Authoritative candidate artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-006-sidebar-srgb-calibration`.
- Final-source verification artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-006-sidebar-srgb-calibration-final-verification`.
- Aggregate score: **77.919485706611 → 78.378540460022**
  (`+0.459054753411`).
- Worst region: `sidebar`.
- Pixel perfect: `false`.
- Settled samples: `3`; aggregate population variance
  `0.000000000000`; range `0.000000000000`.

| Region | Control | Candidate | Δ control |
|---|---:|---:|---:|
| full | 77.929217267045 | 78.380637014162 | +0.451419747117 |
| sidebar | 71.969401869371 | 73.836160908190 | +1.866759038819 |
| top | 80.891588358083 | 80.891588358083 | +0.000000000000 |
| instructions | 76.956315915785 | 76.956315915785 | +0.000000000000 |
| builder_bottom | 81.821710441472 | 81.821710441472 | +0.000000000000 |

- Control raw capture SHA-256:
  `5b01f930cf0b192fbc341f9be252235a8b16a627c6506f247cc974ace63bd1a9`.
- Candidate raw capture SHA-256:
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`.
- Candidate normalized SHA-256:
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`.
- All three authoritative candidate captures and all three final-source
  verification captures were byte-identical. The final-source verification
  reproduced the exact candidate raw and normalized hashes and every metric
  after the shared Pro Edit path-guard correction changed the release binary.
- Candidate `RootShellView.swift` SHA-256:
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`.
- Final release binary SHA-256:
  `b3c6456867fbdfa073cdeb22b1dd39ebc43a349b78788859f90bc26891bec3ef`.
- Frozen inputs: target
  `07ec2644bcbf4f3a9f4eec7aa56d53404d8cbd933b75f7f490e11a25339ba916`,
  scenario
  `8f9870ad97d8ca9f337bc2c340c4cd0112df3e2773ec3798b5fef6929f748f17`,
  nested lockfile
  `4168e8036facce94634b479e6c98265d504a9d31797840c47cec6daf206341f7`,
  and SwiftCrossUI revision
  `a6d206370812e3b9edba259d167e848892c5013d`.
- Swatch diagnostic: the prescribed raw centers `(500,450)`, `(500,1150)`,
  and `(500,1780)` with `40×40` windows measured candidate medians
  `(46,48,49)`, `(46,48,49)`, and `(29,31,33)`, combined `(46,48,49)`.
  The first two centers now overlap sidebar overlay surfaces introduced by the
  completed Pro Edit UI, so they are no longer glyph-free flat-field probes.
  The dominant flat sidebar pixel changed from control `(38,41,44)` to
  candidate `(29,31,33)`; the overlay mode changed from `(54,57,60)` to
  `(46,48,49)`. The frozen regional metrics remain the acceptance authority.
- Historical-score note: the older Iteration-5 precondition
  (`77.999797937989` aggregate, `72.061719894658` sidebar) predates the completed
  Pro Edit UI that expanded `RootShellView.swift`. It is not conflated with this
  trial's fresh control. The candidate nevertheless exceeds that older state by
  `+0.378742522033` aggregate and `+1.774441013532` sidebar points.
- Visual inspection: the review sheet localizes the material improvement to the
  opaque sidebar surface; no geometry, controls, or right-side regions moved.
- Validation: all `61` LinuxDesktop tests passed on macOS and all `61` passed
  under the Linux GTK image; all `10` pixel-metric tests passed;
  `verify_linux_desktop_graph.py` passed; `smoke_linux_desktop.sh` passed under
  Xvfb; and `git diff --check` passed.
- Oracle provenance: RepoPrompt Classic window `5`, pair
  `65F56227-A6BF-4339-B90C-DE656A572240`; Primary
  `h:7f681c804fde5a45` was adopted exactly. Secondary
  `h:cf8b16e5ef69589d` was deferred because it rounded the calibrated channel
  values.
- Decision: `accept_continue`. The single color hunk is retained because both
  required metrics improved well outside zero variance, all non-target regional
  caps held exactly, determinism held across both candidate capture sets, and
  every required platform check passed.
