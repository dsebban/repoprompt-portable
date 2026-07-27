# Classic Pixel-Parity Optimization Runs

This is the append-only scoreboard for measured visual convergence on the supplied
RepoPrompt Classic screenshot. Prior run records are never edited; corrections are
new records.

## Measurement contract

- Canonical target: `docs/visual-contracts/classic-parity-target-v1.png`
- Supplied source SHA-256: `07ec2644bcbf4f3a9f4eec7aa56d53404d8cbd933b75f7f490e11a25339ba916`
- Supplied source dimensions: `3008×1920`
- Raw candidate window: `3008×1898`, including title bar and excluding shadow
- AppKit outer frame: `1504×949` points at exactly `2.0×`
- Target raw image: `3008×1920`
- Normalized canvas: `1956×1252`
- Normalization: `srgb-aspect-fill-lanczos-v1`
- Metric: `rgb-nmae-gaussian-ssim-v1`
- Region masks: `disjoint-right-bands-v1`
- Fixture/scenario: `Scripts/fixtures/classic-pixel-parity/scenario.json`
- Scenario ID: `classic-compose-builder-v1`
- Appearance: dark
- One attributed production UI change per iteration

Both target and candidate are converted to sRGB, composited over opaque white,
center-cropped by the same floating-point aspect-fill rule, and resized with
Lanczos. Channel values are then normalized to `[0,1]`.

The selected 2× host display exposes a 949-point AppKit visible height. macOS
therefore clamps a standard SwiftCrossUI window requested at `1504×960` to
`1504×949` (observed repeatedly by AX). The campaign freezes that honest host
geometry instead of mutating system menu-bar preferences or adding production
screenshot hooks. Exact parity is evaluated on the normalized canvas.

For each region:

```text
NMAE = mean(abs(candidate - target))
score = 100 × (0.5 × (1 - NMAE) + 0.5 × clamp(SSIM, 0, 1))
```

SSIM is evaluated independently over RGB and averaged using an 11×11 Gaussian
kernel, sigma `1.5`, reflect padding, population covariance, `C1=0.01²`, and
`C2=0.03²`.

Aggregate:

```text
0.500 × full
+ 0.125 × sidebar
+ 0.125 × top/right
+ 0.125 × instructions/right
+ 0.125 × builder/bottom/right
```

Masks are half-open:

| Region | Box |
|---|---|
| Full | `[0,1956) × [0,1252)` |
| Sidebar | `[0,473) × [0,1252)` |
| Top/right | `[473,1956) × [0,170)` |
| Instructions/right | `[473,1956) × [170,650)` |
| Builder/bottom/right | `[473,1956) × [650,1252)` |

## Hard acceptance

- `pixel_perfect` requires byte-identical normalized PNGs, exact zero NMAE, and
  exact SSIM `1.0` in every region.
- A candidate is accepted only when aggregate score and its declared target region
  improve, non-target regions do not regress more than `0.10` points, desktop tests
  pass, AppKit capture is deterministic, and Linux build/graph/smoke passes.
- Two consecutive accepted iterations below `0.10` aggregate points and `0.20`
  points in every region constitute a plateau, but not success below the exact
  pixel gate.
- Final visual review records independent Primary and Secondary Oracle verdicts.

## Campaign provenance

The first valid baseline run freezes target, fixture, harness, metric, dependency,
binary, SwiftCrossUI, worktree, and host-environment hashes here.

<!-- CAMPAIGN_PROVENANCE -->

```json
{
  "binary": {
    "nested_lockfile_sha256": "4168e8036facce94634b479e6c98265d504a9d31797840c47cec6daf206341f7",
    "path": "/Users/danielsivan/dev/repoprompt-portable/LinuxDesktop/.build/arm64-apple-macosx/release/repoprompt-linux-desktop",
    "sha256": "1a40607fdcd64d5228642f831e55007176719a7a2290a8350849bc093713cb5b",
    "swift_cross_ui_revision": "a6d206370812e3b9edba259d167e848892c5013d"
  },
  "captures": [
    {
      "ax_frame": {
        "height": 949,
        "width": 1504,
        "x": -1508,
        "y": 33
      },
      "backing_scale": 2,
      "captured_at": "2026-07-26T15:56:02Z",
      "cg_frame": {
        "height": 949,
        "width": 1504,
        "x": -1508,
        "y": 33
      },
      "pid": 25333,
      "raw_pixels": [
        3008,
        1898
      ],
      "schema_version": 1,
      "screen": {
        "backing_scale": 2,
        "frame_height": 982,
        "frame_width": 1512,
        "frame_x": -1512,
        "frame_y": 458
      },
      "sha256": "bdb1985c03e3e33aabbe04fd572ed50c7dcb7a9b21547d3475286229fc978d54",
      "title": "RepoPrompt Portable",
      "window_id": 11583
    },
    {
      "ax_frame": {
        "height": 949,
        "width": 1504,
        "x": -1508,
        "y": 33
      },
      "backing_scale": 2,
      "captured_at": "2026-07-26T15:56:03Z",
      "cg_frame": {
        "height": 949,
        "width": 1504,
        "x": -1508,
        "y": 33
      },
      "pid": 25333,
      "raw_pixels": [
        3008,
        1898
      ],
      "schema_version": 1,
      "screen": {
        "backing_scale": 2,
        "frame_height": 982,
        "frame_width": 1512,
        "frame_x": -1512,
        "frame_y": 458
      },
      "sha256": "bdb1985c03e3e33aabbe04fd572ed50c7dcb7a9b21547d3475286229fc978d54",
      "title": "RepoPrompt Portable",
      "window_id": 11583
    },
    {
      "ax_frame": {
        "height": 949,
        "width": 1504,
        "x": -1508,
        "y": 33
      },
      "backing_scale": 2,
      "captured_at": "2026-07-26T15:56:04Z",
      "cg_frame": {
        "height": 949,
        "width": 1504,
        "x": -1508,
        "y": 33
      },
      "pid": 25333,
      "raw_pixels": [
        3008,
        1898
      ],
      "schema_version": 1,
      "screen": {
        "backing_scale": 2,
        "frame_height": 982,
        "frame_width": 1512,
        "frame_x": -1512,
        "frame_y": 458
      },
      "sha256": "bdb1985c03e3e33aabbe04fd572ed50c7dcb7a9b21547d3475286229fc978d54",
      "title": "RepoPrompt Portable",
      "window_id": 11583
    }
  ],
  "harness": {
    "capture_binary_sha256": "0a0ef80a1bac9a221dc59c407da9a5e2a166ebb173871dbac3a2c6704d59bfe2",
    "capture_source_sha256": "bb950c7d396077b46798c39d9a9ffe7fcbabcbba01ae61a1234e8a9fe18bc814",
    "metrics_sha256": "6246d97c0ffbdac6c784510e61929731f8bf73f139c23518c40126584aa8e0a5",
    "orchestrator_sha256": "9acadcb0d63d60a34d5e39c9c464bba8861f455e071247643dad8868eb7b80c3",
    "requirements_sha256": "647f5b2087fcc5375dc45a98e3bcbe1cefe1c169b5f7f534ea6a80e5d7acfbab"
  },
  "head": "a3997cf3c661dc738117245d45af926128524a97",
  "host": {
    "appearance": "Dark",
    "apple_accent_color": "system-default",
    "architecture": "arm64",
    "increase_contrast": "0",
    "macos": "ProductName:\t\tmacOS\nProductVersion:\t\t26.5\nBuildVersion:\t\t25F71",
    "python": "3.12.3 (v3.12.3:f6650f9ad7, Apr  9 2024, 08:18:47) [Clang 13.0.0 (clang-1300.0.29.30)]",
    "reduce_transparency": "0",
    "screen": {
      "backing_scale": 2,
      "frame_height": 982,
      "frame_width": 1512,
      "frame_x": -1512,
      "frame_y": 458
    },
    "swift": "Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0"
  },
  "measurement": {
    "candidate_raw_pixels": [
      3008,
      1898
    ],
    "canvas": [
      1956,
      1252
    ],
    "mask_policy": "disjoint-right-bands-v1",
    "metric_id": "rgb-nmae-gaussian-ssim-v1",
    "normalization_id": "srgb-aspect-fill-lanczos-v1",
    "target_raw_pixels": [
      3008,
      1920
    ],
    "window_points": [
      1504,
      949
    ]
  },
  "run_id": "baseline-000",
  "scenario": {
    "expected_indexed_file_count": 22,
    "fixture_sha256": "9249879d07c3116eb87e24a4ca8eb8a03651be2d6548d2b31627ca95c8ba4d8c",
    "path": "Scripts/fixtures/classic-pixel-parity/scenario.json",
    "sha256": "195b7b702262e1573ab3edde06081cff1abd44f31a1ac018fa58e260a790899b"
  },
  "schema_version": 1,
  "target": {
    "dimensions": [
      3008,
      1920
    ],
    "path": "docs/visual-contracts/classic-parity-target-v1.png",
    "sha256": "07ec2644bcbf4f3a9f4eec7aa56d53404d8cbd933b75f7f490e11a25339ba916"
  },
  "worktree_after": {
    "entries": [
      {
        "bytes": 185,
        "path": ".codex/environments/environment.toml",
        "sha256": "0d9c84ab61b4224545ec9a1792dbe36b22da071ef20168aaca706b19af3e0c97"
      },
      {
        "bytes": 491,
        "path": ".dockerignore",
        "sha256": "52d0c97f8a7c9df2eb73020eb5991c857172b22d93c84a5b17927c3f351a7403"
      },
      {
        "bytes": 70,
        "path": ".gitignore",
        "sha256": "d4fb36e7f12cdd07e2ba09f53df9ba43214e523842408ce5f46eb5b182912b49"
      },
      {
        "bytes": 3332,
        "path": "Dockerfile.headless",
        "sha256": "9587d0e0eb04743397f8b70f7e5d20f121122799d7f37cfe25cb2305b6cdc487"
      },
      {
        "bytes": 11378,
        "path": "LinuxDesktop/Package.resolved",
        "sha256": "4168e8036facce94634b479e6c98265d504a9d31797840c47cec6daf206341f7"
      },
      {
        "bytes": 3252,
        "path": "LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/DesktopSliceDraftParser.swift",
        "sha256": "e779ff8a0ffd705585859359b4fab8fb98c220eb90e8a4f7d70ec51d3d259624"
      },
      {
        "bytes": 7848,
        "path": "LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/DesktopState.swift",
        "sha256": "14f7006120f4129063b35cb7db78850ad9b9a50ab1c8fe31a4425e0b762b28f6"
      },
      {
        "bytes": 19840,
        "path": "LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/RootShellView.swift",
        "sha256": "92bdb4bd60b1e1474b2ed07655cb952e4800d82cb3d474d1a52326284d62ca05"
      },
      {
        "bytes": 10128,
        "path": "LinuxDesktop/Tests/RepoPromptLinuxDesktopKitTests/DesktopLogicTests.swift",
        "sha256": "f9d50f76b40dbb72ace6932b835ca1c312cea20a56a0d04dae65b340c0121d07"
      },
      {
        "bytes": 2323,
        "path": "LinuxDesktop/Tests/RepoPromptLinuxDesktopKitTests/DesktopWorkspaceIntegrationTests.swift",
        "sha256": "039620dbb70fdb65d571e7a58eb74d28cb03900f5c2116b4b820540e3184484d"
      },
      {
        "bytes": 10438,
        "path": "Package.resolved",
        "sha256": "5ecc892afc41b927a377be4fa1c89d107b2246fac086fd00fb7c8f874d34fa89"
      },
      {
        "bytes": 4448,
        "path": "Package.swift",
        "sha256": "dfefa4df714cfa0ba3316785b072035452132ad18d8457f52ea1b762d95cc4e9"
      },
      {
        "bytes": 12199,
        "path": "README.md",
        "sha256": "af45288cf355d445450516e3f6477bf4b880668cf65439737a3274a8640ce306"
      },
      {
        "bytes": 2442,
        "path": "RepoPromptCodeMap/CodeMapSyntaxArtifactBuilder.swift",
        "sha256": "991f60499785e13462116606eab12a51631c9b98cafa86ec0b9d978aeb765d7b"
      },
      {
        "bytes": 24585,
        "path": "RepoPromptCodeMap/CodeMapSyntaxEngine.swift",
        "sha256": "b9650716f47b07ed08e24924c985e1bd898196cb54d11ffb1e4d1ffa79d10046"
      },
      {
        "bytes": 10264,
        "path": "RepoPromptCodeMap/Extraction/CodeMapCaptureIndex.swift",
        "sha256": "4df3cff08e058d0f05ee42b6cb55976d5951a96a68ab8efc655a3640f7f20c1c"
      },
      {
        "bytes": 5751,
        "path": "RepoPromptCodeMap/Extraction/CodeMapExtractionMemo.swift",
        "sha256": "afa4f65e8dfa40bc92be71ae8f81144bf28e2f3264021cf5b590cc5e31854042"
      },
      {
        "bytes": 126257,
        "path": "RepoPromptCodeMap/Extraction/CodeMapGenerator.swift",
        "sha256": "50dbb0c817eb763455d252bff0ed70857cea658b837f70826b7022517a5f38fa"
      },
      {
        "bytes": 2587,
        "path": "RepoPromptCodeMap/Extraction/CodeMapPCRE2Regex.swift",
        "sha256": "f5525b4e5ca7ef9bfc51edcd4b310dd9bc28dd505e1c4a877a894ea3c838457c"
      },
      {
        "bytes": 19463,
        "path": "RepoPromptCodeMap/Extraction/JSTSSignatureExtractor.swift",
        "sha256": "0593744b1d3bae7441a877bc69c10679f3a11247cca6b7e7a69debde944cff53"
      },
      {
        "bytes": 65833,
        "path": "RepoPromptCodeMap/Extraction/LanguageStrategies/SwiftCodeMapStrategy.swift",
        "sha256": "f80767a5b42593142325f63fefe45f97ceda7100238a9c70c8dd9cbacbd34ed4"
      },
      {
        "bytes": 26665,
        "path": "RepoPromptCodeMap/Extraction/LanguageStrategies/TypeScriptCodeMapStrategy.swift",
        "sha256": "53714f1a2d4a09aec6f4532e3e739c04f1560faec668d7adcd54754a48a1cdac"
      },
      {
        "bytes": 69957,
        "path": "RepoPromptCodeMap/Extraction/LanguageTypeExtractor.swift",
        "sha256": "7c0413635161412e5c49a127851e8d89358d11b29d0c0b1d3fb87bd624ff7f7f"
      },
      {
        "bytes": 5818,
        "path": "RepoPromptCodeMap/Extraction/ReferencedTypesAccumulator.swift",
        "sha256": "6e2b0a1814d630cc998ba6155e1566d6bdbe4c85bd785ce23cd74af795b8f775"
      },
      {
        "bytes": 2364,
        "path": "RepoPromptCodeMap/Extraction/SwiftSignatureParser.swift",
        "sha256": "9590622917e4df3c2e1c045d75aa49e34e9427df4782c52e7dcfa5556bffd761"
      },
      {
        "bytes": 6598,
        "path": "RepoPromptCodeMap/Extraction/TopLevelScanner.swift",
        "sha256": "27d65486cba89eb8d9e7bd489e3af458ae4154bd74307b8566f9d860eac61a9f"
      },
      {
        "bytes": 63122,
        "path": "RepoPromptCodeMap/Extraction/TypeCleaner.swift",
        "sha256": "efd3685a47849be3803e37b01edffe1d9bb108b27b04013d322dcca84cfae701"
      },
      {
        "bytes": 21820,
        "path": "RepoPromptCodeMap/Models/CodeMapArtifactKey.swift",
        "sha256": "832ccea59e786caaecb2d6616670c13022e51d52f982f5fd5af4731087a55201"
      },
      {
        "bytes": 2426,
        "path": "RepoPromptCodeMap/Models/CodeMapCoreSourceSnapshot.swift",
        "sha256": "dfe2e53fe36e1e161421549457f992fefd42c839580676aee0bbf7c471deec51"
      },
      {
        "bytes": 14636,
        "path": "RepoPromptCodeMap/Models/CodeMapSyntaxArtifact.swift",
        "sha256": "9781784581bb1e5c9afdc5ac597f555d875c151a19b0a5bffe839e7faea5bde0"
      },
      {
        "bytes": 14800,
        "path": "RepoPromptCodeMap/Performance/CodeMapPerformanceCollector.swift",
        "sha256": "ab43b29b13d35a0a725b1944642ba80888bdf11541f4d3ae8078b17404d6384c"
      },
      {
        "bytes": 1272,
        "path": "RepoPromptCodeMap/PortableCodeMap.swift",
        "sha256": "d3baba041a20f9dc4fc1daccd9fa9b3a42b0c3b508b432bb91ff772540221f94"
      },
      {
        "bytes": 1638,
        "path": "RepoPromptCodeMap/Queries/GoQueries.swift",
        "sha256": "5cb51de88ec8caa4548961420eafbb06620a21db73d3a6e287e713acd891c297"
      },
      {
        "bytes": 1082,
        "path": "RepoPromptCodeMap/Queries/JavaQueries.swift",
        "sha256": "e9c4db2a1366da4158207b9274b086255d5de48b65f7fb8ff88534553e628993"
      },
      {
        "bytes": 6508,
        "path": "RepoPromptCodeMap/Queries/JavaScriptQueries.swift",
        "sha256": "5cea54b5916607c662a6d2798858cf60aef21f3ce523e89c95951879a145dc65"
      },
      {
        "bytes": 1186,
        "path": "RepoPromptCodeMap/Queries/PythonQueries.swift",
        "sha256": "c31a8d794bca177832d9270506cc3bca2f395782baf8831053c2c3a8e475a405"
      },
      {
        "bytes": 1310,
        "path": "RepoPromptCodeMap/Queries/RubyQueries.swift",
        "sha256": "e770b4bc9d2ee6b8ec4ee802697df8940e14e2800be7ab46603e56f28351c946"
      },
      {
        "bytes": 1971,
        "path": "RepoPromptCodeMap/Queries/RustQueries.swift",
        "sha256": "b95493595fb406183f9fcc7bfb542e812f9e0c0a1ce6a42b9a6f73b7d1e4e70a"
      },
      {
        "bytes": 4670,
        "path": "RepoPromptCodeMap/Queries/SwiftQueries.swift",
        "sha256": "4c0e4820c887074b502e9242e52b4f6965f5f86f1e8337e9c659767c2d51e399"
      },
      {
        "bytes": 3145,
        "path": "RepoPromptCodeMap/Queries/cQueries.swift",
        "sha256": "1efd8de6d2ce20064116435203221786e7e8cbb18a4f40d1038feda2f2e5b7e5"
      },
      {
        "bytes": 1950,
        "path": "RepoPromptCodeMap/Queries/cSharpQueries.swift",
        "sha256": "376c0ed2d8d1d0cfa81ace844a5082c7a2d67a74bfcbe5baa1e7d317404df0f4"
      },
      {
        "bytes": 1678,
        "path": "RepoPromptCodeMap/Queries/cppQueries.swift",
        "sha256": "4018643f8f57007a00d5c2e02b57998de3c9e04833b6ad9d3a3cfa396d7d8562"
      },
      {
        "bytes": 1655,
        "path": "RepoPromptCodeMap/Queries/phpQueries.swift",
        "sha256": "60ea68f631251da4344d38df6de400baf550cfc3bf731c9f4d4f065e512a69f4"
      },
      {
        "bytes": 14560,
        "path": "RepoPromptCodeMap/Queries/typeScript.swift",
        "sha256": "10348ecce15f68534d1f47a4afbbb40633d34d9b52f2a9dd56bb15f9ede7b851"
      },
      {
        "bytes": 7257,
        "path": "RepoPromptCore/WorkspaceContext/Selection/WorkspaceSelectionReducer.swift",
        "sha256": "dc0ddb42c60b5d0f5ca482821a77f418a5be1c2c23706701629588f0cb9216b9"
      },
      {
        "bytes": 4614,
        "path": "RepoPromptCore/WorkspaceContext/Slices/SliceAssembly.swift",
        "sha256": "ce55213585bfa2da5b65179e288c855d09dcac640835cf3606f054bc74e7d82e"
      },
      {
        "bytes": 2671,
        "path": "RepoPromptCore/WorkspaceContext/Slices/SliceRangeMath.swift",
        "sha256": "c89191f3b9643cf96f84d25ffe6da280f1d89cc064b19ceaf26577f7de690308"
      },
      {
        "bytes": 46195,
        "path": "RepoPromptHeadless/HeadlessToolCatalog.swift",
        "sha256": "cfa0b47f2fd07fabdbf75aba12a7ab5b6109f0e513c88b3d5f84899cb6775ee4"
      },
      {
        "bytes": 21412,
        "path": "RepoPromptHeadless/HeadlessWorkspaceContextBuilder.swift",
        "sha256": "3630be0ac260fc3ceac6f47613a3ffd7938e9ae5f5ba33137cee55edb4988d61"
      },
      {
        "bytes": 11207,
        "path": "RepoPromptHeadless/PortableWorkspaceModels.swift",
        "sha256": "3a254a03ca3830ca0a72657562e9318eeac33fa424e925f8723786abaa1ef0b3"
      },
      {
        "bytes": 23617,
        "path": "RepoPromptHeadless/PortableWorkspaceService.swift",
        "sha256": "d469e31148c7b11552c3a6343061492f91113a2126a11aadb15b2672a9b0343d"
      },
      {
        "bytes": 73,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/c/smoke.c",
        "sha256": "3bf77cd1eca994589d4d68709771325b5c57c271df3b8d660e8d8e2880a03f67"
      },
      {
        "bytes": 577,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/cpp/edge_methods.cpp",
        "sha256": "8c56be136cb6b7ca979faf82b8b55726e22e84bb1c06d8dd1a649d3b7b65cc64"
      },
      {
        "bytes": 251,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/cs/smoke.cs",
        "sha256": "d84e8d0676241f244a10d09140f50783afaececebfa3b4dc4987f2b7ef7db1bc"
      },
      {
        "bytes": 245,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/go/smoke.go",
        "sha256": "dbea2ae12828f8bdd4a288a358d7ad3df22b64f0a1f8d042e6169239237d4ce8"
      },
      {
        "bytes": 654,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/java/smoke.java",
        "sha256": "982167e56a4b7300ed5cf0f3fea0fda9b2c857549b76d2ca497ad04e30cf2f0d"
      },
      {
        "bytes": 486,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/js/smoke.js",
        "sha256": "3df59e2ef68cb9bfcf9ac43734c63db150bac2f86589267c8650326d636f19af"
      },
      {
        "bytes": 556,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/php/edge_namespaces.php",
        "sha256": "a6454385533d44ad4dabc4c8d4023dd388f705329a82d2d42ca3017ef482c20b"
      },
      {
        "bytes": 277,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/py/smoke.py",
        "sha256": "52747a8e573441c33a5534d0c9290fab51e7b61f79dc151ab082c58d4cb1e0b1"
      },
      {
        "bytes": 377,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/rb/smoke.rb",
        "sha256": "028562aa4005acac6349adaf6684210ef8e613120c7e22351cf04cc940eeec7c"
      },
      {
        "bytes": 659,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/rs/smoke.rs",
        "sha256": "a82a26653139bcecc6c777bb530f7bfbc1b1d3dae6c9ab0c59b5b21402a3597d"
      },
      {
        "bytes": 301,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/swift/smoke.swift",
        "sha256": "1a076f29734dcf04b1d481390e8f1359dfc6f6b64caa63491b8d8f6e29ae1005"
      },
      {
        "bytes": 403,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/ts/smoke.ts",
        "sha256": "2476eb8a686464469a3bd62fc3c530341af0ab8a5c36a08f29b319d1c9221224"
      },
      {
        "bytes": 385,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/tsx/component.tsx",
        "sha256": "eed960e599e37c2d852aa8ec414e001377aac3a775dfa793d0a31b5a0d0a4b20"
      },
      {
        "bytes": 110,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/c_smoke.codemap.txt",
        "sha256": "bcb7ee7b9aa8f26e6d60c49272365847849da01c9dbb2367e61730f121e8e1c1"
      },
      {
        "bytes": 301,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/cpp_edge_methods.codemap.txt",
        "sha256": "c4c9be3d89172919462264ed4e7b008d429ff23ac4a542f9d3b8c9e35ab7aa94"
      },
      {
        "bytes": 281,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/cs_smoke.codemap.txt",
        "sha256": "f6f19d24dadab94b0a26daf1473ca22701e22a071a97fa20cb8ebd3812d795cb"
      },
      {
        "bytes": 132,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/fixture-tree.txt",
        "sha256": "54261ff48293b34ed9f5da5504af692d4030ae7258b681853c454fb476544ec8"
      },
      {
        "bytes": 272,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/go_smoke.codemap.txt",
        "sha256": "c207fcf6022fd8f44f85cfadf3e6365583b6b8c8f231f6368382c3c49e8847b0"
      },
      {
        "bytes": 320,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/java_smoke.codemap.txt",
        "sha256": "ced3e415f74f9d45a44a6649b7989727a62fcfd56aea1a57e9140e797774e561"
      },
      {
        "bytes": 395,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/js_smoke.codemap.txt",
        "sha256": "59ce2e90761f1da0e2be43eb87f2a821da8e63763df9ba1e164c64bdf846f938"
      },
      {
        "bytes": 461,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/php_edge_namespaces.codemap.txt",
        "sha256": "8d438afb884912b8a9847cfa536483542fcd132e13995fe838453a6e11c1aa79"
      },
      {
        "bytes": 257,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/py_smoke.codemap.txt",
        "sha256": "1f8a2c07d024237e69ede4d6650562c6657e0598704555a8e6d24d79ec9b6ca0"
      },
      {
        "bytes": 797,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/rb_smoke.codemap.txt",
        "sha256": "ce45c538123efa5c15f6dd5ab07e070a77e12b0a64c883499213332d20b990c7"
      },
      {
        "bytes": 439,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/rs_smoke.codemap.txt",
        "sha256": "702f45359581b85f9185ce1d7928f2b554d0537462e2a094b37dbc437a3af1e0"
      },
      {
        "bytes": 353,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/swift_smoke.codemap.txt",
        "sha256": "8896f608c762c679e6d3793af11a8dd5d0312c7f2b14765109a6a3ecb7a28a48"
      },
      {
        "bytes": 553,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/ts_smoke.codemap.txt",
        "sha256": "cd5cc0cd9bbe9d8cd9c9cc168c29a24af50241d7f03f2356c46f60d2e3fbc6ab"
      },
      {
        "bytes": 583,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/tsx_component.codemap.txt",
        "sha256": "1c37575dce832d73d68f24670754510a934f7e5de737a72afc53343c92ff1e21"
      },
      {
        "bytes": 2002,
        "path": "RepoPromptHeadlessTests/PortableCodeMapParityTests.swift",
        "sha256": "52196aa78a4a21d0f975f87faa2fda89291dce6d8ed51fde88e3fe1fc7b934ed"
      },
      {
        "bytes": 29432,
        "path": "RepoPromptHeadlessTests/PortableWorkspaceServiceTests.swift",
        "sha256": "a0c886a3f11afe7219539750704d6b2b0b03e24700142e048a0bcbc53f562a5d"
      },
      {
        "bytes": 45756,
        "path": "RepoPromptHeadlessTests/RepoPromptHeadlessCatalogOracleTests.swift",
        "sha256": "22a0791e36cbb0d4f5597f61121b2444ee919557facf5d843e6c09d9d4a32edb"
      },
      {
        "bytes": 18718,
        "path": "RepoPromptHeadlessTests/RepoPromptHeadlessWorkspaceContextBuilderTests.swift",
        "sha256": "444565609f59a5c89809d9c815011b91e58acbac696105c346e1c6795aef1b85"
      },
      {
        "bytes": 13990,
        "path": "Scripts/classic_pixel_parity_capture.swift",
        "sha256": "bb950c7d396077b46798c39d9a9ffe7fcbabcbba01ae61a1234e8a9fe18bc814"
      },
      {
        "bytes": 12833,
        "path": "Scripts/classic_pixel_parity_metrics.py",
        "sha256": "6246d97c0ffbdac6c784510e61929731f8bf73f139c23518c40126584aa8e0a5"
      },
      {
        "bytes": 4327,
        "path": "Scripts/fixtures/classic-pixel-parity/scenario.json",
        "sha256": "195b7b702262e1573ab3edde06081cff1abd44f31a1ac018fa58e260a790899b"
      },
      {
        "bytes": 341,
        "path": "Scripts/requirements-classic-pixel-parity.txt",
        "sha256": "647f5b2087fcc5375dc45a98e3bcbe1cefe1c169b5f7f534ea6a80e5d7acfbab"
      },
      {
        "bytes": 27363,
        "path": "Scripts/run_classic_pixel_parity.py",
        "sha256": "9acadcb0d63d60a34d5e39c9c464bba8861f455e071247643dad8868eb7b80c3"
      },
      {
        "bytes": 4210,
        "path": "Scripts/smoke_linux_desktop.sh",
        "sha256": "c140273b9c5e105cffcadec404e5ba7cd19fd6d841b8eac775cbb4c60d91d0e6"
      },
      {
        "bytes": 5393,
        "path": "Scripts/test_classic_pixel_parity_metrics.py",
        "sha256": "2d10c762d78358bb3d7fa335bada33274e98d93a3b04f6e522c5718ddf176b16"
      },
      {
        "bytes": 10073,
        "path": "Scripts/verify_linux_desktop_graph.py",
        "sha256": "e98161f312f6e2a4220d3041e0a7e289e644372c78a0e0e72c3b452b40ccd766"
      },
      {
        "bytes": 985,
        "path": "TreeSitterScannerSupport/include/tree_sitter/alloc.h",
        "sha256": "b29c1c9fb7cc82f58c84b376df1297d6e2737a1d655fd356db0859e3c29c2fea"
      },
      {
        "bytes": 10431,
        "path": "TreeSitterScannerSupport/include/tree_sitter/array.h",
        "sha256": "5bdf6ed1a78e3409fd443e085ca967a64c188a5d082aaf7f819bccd53a471c94"
      },
      {
        "bytes": 7624,
        "path": "TreeSitterScannerSupport/include/tree_sitter/parser.h",
        "sha256": "180b893c8734778fd32f372dfbc27bd6ad1cd2221f26150b31256ff6716320d2"
      },
      {
        "bytes": 10576,
        "path": "TreeSitterScannerSupport/src/javascript/scanner.c",
        "sha256": "b3d3f64284d97bf80749c026862427782cf7ecc0b7dc094e6698ab311c9a42c7"
      },
      {
        "bytes": 15470,
        "path": "TreeSitterScannerSupport/src/python/scanner.c",
        "sha256": "6db82134ac2d4c90a1a1475487a625cface02662ebda9b7478cad9c7147e9afe"
      },
      {
        "bytes": 6881,
        "path": "docs/architecture/linux-desktop.md",
        "sha256": "eff16110a2892a97ba827354234c11f7c840ec494584289cb1bdbc0a923592ae"
      },
      {
        "bytes": 19644,
        "path": "docs/architecture/portable-oracle-mcp.md",
        "sha256": "a025762617a9748b00771304eebc7769f87327505c561d6cd09c7f477db2b06a"
      },
      {
        "bytes": 1514829,
        "path": "docs/visual-contracts/classic-parity-target-v1.png",
        "sha256": "07ec2644bcbf4f3a9f4eec7aa56d53404d8cbd933b75f7f490e11a25339ba916"
      },
      {
        "bytes": 48946,
        "path": "prompt-exports/oracle-plan-2026-07-26-155226-chat-81a6.md",
        "sha256": "bdd80d5e4e657734f2ca9a3e57ef444259b5655f4e4e5cbe15cc70b80c961ecd"
      },
      {
        "bytes": 3702,
        "path": "prompt-exports/oracle-review-2026-07-26-162552-classic-layout-slice-f0ba.md",
        "sha256": "ae5d3f505dba260f9da1ac42920780098812e87b5a8e7b20a3b35070de299bed"
      },
      {
        "bytes": 2078,
        "path": "script/build_and_run.sh",
        "sha256": "d3c3d0e0e77f5fa6cd466ba6a234d6d23d923e9eda605bb0c846d39309441e57"
      }
    ],
    "sha256": "8583e5073966928a79fe0c0cee72c8b40647106953a656fd2ab40ccf8aed76e4"
  },
  "worktree_before": {
    "entries": [
      {
        "bytes": 185,
        "path": ".codex/environments/environment.toml",
        "sha256": "0d9c84ab61b4224545ec9a1792dbe36b22da071ef20168aaca706b19af3e0c97"
      },
      {
        "bytes": 491,
        "path": ".dockerignore",
        "sha256": "52d0c97f8a7c9df2eb73020eb5991c857172b22d93c84a5b17927c3f351a7403"
      },
      {
        "bytes": 70,
        "path": ".gitignore",
        "sha256": "d4fb36e7f12cdd07e2ba09f53df9ba43214e523842408ce5f46eb5b182912b49"
      },
      {
        "bytes": 3332,
        "path": "Dockerfile.headless",
        "sha256": "9587d0e0eb04743397f8b70f7e5d20f121122799d7f37cfe25cb2305b6cdc487"
      },
      {
        "bytes": 11378,
        "path": "LinuxDesktop/Package.resolved",
        "sha256": "4168e8036facce94634b479e6c98265d504a9d31797840c47cec6daf206341f7"
      },
      {
        "bytes": 3252,
        "path": "LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/DesktopSliceDraftParser.swift",
        "sha256": "e779ff8a0ffd705585859359b4fab8fb98c220eb90e8a4f7d70ec51d3d259624"
      },
      {
        "bytes": 7848,
        "path": "LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/DesktopState.swift",
        "sha256": "14f7006120f4129063b35cb7db78850ad9b9a50ab1c8fe31a4425e0b762b28f6"
      },
      {
        "bytes": 19840,
        "path": "LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/RootShellView.swift",
        "sha256": "92bdb4bd60b1e1474b2ed07655cb952e4800d82cb3d474d1a52326284d62ca05"
      },
      {
        "bytes": 10128,
        "path": "LinuxDesktop/Tests/RepoPromptLinuxDesktopKitTests/DesktopLogicTests.swift",
        "sha256": "f9d50f76b40dbb72ace6932b835ca1c312cea20a56a0d04dae65b340c0121d07"
      },
      {
        "bytes": 2323,
        "path": "LinuxDesktop/Tests/RepoPromptLinuxDesktopKitTests/DesktopWorkspaceIntegrationTests.swift",
        "sha256": "039620dbb70fdb65d571e7a58eb74d28cb03900f5c2116b4b820540e3184484d"
      },
      {
        "bytes": 10438,
        "path": "Package.resolved",
        "sha256": "5ecc892afc41b927a377be4fa1c89d107b2246fac086fd00fb7c8f874d34fa89"
      },
      {
        "bytes": 4448,
        "path": "Package.swift",
        "sha256": "dfefa4df714cfa0ba3316785b072035452132ad18d8457f52ea1b762d95cc4e9"
      },
      {
        "bytes": 12199,
        "path": "README.md",
        "sha256": "af45288cf355d445450516e3f6477bf4b880668cf65439737a3274a8640ce306"
      },
      {
        "bytes": 2442,
        "path": "RepoPromptCodeMap/CodeMapSyntaxArtifactBuilder.swift",
        "sha256": "991f60499785e13462116606eab12a51631c9b98cafa86ec0b9d978aeb765d7b"
      },
      {
        "bytes": 24585,
        "path": "RepoPromptCodeMap/CodeMapSyntaxEngine.swift",
        "sha256": "b9650716f47b07ed08e24924c985e1bd898196cb54d11ffb1e4d1ffa79d10046"
      },
      {
        "bytes": 10264,
        "path": "RepoPromptCodeMap/Extraction/CodeMapCaptureIndex.swift",
        "sha256": "4df3cff08e058d0f05ee42b6cb55976d5951a96a68ab8efc655a3640f7f20c1c"
      },
      {
        "bytes": 5751,
        "path": "RepoPromptCodeMap/Extraction/CodeMapExtractionMemo.swift",
        "sha256": "afa4f65e8dfa40bc92be71ae8f81144bf28e2f3264021cf5b590cc5e31854042"
      },
      {
        "bytes": 126257,
        "path": "RepoPromptCodeMap/Extraction/CodeMapGenerator.swift",
        "sha256": "50dbb0c817eb763455d252bff0ed70857cea658b837f70826b7022517a5f38fa"
      },
      {
        "bytes": 2587,
        "path": "RepoPromptCodeMap/Extraction/CodeMapPCRE2Regex.swift",
        "sha256": "f5525b4e5ca7ef9bfc51edcd4b310dd9bc28dd505e1c4a877a894ea3c838457c"
      },
      {
        "bytes": 19463,
        "path": "RepoPromptCodeMap/Extraction/JSTSSignatureExtractor.swift",
        "sha256": "0593744b1d3bae7441a877bc69c10679f3a11247cca6b7e7a69debde944cff53"
      },
      {
        "bytes": 65833,
        "path": "RepoPromptCodeMap/Extraction/LanguageStrategies/SwiftCodeMapStrategy.swift",
        "sha256": "f80767a5b42593142325f63fefe45f97ceda7100238a9c70c8dd9cbacbd34ed4"
      },
      {
        "bytes": 26665,
        "path": "RepoPromptCodeMap/Extraction/LanguageStrategies/TypeScriptCodeMapStrategy.swift",
        "sha256": "53714f1a2d4a09aec6f4532e3e739c04f1560faec668d7adcd54754a48a1cdac"
      },
      {
        "bytes": 69957,
        "path": "RepoPromptCodeMap/Extraction/LanguageTypeExtractor.swift",
        "sha256": "7c0413635161412e5c49a127851e8d89358d11b29d0c0b1d3fb87bd624ff7f7f"
      },
      {
        "bytes": 5818,
        "path": "RepoPromptCodeMap/Extraction/ReferencedTypesAccumulator.swift",
        "sha256": "6e2b0a1814d630cc998ba6155e1566d6bdbe4c85bd785ce23cd74af795b8f775"
      },
      {
        "bytes": 2364,
        "path": "RepoPromptCodeMap/Extraction/SwiftSignatureParser.swift",
        "sha256": "9590622917e4df3c2e1c045d75aa49e34e9427df4782c52e7dcfa5556bffd761"
      },
      {
        "bytes": 6598,
        "path": "RepoPromptCodeMap/Extraction/TopLevelScanner.swift",
        "sha256": "27d65486cba89eb8d9e7bd489e3af458ae4154bd74307b8566f9d860eac61a9f"
      },
      {
        "bytes": 63122,
        "path": "RepoPromptCodeMap/Extraction/TypeCleaner.swift",
        "sha256": "efd3685a47849be3803e37b01edffe1d9bb108b27b04013d322dcca84cfae701"
      },
      {
        "bytes": 21820,
        "path": "RepoPromptCodeMap/Models/CodeMapArtifactKey.swift",
        "sha256": "832ccea59e786caaecb2d6616670c13022e51d52f982f5fd5af4731087a55201"
      },
      {
        "bytes": 2426,
        "path": "RepoPromptCodeMap/Models/CodeMapCoreSourceSnapshot.swift",
        "sha256": "dfe2e53fe36e1e161421549457f992fefd42c839580676aee0bbf7c471deec51"
      },
      {
        "bytes": 14636,
        "path": "RepoPromptCodeMap/Models/CodeMapSyntaxArtifact.swift",
        "sha256": "9781784581bb1e5c9afdc5ac597f555d875c151a19b0a5bffe839e7faea5bde0"
      },
      {
        "bytes": 14800,
        "path": "RepoPromptCodeMap/Performance/CodeMapPerformanceCollector.swift",
        "sha256": "ab43b29b13d35a0a725b1944642ba80888bdf11541f4d3ae8078b17404d6384c"
      },
      {
        "bytes": 1272,
        "path": "RepoPromptCodeMap/PortableCodeMap.swift",
        "sha256": "d3baba041a20f9dc4fc1daccd9fa9b3a42b0c3b508b432bb91ff772540221f94"
      },
      {
        "bytes": 1638,
        "path": "RepoPromptCodeMap/Queries/GoQueries.swift",
        "sha256": "5cb51de88ec8caa4548961420eafbb06620a21db73d3a6e287e713acd891c297"
      },
      {
        "bytes": 1082,
        "path": "RepoPromptCodeMap/Queries/JavaQueries.swift",
        "sha256": "e9c4db2a1366da4158207b9274b086255d5de48b65f7fb8ff88534553e628993"
      },
      {
        "bytes": 6508,
        "path": "RepoPromptCodeMap/Queries/JavaScriptQueries.swift",
        "sha256": "5cea54b5916607c662a6d2798858cf60aef21f3ce523e89c95951879a145dc65"
      },
      {
        "bytes": 1186,
        "path": "RepoPromptCodeMap/Queries/PythonQueries.swift",
        "sha256": "c31a8d794bca177832d9270506cc3bca2f395782baf8831053c2c3a8e475a405"
      },
      {
        "bytes": 1310,
        "path": "RepoPromptCodeMap/Queries/RubyQueries.swift",
        "sha256": "e770b4bc9d2ee6b8ec4ee802697df8940e14e2800be7ab46603e56f28351c946"
      },
      {
        "bytes": 1971,
        "path": "RepoPromptCodeMap/Queries/RustQueries.swift",
        "sha256": "b95493595fb406183f9fcc7bfb542e812f9e0c0a1ce6a42b9a6f73b7d1e4e70a"
      },
      {
        "bytes": 4670,
        "path": "RepoPromptCodeMap/Queries/SwiftQueries.swift",
        "sha256": "4c0e4820c887074b502e9242e52b4f6965f5f86f1e8337e9c659767c2d51e399"
      },
      {
        "bytes": 3145,
        "path": "RepoPromptCodeMap/Queries/cQueries.swift",
        "sha256": "1efd8de6d2ce20064116435203221786e7e8cbb18a4f40d1038feda2f2e5b7e5"
      },
      {
        "bytes": 1950,
        "path": "RepoPromptCodeMap/Queries/cSharpQueries.swift",
        "sha256": "376c0ed2d8d1d0cfa81ace844a5082c7a2d67a74bfcbe5baa1e7d317404df0f4"
      },
      {
        "bytes": 1678,
        "path": "RepoPromptCodeMap/Queries/cppQueries.swift",
        "sha256": "4018643f8f57007a00d5c2e02b57998de3c9e04833b6ad9d3a3cfa396d7d8562"
      },
      {
        "bytes": 1655,
        "path": "RepoPromptCodeMap/Queries/phpQueries.swift",
        "sha256": "60ea68f631251da4344d38df6de400baf550cfc3bf731c9f4d4f065e512a69f4"
      },
      {
        "bytes": 14560,
        "path": "RepoPromptCodeMap/Queries/typeScript.swift",
        "sha256": "10348ecce15f68534d1f47a4afbbb40633d34d9b52f2a9dd56bb15f9ede7b851"
      },
      {
        "bytes": 7257,
        "path": "RepoPromptCore/WorkspaceContext/Selection/WorkspaceSelectionReducer.swift",
        "sha256": "dc0ddb42c60b5d0f5ca482821a77f418a5be1c2c23706701629588f0cb9216b9"
      },
      {
        "bytes": 4614,
        "path": "RepoPromptCore/WorkspaceContext/Slices/SliceAssembly.swift",
        "sha256": "ce55213585bfa2da5b65179e288c855d09dcac640835cf3606f054bc74e7d82e"
      },
      {
        "bytes": 2671,
        "path": "RepoPromptCore/WorkspaceContext/Slices/SliceRangeMath.swift",
        "sha256": "c89191f3b9643cf96f84d25ffe6da280f1d89cc064b19ceaf26577f7de690308"
      },
      {
        "bytes": 46195,
        "path": "RepoPromptHeadless/HeadlessToolCatalog.swift",
        "sha256": "cfa0b47f2fd07fabdbf75aba12a7ab5b6109f0e513c88b3d5f84899cb6775ee4"
      },
      {
        "bytes": 21412,
        "path": "RepoPromptHeadless/HeadlessWorkspaceContextBuilder.swift",
        "sha256": "3630be0ac260fc3ceac6f47613a3ffd7938e9ae5f5ba33137cee55edb4988d61"
      },
      {
        "bytes": 11207,
        "path": "RepoPromptHeadless/PortableWorkspaceModels.swift",
        "sha256": "3a254a03ca3830ca0a72657562e9318eeac33fa424e925f8723786abaa1ef0b3"
      },
      {
        "bytes": 23617,
        "path": "RepoPromptHeadless/PortableWorkspaceService.swift",
        "sha256": "d469e31148c7b11552c3a6343061492f91113a2126a11aadb15b2672a9b0343d"
      },
      {
        "bytes": 73,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/c/smoke.c",
        "sha256": "3bf77cd1eca994589d4d68709771325b5c57c271df3b8d660e8d8e2880a03f67"
      },
      {
        "bytes": 577,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/cpp/edge_methods.cpp",
        "sha256": "8c56be136cb6b7ca979faf82b8b55726e22e84bb1c06d8dd1a649d3b7b65cc64"
      },
      {
        "bytes": 251,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/cs/smoke.cs",
        "sha256": "d84e8d0676241f244a10d09140f50783afaececebfa3b4dc4987f2b7ef7db1bc"
      },
      {
        "bytes": 245,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/go/smoke.go",
        "sha256": "dbea2ae12828f8bdd4a288a358d7ad3df22b64f0a1f8d042e6169239237d4ce8"
      },
      {
        "bytes": 654,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/java/smoke.java",
        "sha256": "982167e56a4b7300ed5cf0f3fea0fda9b2c857549b76d2ca497ad04e30cf2f0d"
      },
      {
        "bytes": 486,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/js/smoke.js",
        "sha256": "3df59e2ef68cb9bfcf9ac43734c63db150bac2f86589267c8650326d636f19af"
      },
      {
        "bytes": 556,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/php/edge_namespaces.php",
        "sha256": "a6454385533d44ad4dabc4c8d4023dd388f705329a82d2d42ca3017ef482c20b"
      },
      {
        "bytes": 277,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/py/smoke.py",
        "sha256": "52747a8e573441c33a5534d0c9290fab51e7b61f79dc151ab082c58d4cb1e0b1"
      },
      {
        "bytes": 377,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/rb/smoke.rb",
        "sha256": "028562aa4005acac6349adaf6684210ef8e613120c7e22351cf04cc940eeec7c"
      },
      {
        "bytes": 659,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/rs/smoke.rs",
        "sha256": "a82a26653139bcecc6c777bb530f7bfbc1b1d3dae6c9ab0c59b5b21402a3597d"
      },
      {
        "bytes": 301,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/swift/smoke.swift",
        "sha256": "1a076f29734dcf04b1d481390e8f1359dfc6f6b64caa63491b8d8f6e29ae1005"
      },
      {
        "bytes": 403,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/ts/smoke.ts",
        "sha256": "2476eb8a686464469a3bd62fc3c530341af0ab8a5c36a08f29b319d1c9221224"
      },
      {
        "bytes": 385,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Fixtures/tsx/component.tsx",
        "sha256": "eed960e599e37c2d852aa8ec414e001377aac3a775dfa793d0a31b5a0d0a4b20"
      },
      {
        "bytes": 110,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/c_smoke.codemap.txt",
        "sha256": "bcb7ee7b9aa8f26e6d60c49272365847849da01c9dbb2367e61730f121e8e1c1"
      },
      {
        "bytes": 301,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/cpp_edge_methods.codemap.txt",
        "sha256": "c4c9be3d89172919462264ed4e7b008d429ff23ac4a542f9d3b8c9e35ab7aa94"
      },
      {
        "bytes": 281,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/cs_smoke.codemap.txt",
        "sha256": "f6f19d24dadab94b0a26daf1473ca22701e22a071a97fa20cb8ebd3812d795cb"
      },
      {
        "bytes": 132,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/fixture-tree.txt",
        "sha256": "54261ff48293b34ed9f5da5504af692d4030ae7258b681853c454fb476544ec8"
      },
      {
        "bytes": 272,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/go_smoke.codemap.txt",
        "sha256": "c207fcf6022fd8f44f85cfadf3e6365583b6b8c8f231f6368382c3c49e8847b0"
      },
      {
        "bytes": 320,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/java_smoke.codemap.txt",
        "sha256": "ced3e415f74f9d45a44a6649b7989727a62fcfd56aea1a57e9140e797774e561"
      },
      {
        "bytes": 395,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/js_smoke.codemap.txt",
        "sha256": "59ce2e90761f1da0e2be43eb87f2a821da8e63763df9ba1e164c64bdf846f938"
      },
      {
        "bytes": 461,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/php_edge_namespaces.codemap.txt",
        "sha256": "8d438afb884912b8a9847cfa536483542fcd132e13995fe838453a6e11c1aa79"
      },
      {
        "bytes": 257,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/py_smoke.codemap.txt",
        "sha256": "1f8a2c07d024237e69ede4d6650562c6657e0598704555a8e6d24d79ec9b6ca0"
      },
      {
        "bytes": 797,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/rb_smoke.codemap.txt",
        "sha256": "ce45c538123efa5c15f6dd5ab07e070a77e12b0a64c883499213332d20b990c7"
      },
      {
        "bytes": 439,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/rs_smoke.codemap.txt",
        "sha256": "702f45359581b85f9185ce1d7928f2b554d0537462e2a094b37dbc437a3af1e0"
      },
      {
        "bytes": 353,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/swift_smoke.codemap.txt",
        "sha256": "8896f608c762c679e6d3793af11a8dd5d0312c7f2b14765109a6a3ecb7a28a48"
      },
      {
        "bytes": 553,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/ts_smoke.codemap.txt",
        "sha256": "cd5cc0cd9bbe9d8cd9c9cc168c29a24af50241d7f03f2356c46f60d2e3fbc6ab"
      },
      {
        "bytes": 583,
        "path": "RepoPromptHeadlessTests/Fixtures/CodeMapParity/Goldens/tsx_component.codemap.txt",
        "sha256": "1c37575dce832d73d68f24670754510a934f7e5de737a72afc53343c92ff1e21"
      },
      {
        "bytes": 2002,
        "path": "RepoPromptHeadlessTests/PortableCodeMapParityTests.swift",
        "sha256": "52196aa78a4a21d0f975f87faa2fda89291dce6d8ed51fde88e3fe1fc7b934ed"
      },
      {
        "bytes": 29432,
        "path": "RepoPromptHeadlessTests/PortableWorkspaceServiceTests.swift",
        "sha256": "a0c886a3f11afe7219539750704d6b2b0b03e24700142e048a0bcbc53f562a5d"
      },
      {
        "bytes": 45756,
        "path": "RepoPromptHeadlessTests/RepoPromptHeadlessCatalogOracleTests.swift",
        "sha256": "22a0791e36cbb0d4f5597f61121b2444ee919557facf5d843e6c09d9d4a32edb"
      },
      {
        "bytes": 18718,
        "path": "RepoPromptHeadlessTests/RepoPromptHeadlessWorkspaceContextBuilderTests.swift",
        "sha256": "444565609f59a5c89809d9c815011b91e58acbac696105c346e1c6795aef1b85"
      },
      {
        "bytes": 13990,
        "path": "Scripts/classic_pixel_parity_capture.swift",
        "sha256": "bb950c7d396077b46798c39d9a9ffe7fcbabcbba01ae61a1234e8a9fe18bc814"
      },
      {
        "bytes": 12833,
        "path": "Scripts/classic_pixel_parity_metrics.py",
        "sha256": "6246d97c0ffbdac6c784510e61929731f8bf73f139c23518c40126584aa8e0a5"
      },
      {
        "bytes": 4327,
        "path": "Scripts/fixtures/classic-pixel-parity/scenario.json",
        "sha256": "195b7b702262e1573ab3edde06081cff1abd44f31a1ac018fa58e260a790899b"
      },
      {
        "bytes": 341,
        "path": "Scripts/requirements-classic-pixel-parity.txt",
        "sha256": "647f5b2087fcc5375dc45a98e3bcbe1cefe1c169b5f7f534ea6a80e5d7acfbab"
      },
      {
        "bytes": 27363,
        "path": "Scripts/run_classic_pixel_parity.py",
        "sha256": "9acadcb0d63d60a34d5e39c9c464bba8861f455e071247643dad8868eb7b80c3"
      },
      {
        "bytes": 4210,
        "path": "Scripts/smoke_linux_desktop.sh",
        "sha256": "c140273b9c5e105cffcadec404e5ba7cd19fd6d841b8eac775cbb4c60d91d0e6"
      },
      {
        "bytes": 5393,
        "path": "Scripts/test_classic_pixel_parity_metrics.py",
        "sha256": "2d10c762d78358bb3d7fa335bada33274e98d93a3b04f6e522c5718ddf176b16"
      },
      {
        "bytes": 10073,
        "path": "Scripts/verify_linux_desktop_graph.py",
        "sha256": "e98161f312f6e2a4220d3041e0a7e289e644372c78a0e0e72c3b452b40ccd766"
      },
      {
        "bytes": 985,
        "path": "TreeSitterScannerSupport/include/tree_sitter/alloc.h",
        "sha256": "b29c1c9fb7cc82f58c84b376df1297d6e2737a1d655fd356db0859e3c29c2fea"
      },
      {
        "bytes": 10431,
        "path": "TreeSitterScannerSupport/include/tree_sitter/array.h",
        "sha256": "5bdf6ed1a78e3409fd443e085ca967a64c188a5d082aaf7f819bccd53a471c94"
      },
      {
        "bytes": 7624,
        "path": "TreeSitterScannerSupport/include/tree_sitter/parser.h",
        "sha256": "180b893c8734778fd32f372dfbc27bd6ad1cd2221f26150b31256ff6716320d2"
      },
      {
        "bytes": 10576,
        "path": "TreeSitterScannerSupport/src/javascript/scanner.c",
        "sha256": "b3d3f64284d97bf80749c026862427782cf7ecc0b7dc094e6698ab311c9a42c7"
      },
      {
        "bytes": 15470,
        "path": "TreeSitterScannerSupport/src/python/scanner.c",
        "sha256": "6db82134ac2d4c90a1a1475487a625cface02662ebda9b7478cad9c7147e9afe"
      },
      {
        "bytes": 6881,
        "path": "docs/architecture/linux-desktop.md",
        "sha256": "eff16110a2892a97ba827354234c11f7c840ec494584289cb1bdbc0a923592ae"
      },
      {
        "bytes": 19644,
        "path": "docs/architecture/portable-oracle-mcp.md",
        "sha256": "a025762617a9748b00771304eebc7769f87327505c561d6cd09c7f477db2b06a"
      },
      {
        "bytes": 1514829,
        "path": "docs/visual-contracts/classic-parity-target-v1.png",
        "sha256": "07ec2644bcbf4f3a9f4eec7aa56d53404d8cbd933b75f7f490e11a25339ba916"
      },
      {
        "bytes": 48946,
        "path": "prompt-exports/oracle-plan-2026-07-26-155226-chat-81a6.md",
        "sha256": "bdd80d5e4e657734f2ca9a3e57ef444259b5655f4e4e5cbe15cc70b80c961ecd"
      },
      {
        "bytes": 3702,
        "path": "prompt-exports/oracle-review-2026-07-26-162552-classic-layout-slice-f0ba.md",
        "sha256": "ae5d3f505dba260f9da1ac42920780098812e87b5a8e7b20a3b35070de299bed"
      },
      {
        "bytes": 2078,
        "path": "script/build_and_run.sh",
        "sha256": "d3c3d0e0e77f5fa6cd466ba6a234d6d23d923e9eda605bb0c846d39309441e57"
      }
    ],
    "sha256": "8583e5073966928a79fe0c0cee72c8b40647106953a656fd2ab40ccf8aed76e4"
  }
}
```


## Candidate queue

| Rank | Candidate | Target region | Status |
|---:|---|---|---|
| 1 | Fixed Classic instructions section | Instructions/right | queued |
| 2 | Classic sidebar sizing and hierarchy | Sidebar | queued |
| 3 | Compose selector, accent underline, and tab row | Top/right | queued |
| 4 | Files tabs and 50/50 working split | Instructions + builder | queued |
| 5 | Unified preset/action bottom bar | Builder/bottom | queued |
| 6 | Dense Classic colors, borders, radii, and spacing | All | queued |
| 7 | Fully backed Pro Edit surface | Builder/bottom | separate functional phase |

## Corrections

- `baseline-000` is retained as an invalid setup trial. Its fixture parent was
  randomized and the resulting absolute path was visible in the UI, so it is not
  comparable across future iterations. Do not use its score or campaign
  provenance.
- `baseline-001` supersedes it as the authoritative iteration-0 baseline. It uses
  the fixed `/tmp/repoprompt-classic-pixel-parity/repoprompt-portable` fixture,
  explicitly focuses the active `● Context Builder` button to eliminate caret
  blink, canonicalizes screenshot PNG encoding, and records complete provenance at
  `prompt-exports/classic-pixel-parity-artifacts/baseline-001/provenance.json`.
  Frozen hashes: scenario
  `8f9870ad97d8ca9f337bc2c340c4cd0112df3e2773ec3798b5fef6929f748f17`,
  metric
  `6246d97c0ffbdac6c784510e61929731f8bf73f139c23518c40126584aa8e0a5`,
  orchestrator
  `b9d1e5cf765491a5b5e739fb45d35d8c63231adeb55943478c9b699e2becdf8c`,
  capture source
  `969aecd004da323afefc1a2d6bf540dea7725e508441f4a13fbef76056f2675c`,
  binary
  `1a40607fdcd64d5228642f831e55007176719a7a2290a8350849bc093713cb5b`,
  and worktree
  `faf057000b71d8500b5a85002ab14041db2cf6f5d536f0f6f50b7e0d2f050e6e`.

## Run records

<!-- RUN_RECORDS -->

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

### Iteration 0 — `baseline-001` (authoritative)

- Candidate: `baseline` — current UI before any new parity layout/style change.
- Artifacts: `prompt-exports/classic-pixel-parity-artifacts/baseline-001`
- Aggregate score: **76.009331/100**
- Worst region: `sidebar`
- Pixel perfect: `false`
- Settled samples: `3`; aggregate variance `0.000000000000`; range `0.000000000000`
- Raw capture SHA-256: `ab0152d5aac37fb1b0e04f696fe8a6f4653d6656979d6b7e8e8b0e4e0a54503b`

| Region | NMAE | SSIM | Score | Variance (score) |
|---|---:|---:|---:|---:|
| full | 0.095794 | 0.616895 | 76.055027 | 0.000000000000 |
| sidebar | 0.188560 | 0.470913 | 64.117685 | 0.000000000000 |
| top | 0.053825 | 0.671657 | 80.891588 | 0.000000000000 |
| instructions | 0.078100 | 0.617226 | 76.956316 | 0.000000000000 |
| builder_bottom | 0.060221 | 0.698000 | 81.888950 | 0.000000000000 |

- Boundary offsets: sidebar `-43 px`; top/right `-51 px`; instructions
  `-16 px`.
- Decision: `continue`.
- Tests: metric unit suite passed; three canonical capture hashes were
  byte-identical.
- Oracle verdict: baseline only; visual stop gate not evaluated.

### Iteration 1 — `iteration-001-sidebar-geometry` (reverted)

- Candidate: `classic-sidebar-geometry` — set the default viewport to
  `1504×960`, bind the sidebar to Classic `AppSidebarSizing` ideal width `364`,
  derive its `344`-point content width from `10`-point horizontal padding, and
  remove the competing `280`/`250` literals.
- Attempted files:
  `LinuxDesktop/Sources/RepoPromptLinuxDesktop/RepoPromptLinuxDesktopApp.swift`,
  `LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/DesktopLayoutMetrics.swift`,
  `LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/RootShellView.swift`, and
  `LinuxDesktop/Tests/RepoPromptLinuxDesktopKitTests/DesktopLogicTests.swift`.
- Artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-001-sidebar-geometry`
- Aggregate score: **76.009331 → 74.590130** (`-1.419201`).
- Worst region: `sidebar`.
- Pixel perfect: `false`.
- Settled samples: `3`; aggregate variance `0.000000000000`; range
  `0.000000000000`.
- Raw capture SHA-256:
  `54d790c687fc7d26b7a725a27fbe1a86c47079a0b1b9c05a68c3f8f01f2aaec4`.

| Region | NMAE | SSIM | Score | Δ baseline |
|---|---:|---:|---:|---:|
| full | 0.104930 | 0.599039 | 74.705415 | -1.349613 |
| sidebar | 0.221014 | 0.420515 | 59.975067 | -4.142618 |
| top | 0.058593 | 0.652501 | 79.695411 | -1.196178 |
| instructions | 0.078100 | 0.617226 | 76.956337 | +0.000021 |
| builder_bottom | 0.062408 | 0.687859 | 81.272566 | -0.616384 |

- Boundary offsets: normalized sidebar `-43 px → -5 px`; top/right remained
  `-51 px`; instructions remained `-16 px`.
- Raw registration evidence: the strongest sidebar edge is `x=727` in both the
  Classic target and this candidate. A sizing-only retry would move an already
  registered raw divider and cannot fix the enlarged light AppKit sidebar
  material that caused the score regression.
- Tests: all `21` LinuxDesktop tests passed with the candidate, including the
  focused Classic sizing invariants; the three canonical capture hashes were
  byte-identical.
- Decision: `revert_regression`. All candidate production and test hunks were
  reverted. A future sidebar-material/style iteration must address the color
  mismatch before retrying the wider Classic geometry.
- Oracle verdict: the sizing hypothesis was falsified by the zero-variance
  aggregate and sidebar regressions; no visual stop gate was requested.

### Iteration 2 — `iteration-002-sidebar-opaque-surface`

- Candidate: `classic-sidebar-opaque-surface` — leave the reverted baseline
  geometry unchanged and cover the inherited AppKit sidebar material with one
  fully opaque SwiftCrossUI sRGB background.
- Palette provenance: three visually verified glyph-free `40×40` target swatches
  centered at raw pixels `(500,450)`, `(500,1150)`, and `(500,1780)` have the
  combined channel median **RGB `(29,31,33)`** (`#1D1F21`). The authoritative
  baseline material is modal **RGB `(71,73,74)`**. Against those `4,800` target
  pixels, normalized mean absolute channel distance is `0.162565904139` for the
  inherited material versus `0.000931372549` for the fixed surface.
- Production file:
  `LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/RootShellView.swift`.
  No layout, window, width, control, typography, detail-pane, or Pro Edit code
  changed. The first modifier placement filled the complete pane, so the allowed
  fallback was not used.
- Artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-002-sidebar-opaque-surface`
- Aggregate score: **76.009331 → 77.940145** (`+1.930814`).
- Worst region: `sidebar`.
- Pixel perfect: `false`.
- Settled samples: `3`; aggregate variance `0.000000000000`; range
  `0.000000000000`.
- Raw capture SHA-256:
  `404bf624083f13d3ba3d8fcab765ecafce7bccf90eecefac65e24a73fcf37238`.

| Region | NMAE | SSIM | Score | Δ baseline |
|---|---:|---:|---:|---:|
| full | 0.078484 | 0.637558 | 77.953728 | +1.898701 |
| sidebar | 0.116976 | 0.556364 | 71.969395 | +7.851710 |
| top | 0.053825 | 0.671657 | 80.891588 | +0.000000 |
| instructions | 0.078100 | 0.617226 | 76.956316 | +0.000000 |
| builder_bottom | 0.060221 | 0.698000 | 81.888950 | +0.000000 |

- Boundary offsets remained unchanged: sidebar `-43 px`, top/right `-51 px`,
  and instructions `-16 px`.
- Tests: all `20` LinuxDesktop tests passed; all `10` pixel-metric tests passed;
  `git diff --check` passed. The three canonical raw capture hashes were
  byte-identical.
- Screenshot inspection: the opaque surface covers the sidebar continuously from
  the content area below the title bar through the rounded bottom corners, with
  no material leakage or geometry shift. Existing buttons and file-row controls
  intentionally retain their baseline colors. The captured modal surface is
  `RGB (38,41,44)`, not the source `RGB (29,31,33)`, because SwiftCrossUI 0.8.0's
  AppKit backend constructs `NSColor(calibratedRed:green:blue:alpha:)`; future
  palette work must account for that transform rather than assuming byte-identity.
- Decision: `accept_continue`. This iteration is a **PASS** because aggregate and
  sidebar scores improved well outside zero variance while every non-target
  region was byte-metrically unchanged.

### Iteration 3 — `iteration-003-sidebar-opaque-geometry` (reverted)

- Candidate: `classic-sidebar-opaque-geometry` — re-land the exact Iteration-1
  Classic geometry tuple unchanged on top of the accepted opaque sidebar:
  requested viewport `1504×960`, sidebar minimum/ideal/maximum widths
  `325/364/425`, `10`-point horizontal padding, and derived `344`-point content
  width. The RGB `(29,31,33)` sidebar background modifier remained unchanged.
- Attempted files:
  `LinuxDesktop/Sources/RepoPromptLinuxDesktop/RepoPromptLinuxDesktopApp.swift`,
  `LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/DesktopLayoutMetrics.swift`,
  `LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/RootShellView.swift`, and
  `LinuxDesktop/Tests/RepoPromptLinuxDesktopKitTests/DesktopLogicTests.swift`.
- Artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-003-sidebar-opaque-geometry`
- Aggregate score: **77.940145 → 77.296284** (`-0.643861`).
- Worst region: `sidebar`.
- Pixel perfect: `false`.
- Settled samples: `3`; aggregate variance `0.000000000000`; range
  `0.000000000000`.
- Raw capture SHA-256:
  `eb2118366259a22846fa11bf33a20136d092a13215e578452c80d1ed55a72205`.

| Region | NMAE | SSIM | Score | Δ Iteration 2 |
|---|---:|---:|---:|---:|
| full | 0.081446 | 0.628777 | 77.366560 | -0.587168 |
| sidebar | 0.123897 | 0.543491 | 70.979718 | -0.989677 |
| top | 0.058593 | 0.652501 | 79.695411 | -1.196178 |
| instructions | 0.078100 | 0.617226 | 76.956337 | +0.000021 |
| builder_bottom | 0.062408 | 0.687859 | 81.272566 | -0.616384 |

- Boundary evidence: the strongest raw sidebar edge is `x=727` in both the
  Classic target and this candidate. Normalization retains the previously known
  residual: candidate `x=465`, target `x=470`, delta `-5 px`.
- Acceptance gate: **FAIL**. Aggregate did not exceed `77.940145`, sidebar did
  not exceed `71.969395`, and non-sidebar regressions exceeded the `0.3` limit
  in top/right (`-1.196178`) and builder/bottom/right (`-0.616384`).
- Tests: all `21` LinuxDesktop tests passed with the candidate, including the
  focused Classic geometry invariant; all `10` pixel-metric tests passed. The
  three canonical raw capture hashes were byte-identical.
- Screenshot inspection: the opaque sidebar surface covered the widened pane
  continuously to the new divider and through its bottom edge. No inherited
  material leaked at the widened edge, so the single allowed background-placement
  fallback was not used.
- Decision: `revert_regression`. The exact geometry and focused test hunks were
  reverted; the accepted Iteration-2 opaque background remains. Wider sidebar
  geometry is now rejected even when paired with the corrected opaque surface.

### Iteration 4 — `iteration-004-instructions-card-corrected-trial` (reverted)

- Candidate: `classic-instructions-card` — replace the free-standing
  Instructions heading and flexible editor with one bounded card in
  `RootShellView.swift`: `290`-point total height, `40`-point integrated header,
  divider, `249`-point editor, `16`-point radius, `0.5`-point gray stroke, and
  retained editor RGB `(35,40,42)`.
- Target geometry preflight: the normalized target card occupies approximately
  `y=245...630`, with its principal top stroke at `y=246`, header divider at
  `y=298...299`, and bottom stroke at `y=627...629`. Its `383`-pixel normalized
  height converts through the candidate capture scale
  `2 × (1252 / 1898) = 1.319283` pixels/point to `290.31` host points. The
  initial card trial matched the height but landed at `y=130...510`; the single
  permitted geometry correction added `88` points
  (`116 / 1.319283 = 87.93`) of top registration and landed the card at
  `y=245...630`.
- Numeric gate: the retained instructions score of `76.956316` has a theoretical
  region ceiling of `+23.043684` points and a direct aggregate-weight ceiling of
  `+2.880461` points before full-image coupling. PASS required aggregate
  `>77.941216`, instructions `>76.956316`, sidebar unchanged within the `0.10`
  hard cap, and no other-region regression beyond that cap.
- Retained-state preflight artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-004-retained-preflight`.
- Initial unregistered trial artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-004-instructions-card-trial`.
- Corrected authoritative artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-004-instructions-card-corrected-trial`.
- Aggregate score: **77.941216 → 77.198220** (`-0.742995`).
- Worst region: `sidebar`.
- Pixel perfect: `false`.
- Settled samples: `3`; all canonical raw captures were byte-identical.
- Raw capture SHA-256:
  `92870f23b6f2a641fb92e81ef70b082d61f696f0200d28ab92fb8117395761f6`.

| Region | NMAE | SSIM | Score | Δ retained |
|---|---:|---:|---:|---:|
| full | 0.086629 | 0.629516 | 77.144374 | -0.810355 |
| sidebar | 0.120155 | 0.546890 | 71.336780 | -0.634172 |
| top | 0.052668 | 0.678343 | 81.283790 | +0.390406 |
| instructions | 0.104728 | 0.589936 | 74.260439 | -2.695877 |
| builder_bottom | 0.059549 | 0.702094 | 82.127255 | +0.237099 |

- Tests: all `20` LinuxDesktop tests passed before and after the revert; all
  `10` pixel-metric tests passed; `git diff --check` passed. The measured
  candidate used SwiftCrossUI revision
  `a6d206370812e3b9edba259d167e848892c5013d`, nested lockfile SHA-256
  `4168e8036facce94634b479e6c98265d504a9d31797840c47cec6daf206341f7`,
  and binary SHA-256
  `b0acf636d1082695e6e33b9603f9e3d675d3817761da44751d768dd5ced0d581`.
- Screenshot inspection: the corrected card's top, header divider, and bottom
  strokes registered vertically with the target to within one normalized pixel,
  and its editor surface, labels, binding, fonts, and behavior were preserved.
  The frozen scenario intentionally has empty instructions while the target card
  contains dense text, and the candidate's horizontal start remains displaced
  by the retained sidebar geometry. Those mismatches overwhelmed the geometry
  gain and also moved the rest of the flexible stack enough to violate the
  sidebar invariant.
- Decision: `revert_regression`. Both candidate card hunks and the sole geometry
  correction were reverted. `RootShellView.swift` returned exactly to preflight
  SHA-256
  `7121ea12f2ea00a4121a813b0785b8ded03b51c978134c885cc2890524158850`.

### Iteration 5 — `iteration-005-dense-fixture` (reverted)

- Candidate: `classic-dense-compose-fixture` — change only the screenshot
  fixture and harness to seed a deterministic target-like workspace: a separate
  32-file ASCII-sorted manifest, fixed `repoprompt-classic` root, six selected
  non-Swift files, 1,038 characters of instructions, and a completed six-entry
  context preview. No `RootShellView`, `DesktopState`, service, Oracle, provider,
  network, or Pro Edit behavior changed.
- Content contract: UTF-8/LF text only; ASCII path ordering; no ignore files,
  timestamps, random paths, provider configuration, or network access. The
  explicit `classic-dense-compose-v1` mode failed closed on mode mismatch,
  manifest drift, missing selections, or missing context readiness.
- Precondition artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-005-precondition`.
- Candidate artifacts:
  `prompt-exports/classic-pixel-parity-artifacts/iteration-005-dense-fixture`.
- Aggregate score: **77.999798 → 75.928980** (`-2.070818`).
- Worst region: `instructions`.
- Pixel perfect: `false`.
- Settled samples: `3`; aggregate variance `0.000000000000`; range
  `0.000000000000`.
- Precondition raw capture SHA-256:
  `78fd2735a7bf2dc3fdd8a0fdfae79053e431fe02b6d431d8780c89f8c78ab88f`.
- Candidate raw capture SHA-256:
  `c1da04af45de89dd26871417716d1891f8c280ceaa23281a3383f8ca7b4ef9ff`.
- Candidate settle capture SHA-256:
  `7585236db78aded1200c1c67bf9ad01cdf326d2a7dce388b1d4b3a2075dd9191`;
  the following three measured captures were byte-identical.

| Region | Precondition | Candidate | Δ precondition |
|---|---:|---:|---:|
| full | 78.019891 | 75.764002 | -2.255889 |
| sidebar | 72.061720 | 72.150270 | +0.088550 |
| top | 80.891588 | 80.740990 | -0.150598 |
| instructions | 76.956316 | 70.656590 | -6.299726 |
| builder_bottom | 82.009196 | 80.827981 | -1.181215 |

- Trial hashes: scenario
  `29132658875e09e1ae779234d1dc4d1343e512052408d009244e96c5a6ecba7d`,
  manifest
  `c41232b1e07a87c9a54eb575abc2f636d4b437e6ef7e34e674bea8c5b2cc818d`,
  fixture content
  `1d6111e493ce5dccc5fac37d5513d517782fc5610212b09e72f1f2cf91afa2d7`,
  orchestrator
  `92a253a9af523c29ea2927ef57c44777398271c9d308bf44d791d978aa345efe`,
  and capture source
  `f14526131cbe8f68a596c15d21e81dfca53525d76814add80b29c79d8da6af3e`.
- Tests: all `14` harness/metric tests passed; Swift capture helper typecheck
  passed. Visual inspection confirmed the selected inventory, deterministic
  instructions, six canonical preview entries, and fixed root were present.
- Acceptance gate: **FAIL**. Aggregate regressed outside zero variance, neither
  required text-bearing region improved, and only the sidebar held within the
  material-regression limit.
- Decision: `revert_regression`. The dense scenario, separate manifest,
  explicit fixture-mode harness support, and its support test were removed.
  The precondition scenario and harness hashes were restored; measured artifacts
  remain as evidence that content density cannot compensate for the retained
  production geometry.

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

### Iteration 7 — classic-sidebar-selectable-file-list (runtime-aborted, reverted)

- Candidate: replace only the sidebar file inventory `ScrollView` / `VStack` /
  per-row `Button` subtree with a native selectable SwiftCrossUI `List`,
  preserving labels, ordering, filtering, and cap behavior. Non-nil selection
  focused a file and never mutated workspace selection.
- Pinned API audit: SwiftCrossUI revision
  `a6d206370812e3b9edba259d167e848892c5013d` exposes
  `List<SelectionValue: Hashable, RowView>` with
  `Binding<SelectionValue?>`, so the `String?` candidate type-checked. Runtime
  audit found the decisive cross-backend blocker: the AppKit backend's
  `selectionIndexesForProposedSelection` force-unwraps
  `proposedSelectionIndexes.first!` when selection is enabled, including the
  empty set used to clear an optional selection. GTK handles nil safely with
  `unselectAll()`. Backend-specific workarounds were outside this candidate.
- Fresh control: three byte-identical samples in
  `iteration-007-precondition`; aggregate `78.378540460022`, full
  `78.380637014162`, sidebar `73.836160908190`, top `80.891588358083`,
  instructions `76.956315915785`, and builder `81.821710441472`.
- Fresh control raw SHA-256:
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`;
  normalized SHA-256:
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`.
- Frozen hashes remained target
  `07ec2644bcbf4f3a9f4eec7aa56d53404d8cbd933b75f7f490e11a25339ba916`,
  scenario
  `8f9870ad97d8ca9f337bc2c340c4cd0112df3e2773ec3798b5fef6929f748f17`,
  and nested lockfile
  `4168e8036facce94634b479e6c98265d504a9d31797840c47cec6daf206341f7`.
- Candidate provenance: retained `RootShellView.swift` SHA-256
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`;
  candidate source SHA-256
  `0be0b5e715ec4b8986af145c3bd061226eac9fcf3a090b4d9c4162b6618ef384`;
  candidate release executable SHA-256
  `7f69abc850c7abc82c2399aa392568e560692092696bc1efcfc3de288e44b718`.
- Runtime result: the canonical candidate exited with status `-6` before
  readiness. The failed build/stdout/stderr evidence is preserved in
  `iteration-007-sidebar-selectable-file-list-runtime-abort`. No candidate
  screenshots, hashes, or regional metrics exist, so the acceptance gate failed
  automatically and score deltas are `not measured`.
- Functional macOS result: all `61` candidate tests passed. Computer Use found
  the candidate application, but ScreenCaptureKit returned `-3811`; Peekaboo
  then showed the native list expanding the window to `1504 × 24219`.
  Focus/search/reload could not be exercised in that invalid geometry.
- Candidate Linux/graph/Xvfb validation was not run because the Docker socket
  was absent and the local Docker application could not be launched. This is
  reported as unavailable, not passed.
- Reversion and checks: only the candidate inventory hunk was reverted.
  `RootShellView.swift` returned exactly to SHA-256
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`;
  all `61` macOS tests, all `10` metric tests, and `git diff --check` passed.
  Earlier Iteration-6 validation of this exact retained source passed all `61`
  Linux GTK tests, the graph verifier, and Xvfb smoke; it is retained-state
  evidence and is not presented as candidate validation.
- Host-recovery note: the candidate persisted an invalid `24219`-point AppKit
  frame. Only the exact
  `NSWindow Frame TupleView1<RootShellView>-0` preference key was removed and
  `cfprefsd` restarted. Post-revert capture retries remained blocked by local
  LaunchServices registration failures; their separate abort artifacts are
  retained. The repository source itself is restored exactly.
- Decision: `revert_runtime_failure`. The native `List` candidate is rejected
  because the pinned AppKit implementation cannot safely represent the required
  optional selection and the candidate never reached deterministic capture.
  No Iteration-7 production source is retained.

### Iteration 8 — classic-sidebar-scroll-surface (no effect, reverted)

- Candidate: add exactly one
  `Color(red: 0.086810246, green: 0.092231961, blue: 0.097734573)`
  background modifier to the existing first sidebar file-inventory
  `ScrollView`. No hierarchy, row, geometry, state, fixture, harness, or
  cross-backend behavior changed.
- Fresh precondition: `iteration-008-precondition` produced three byte-identical
  samples and exactly reproduced retained `RootShellView.swift` SHA-256
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`,
  raw SHA-256
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`,
  normalized SHA-256
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`,
  aggregate `78.378540460022`, full `78.380637014162`, sidebar
  `73.836160908190`, top `80.891588358083`, instructions
  `76.956315915785`, and builder bottom `81.821710441472`. Every variance
  and range was zero.
- Capture-state correction: the first candidate set was internally
  deterministic but its window was inactive, removing the active traffic-light
  state and blue Context Builder focus ring. Its apparent aggregate
  `78.438193209493` and sidebar `73.928486088828` gains are quarantined at
  `iteration-008-sidebar-scroll-surface-contaminated-inactive-window` and are
  non-authoritative because its control-to-candidate diff extended outside the
  inventory viewport.
- Authoritative A/B method: an external temporary activation watcher detected
  only the harness-created executable under
  `/tmp/repoprompt-classic-pixel-parity/` and called
  `NSRunningApplication.activate` before the unchanged canonical helper applied
  its `● Context Builder` AX focus selector. The same watcher source and binary
  were used for both sides. Watcher source SHA-256:
  `21293229e3c6e65bf5a57a917aa676a49c64f4cc52ae57a5674516f8b8c715b7`;
  binary SHA-256:
  `20c77c2ac3d68d69410b116ad64e84132b53bf51964cf90e4097139953ac1323`.
  Both activation logs record `activated=true`; source and logs are preserved
  with `iteration-008-activation-control` and
  `iteration-008-sidebar-scroll-surface`.
- Authoritative result: candidate source SHA-256
  `4df0dc11386a74dfded1094c76821e8266c6cd25f8408818f81e74055ce19ea4`;
  candidate release executable SHA-256
  `978fa87ef603e03b115dd5f68497bedd5d4449e7bf0a8df88050f03fd8224de2`.
  All three candidate samples were byte-identical to one another and to the
  activation-matched control: raw SHA-256
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`
  and normalized SHA-256
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`.
  Aggregate, full, sidebar, top, instructions, and builder-bottom deltas were
  each exactly `0.000000000000`; the authoritative control-to-candidate diff
  contained zero changed pixels.
- Live functional inspection: after reversion, Computer Use confirmed normal
  window geometry and a `541`-file workspace capped at `500` visible rows.
  Searching `RootShellView` reduced the inventory to the single expected path;
  clearing restored `500`; Reload completed with `Reloaded 541 files.`
- Validation after reversion: all `61` macOS LinuxDesktop tests, all `10`
  pixel-metric tests, and `git diff --check` passed.
  `verify_linux_desktop_graph.py` was invoked locally and correctly refused
  because compile/link verification requires Linux. Docker remained
  unavailable, so candidate Linux GTK, graph, and Xvfb gates were not run after
  the visual gate had already rejected the modifier. Earlier Iteration-6
  validation of the exact restored source remains the latest Linux evidence.
- Oracle consultation: pair
  `CF0B1FB6-9658-4691-A97E-0BBCC336EC85`; Primary
  `h:f33a769128bffc0a` failed during provider browser startup and produced no
  recommendation. Secondary `h:10d84932c7fbff24` recommended continuing with
  one distinct Iteration-9 candidate: apply the calibrated background to the
  inner file-content `VStack`, not the no-op `ScrollView`. Both outcomes were
  acknowledged; the recommendation is deferred to the parent lane.
- Decision: `revert_no_effect`. Strict aggregate and sidebar improvement were
  both absent, so the sole modifier was removed. `RootShellView.swift` is
  restored exactly to SHA-256
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`;
  no Iteration-8 production source is retained.

### Iteration 9 — classic-sidebar-file-content-vstack-surface (no effect, reverted)

- Candidate: add exactly one
  `Color(red: 0.086810246, green: 0.092231961, blue: 0.097734573)`
  background modifier to the inner file-content `VStack` directly inside the
  first sidebar inventory `ScrollView`. The `ScrollView`, outer sidebar,
  hierarchy, rows, geometry, state, fixture, harness, and backend behavior were
  unchanged.
- Fresh authoritative control: `iteration-009-activation-control` used the
  preserved Iteration-8 activation watcher and produced three byte-identical
  samples. The watcher logged `activated=true`; retained
  `RootShellView.swift` SHA-256 was
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`;
  control release executable SHA-256 was
  `bec6f0c5a39b0258bf1c94dd762c062d5417c580161ccc91a331bd6dbb82be79`.
  Raw SHA-256 exactly reproduced
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`;
  normalized SHA-256 exactly reproduced
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`.
- Control metrics exactly reproduced aggregate `78.378540460022`, full
  `78.380637014162`, sidebar `73.836160908190`, top `80.891588358083`,
  instructions `76.956315915785`, and builder bottom `81.821710441472`.
  All sample variance and range values were zero.
- Activation provenance: the exact same watcher source and binary were used for
  control and candidate. Watcher source SHA-256:
  `21293229e3c6e65bf5a57a917aa676a49c64f4cc52ae57a5674516f8b8c715b7`;
  binary SHA-256:
  `20c77c2ac3d68d69410b116ad64e84132b53bf51964cf90e4097139953ac1323`.
  Source and activation logs are preserved in both Iteration-9 artifact
  directories.
- Candidate result: source SHA-256
  `59eab84774434436ccae6c061714d8444812796bfb3eadd6f537a1b4819c9b5e`;
  candidate release executable SHA-256
  `eb3d82d101195242639ca6c099260f1fe40facbe84dfea0fc9dda4425ca0c062`.
  The watcher logged `activated=true`, and all three candidate samples were
  byte-identical to one another and to control. Candidate raw SHA-256 remained
  `55541bc14cf0b4943df92746416cfd76560e63f5dff372d96dfa0786ef611fbc`;
  normalized SHA-256 remained
  `a4791a11a6a61c0c38c758482467971745b026a82a146c123e31ff30758c0a75`.
- Metric and localization result: aggregate, full, sidebar, top, instructions,
  and builder-bottom deltas were each exactly `0.000000000000`. The
  authoritative control-to-candidate comparison contained zero changed pixels.
  Required aggregate and sidebar strict-improvement gates therefore failed;
  non-target regions remained exact.
- Live candidate validation: Computer Use confirmed normal window geometry,
  changed search from the `500`-row cap to the single expected
  `LinuxDesktop/Sources/RepoPromptLinuxDesktopKit/RootShellView.swift` result,
  cleared back to `500`, and completed Reload with `Reloaded 577 files.`
- Validation after reversion: all `61` macOS LinuxDesktop tests, all `10`
  pixel-metric tests, and `git diff --check` passed. Candidate Linux GTK,
  graph, and Xvfb gates were not run because the authoritative visual gate had
  already rejected the no-op modifier; Iteration 6 remains the latest Linux
  validation of the exact restored source.
- Oracle consultation: pair
  `CF0B1FB6-9658-4691-A97E-0BBCC336EC85`; Primary
  `h:f8fabb9091ec606f` again failed during provider browser startup and produced
  no recommendation. Secondary `h:93c28f21a95a8b50` was adopted: stop further
  production visual edits at a visual-diagnosis plateau. Iterations 8 and 9
  conclusively eliminate both nested sidebar paint boundaries, while remaining
  queued changes are rejected or broader multi-property guesses. Both outcomes
  were acknowledged.
- Resume condition: obtain a new target/review-sheet diagnosis identifying one
  untested SwiftCrossUI-owned mechanism, precise target-region pixel evidence,
  the responsible current control layer, a single cross-backend change, and a
  capture plan excluding activation, focus, geometry, and fixture confounds.
- Decision: `revert_no_effect_stop_for_diagnosis`. The sole modifier was
  removed. `RootShellView.swift` is restored exactly to SHA-256
  `32f92d2aa13e1c80336846bf038247aebbb42c4b716098e26d5fdd5661de0f45`;
  no Iteration-9 production source is retained.
