# Iteration 7 — classic-sidebar-selectable-file-list

- Decision: `revert_runtime_failure`.
- Scope: replace only the sidebar file inventory `ScrollView` / `VStack` /
  per-row `Button` subtree with a native selectable SwiftCrossUI `List`.
- Pinned SwiftCrossUI revision:
  `a6d206370812e3b9edba259d167e848892c5013d`.
- API preflight: `List` accepts `Binding<String?>`, but the pinned AppKit
  backend cannot safely clear an optional selection. Its
  `selectionIndexesForProposedSelection` implementation force-unwraps
  `proposedSelectionIndexes.first!` even when the proposed selection is empty.
- Fresh control run: `iteration-007-precondition`, three deterministic samples.
  Aggregate `78.378540460022`; full `78.380637014162`; sidebar
  `73.836160908190`; top `80.891588358083`; instructions
  `76.956315915785`; builder `81.821710441472`.
- Control raw SHA-256:
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`.
- Control normalized SHA-256:
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`.
- Retained `RootShellView.swift` SHA-256:
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`.
- Candidate `RootShellView.swift` SHA-256:
  `0be0b5e715ec4b8986af145c3bd061226eac9fcf3a090b4d9c4162b6618ef384`.
- Candidate release executable SHA-256:
  `7f69abc850c7abc82c2399aa392568e560692092696bc1efcfc3de288e44b718`.
- Candidate macOS tests: all `61` passed.
- Runtime result: the canonical candidate exited with status `-6` before
  readiness, so no candidate screenshots, hashes, or regional metrics exist.
  The failure matches the audited AppKit empty-selection force unwrap.
- Manual UI result: Computer Use could identify the app but capture failed
  with ScreenCaptureKit error `-3811`. Peekaboo then showed the native list
  expanding the window to `1504 × 24219`, so focus/search/reload could not be
  exercised.
- Candidate Linux/graph/Xvfb validation was not run. Docker was unavailable,
  and the local Docker application could not be launched.
- Metric verifier after reversion: all `10` tests passed.
- Reverted macOS tests: all `61` passed. `git diff --check` passed.
- The exact retained source SHA-256 was restored. Earlier Iteration-6 checks
  against this same retained source passed all `61` Linux GTK tests, the graph
  verifier, and the Xvfb smoke; those are retained-state evidence, not candidate
  validation.
- Host recovery: the candidate persisted an invalid `24219`-point AppKit
  window frame. Only the exact
  `NSWindow Frame TupleView1<RootShellView>-0` preference key was removed and
  `cfprefsd` restarted. Later post-revert capture attempts remained blocked by
  local LaunchServices registration failures despite the exact source revert;
  their artifacts are retained separately.
- Acceptance gate: failed automatically because the candidate never reached
  canonical readiness and therefore produced no score. No production source
  from the candidate is retained.
