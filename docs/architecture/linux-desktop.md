# Linux desktop architecture

## Scope

`LinuxDesktop/` is a separate SwiftPM package for the native GTK 4 product `repoprompt-linux-desktop`. The same executable supports explicit macOS QA with `--macos`, where SwiftCrossUI selects its native AppKit backend; this does not add Apple dependencies to the Linux build graph. Its Classic-inspired workspace keeps a compact explorer beside Compose, Selected Files, Context Builder, paired Oracle, and Pro Edit panels. It opens configured workspace roots, searches a flattened file list, focuses a file, chooses full/slice/manual-codemap selection, edits described line ranges, uses derived automatic codemaps, previews canonical context metadata/content, and generates a dual-lane plan, review, or Pro Edit result when Oracle environment configuration is present.

The application window title is `RepoPrompt Portable`. Normal browsing, selection, context, and Oracle generation are read-only. The desktop has one deliberately separate write path: after a user chooses either the Primary or Secondary Pro Edit artifact, strict parsing and preflight produce a materialized per-file preview, and only the explicit **Apply & Save** action may call the desktop transaction writer. Instructions, selection, context, Oracle results, and unapplied previews remain in process memory.

## Package and dependency boundary

The root package exports `RepoPromptHeadless` as a library but does not depend on SwiftCrossUI. The nested package depends on the parent through `path: ".."` and pins `swift-cross-ui` exactly to `0.8.0` in `LinuxDesktop/Package.swift` and `LinuxDesktop/Package.resolved`.

SwiftPM resolves the local parent and SwiftCrossUI in one graph. SwiftCrossUI `0.8.0` requires `swift-log` `1.6.4` or newer, so the root manifest intentionally declares `swift-log` as `1.6.3..<1.7.0` instead of exact `1.6.3`. The root lockfile remains valid at `1.6.3` for the headless graph, while the nested lockfile resolves `1.6.4`. Do not add SwiftCrossUI to the root manifest or update the root lockfile for this coupling.

The target graph is:

```text
RepoPromptLinuxDesktop
├── RepoPromptLinuxDesktopKit
├── RepoPromptHeadless
├── SwiftCrossUI
└── DefaultBackend → GtkBackend on Linux

RepoPromptLinuxDesktopKit
├── RepoPromptHeadless
└── SwiftCrossUI
```

`PortableWorkspaceService` is the typed in-process boundary. The desktop uses `workspace()`, cancellable `files()`, `selection()`, `mutateSelection(_:)` and its full/slice/manual-codemap/automatic-toggle conveniences, cancellable `previewContext()`, `generatePlan(instructions:)`, `generateReview(instructions:)`, `generateProEdit(instructions:)`, strict `resolveProEditArtifact`, and preview-only `materializeProEditPreview`, together with their typed value models. Selection transition rules, path validation, canonical rendering, codemap extraction, and Oracle execution remain shared headless implementation details. The service shares the existing bootstrap, session selection store, context builder, and concurrent Oracle workflow with the MCP catalog; the desktop-only inventory filters resolved paths outside the roots and non-regular targets without changing MCP `file_search`. No MCP/JSON subprocess or fallback transport is used. SwiftCrossUI, GTK, and desktop sources remain outside the root dependency graph and `Dockerfile.headless`.

`DesktopProEditService` is the desktop-only mutation boundary. A materialization captures the exact workspace, selection, canonical paths, source bytes, metadata, and proposed bytes in a single current session. The UI renders the session's ordered proposals, statuses, replacement diffs, and original-to-proposed content before enabling **Apply & Save**. Apply revalidates the session and every target, stages same-directory files, performs the transaction, rolls back a partial commit, and returns the exact applied paths. Parse, preflight, materialization, cancellation, and reset never write files. `RootShellView` never writes directly; it can mutate the workspace only by calling `DesktopProEditService.apply(session.id)`.

The desktop write boundary is not linked into `HeadlessToolCatalog`. The seven MCP tools and the direct JSONL CLI remain read-only: their `pro_edit` result is still two independent opaque artifacts, and neither surface can materialize or apply a desktop session.

SwiftPM resolves packages across platforms, so `LinuxDesktop/Package.resolved` can contain pins used by non-Linux SwiftCrossUI backends. Those pins do not prove that a backend is compiled. `Scripts/verify_linux_desktop_graph.py` checks the declared graphs, compiled modules, and final Linux linkage instead.

## Prerequisites

Ubuntu build dependencies:

```bash
sudo apt-get update
sudo apt-get install --yes --no-install-recommends \
  clang git libgtk-4-dev pkg-config
```

Xvfb smoke dependencies:

```bash
sudo apt-get install --yes --no-install-recommends xvfb xauth x11-utils
```

Running the binary requires Git for hierarchical `.gitignore` evaluation, GTK 4, and an X11 or Wayland display. Provider-free canonical preview, including manual and derived automatic codemaps, needs no API key. Generate Plan, Generate Review, and Pro Edit use the same `OPENCODE_API_KEY` or complete `REPOPROMPT_ORACLE_*` environment configuration as the headless products.

## Build, test, run, and verify

```bash
export SCUI_DEFAULT_BACKEND=GtkBackend

swift build --package-path LinuxDesktop \
  --product repoprompt-linux-desktop \
  --disable-automatic-resolution

swift test --package-path LinuxDesktop --disable-automatic-resolution

swift run --package-path LinuxDesktop \
  repoprompt-linux-desktop --root /path/to/workspace

python3 Scripts/verify_linux_desktop_graph.py
bash Scripts/smoke_linux_desktop.sh
```

The graph verifier proves that:

- the root manifest and lockfile exclude SwiftCrossUI;
- the nested manifest and lockfile pin the exact approved SwiftCrossUI `0.8.0` GitHub URL and revision;
- all three nested targets use exactly their intended target/product dependencies;
- portable-owned sources do not import Apple UI frameworks;
- `Dockerfile.headless` excludes the desktop and its dependencies;
- a clean Linux build compiles `GtkBackend`, not any other platform backend;
- the executable links GTK 4 and `ldd` reports no missing libraries.

The smoke creates a temporary workspace and sentinel file, clears all provider environment variables, forces `SCUI_DEFAULT_BACKEND=GtkBackend` and X11, and launches under Xvfb. It requires both the `RepoPrompt Portable` window and the post-bootstrap `ready: 1 files` signal, rejects GTK/GLib/display criticals, verifies an invalid root reports startup failure without readiness, terminates the application, and removes the temporary workspace.

## Nested lockfile rule

Do not run a root resolution to update desktop dependencies. When an intentional nested dependency update is approved, use:

```bash
swift package --package-path LinuxDesktop resolve
```

Only `LinuxDesktop/Package.resolved` should change. The root `Package.resolved` belongs to the headless package and release graph.

## Packaging and release boundary

Native packaging is deferred. A `.deb`, AppImage, Flatpak, tarball, desktop entry, or icon would require a distribution, runtime-support, signing, and release-artifact policy that does not exist yet. The current deliverable is the native SwiftPM executable product `repoprompt-linux-desktop`.

The existing headless container, `Dockerfile.headless`, `publish-container.yml`, release assets, tags, MCP schema/version, and release channel do not include the desktop and remain unchanged.

## Non-goals

- Shipping Apple frameworks or UI backends in the Linux build/release graph; AppKit is used only by the explicit `--macos` QA launch.
- Native file trees or file/folder pickers.
- General-purpose editing, syntax highlighting, review-diff discovery, git operations, or write tools outside the explicit Pro Edit preview/apply transaction.
- Presets, Agent Mode, persistence, or mutable desktop settings.
- Clipboard integration or pixel-identical parity with Classic/CE. The supported workflow should retain Classic's dense IDE hierarchy and interaction model where SwiftCrossUI permits it.
- Alternate UI backends, fallback transports, or feature flags.
- Desktop containers or native release packages.
