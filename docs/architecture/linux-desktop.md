# Linux desktop architecture

## Scope

`LinuxDesktop/` is a separate SwiftPM package for the native GTK 4 product `repoprompt-linux-desktop`. The same executable supports explicit macOS QA with `--macos`, where SwiftCrossUI selects its native AppKit backend; this does not add Apple dependencies to the Linux build graph. It implements the existing minimum workflow: open configured workspace roots, search a flattened file list, manage explicit full-file selection, preview selected context, and generate a dual-lane plan when Oracle environment configuration is present.

The application window title is `RepoPrompt Portable`. The desktop is read-only and keeps workspace, instructions, selection, context, and Oracle results in process memory.

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

`PortableWorkspaceService` is the typed in-process boundary. Its intended public surface is `workspace()`, cancellable `files()`, `selection()`, `addFiles(_:)`, `removeFiles(_:)`, `clearSelection()`, cancellable `previewContext()`, and fixed-mode `generatePlan(instructions:)`, together with the `PortableWorkspace*`, `PortableContext*`, and `PortablePlan*` value models. Enumeration/path helpers, selection editing, context rendering, and Oracle execution remain internal implementation details. The service shares the existing bootstrap, session selection store, secure context builder, and concurrent Oracle workflow with the MCP catalog; the desktop-only inventory filters resolved paths outside the roots and non-regular targets without changing MCP `file_search`. No MCP/JSON subprocess or fallback transport is used. SwiftCrossUI, GTK, and desktop sources remain outside the root dependency graph and `Dockerfile.headless`.

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

Running the binary requires Git for hierarchical `.gitignore` evaluation, GTK 4, and an X11 or Wayland display. Provider-free preview needs no API key. Generate Plan uses the same `OPENCODE_API_KEY` or complete `REPOPROMPT_ORACLE_*` environment configuration as the headless products.

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
- Rich editing, syntax highlighting, git/apply operations, or write tools.
- Tabs, presets, Agent Mode, persistence, or desktop settings.
- Clipboard integration or pixel parity with Classic/CE.
- Alternate UI backends, fallback transports, or feature flags.
- Desktop containers or native release packages.
