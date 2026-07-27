# Oracle Review

## Requested route metadata

- Provider: Custom (`customProvider`)
- Backend: `CustomOpenAIProvider`
- Model: Custom/gpt-5.6-sol-pro
- Raw model ID: `custom_provider_gpt-5.6-sol-pro`
- Runtime model ID: `gpt-5.6-sol-pro`
- Execution mode: `standard`

# Summary

The implementation, as described, accomplishes the intended targeted presentation refactor: a stable two-column shell, testable `DesktopDetailRoute`, preserved selection/codemap/context behavior, explicit workflow panels, independent Primary/Secondary results, and bounded long-path rendering. The 20 passing desktop tests and the AppKit interaction pass are strong supporting evidence. **Decision: CONTINUE**, solely because the required production-target proof is still missing: the Linux graph verifier correctly refused to run its compile/link checks on macOS, and the visual exercise used AppKit rather than the required GTK/Xvfb backend. I could inspect the repository’s verification scripts, but the current uncommitted desktop diff itself was not available through the conversation files or connected GitHub branch, so I cannot independently certify its exact line-level implementation.

## P1 — Should fix

### Target GTK layout and linkage remain unverified

**Files:** `Scripts/verify_linux_desktop_graph.py:188-242`, `Scripts/smoke_linux_desktop.sh:37-145`

**What’s wrong:** `verify_linux_desktop_graph.py` intentionally exits on non-Linux before compiling the executable, confirming that `GtkBackend` was built, checking `libgtk-4.so` linkage, rejecting Apple backends, and detecting missing libraries. The macOS refusal is therefore expected, but it is not a successful verification result. fileciteturn28file0L188-L242

Likewise, the existing smoke launches the real executable with `SCUI_DEFAULT_BACKEND=GtkBackend` under a 1280×800 Xvfb screen and checks window visibility, bootstrap readiness, GTK/GLib criticals, and invalid-root behavior. That target-backend smoke has not yet been reported as run. fileciteturn29file0L37-L44 fileciteturn29file0L60-L109 fileciteturn29file0L112-L145

The AppKit screenshot cannot close this gap. SwiftCrossUI’s AppKit and GTK implementations may differ in `NavigationSplitView` sizing, button intrinsic widths, text wrapping, editor sizing, and scroll behavior—the exact areas this slice changes. The smoke also checks launch health rather than route switching or visual landmarks, so a separate GTK screenshot inspection remains necessary.

**Concrete suggestion:** Make the next step verification-only—do not add another feature or refactor. Run on Linux with the repository’s required GTK/Xvfb dependencies:

```bash
export SCUI_DEFAULT_BACKEND=GtkBackend

swift test \
  --package-path LinuxDesktop \
  --disable-automatic-resolution

python3 Scripts/verify_linux_desktop_graph.py

bash Scripts/smoke_linux_desktop.sh
```

Then exercise the actual 1280×800 GTK window with:

- A long-path inventory that forces sidebar scrolling.
- Full, sliced, and manual-codemap selections, including **Apply Slices**.
- Automatic codemaps both On and Off.
- A context containing automatic codemaps and at least one omission or long content block.
- Both independently rendered Oracle lanes.
- Settings followed by return to Workspace, confirming route-state preservation.

Capture Workspace and Settings GTK screenshots and mark each of the nine requested landmarks PASS or FAIL against `classic-parity-target-v1.png`.

Once those checks pass, **SHIP THIS SLICE** without further UI work. Any additional code change should be limited to a defect observed on GTK—not speculative polishing or another parity phase.