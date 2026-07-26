#!/usr/bin/env python3
"""Verify that the Linux desktop stays isolated and links only the GTK backend."""

from __future__ import annotations

import json
import os
import platform
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DESKTOP = ROOT / "LinuxDesktop"
PRODUCT = "repoprompt-linux-desktop"
VERSION = "0.8.0"
SWIFT_CROSS_UI_URL = "https://github.com/stackotter/swift-cross-ui.git"
SWIFT_CROSS_UI_REVISION = "a6d206370812e3b9edba259d167e848892c5013d"
FORBIDDEN_IMPORTS = {
    "AppKit", "Cocoa", "Combine", "CoreGraphics", "CoreImage", "CoreServices",
    "Metal", "MetalKit", "Quartz", "QuartzCore", "SwiftUI", "UIKit",
}
FORBIDDEN_BACKENDS = {"AppKitBackend", "UIKitBackend", "WinUIBackend"}
DOCKERFILE_FORBIDDEN = {"SwiftCrossUI", "swift-cross-ui", "LinuxDesktop", "GtkBackend", "libgtk"}
DESKTOP_ONLY_IDENTITIES = {
    "jpeg", "libpng", "libwebp", "swift-cross-ui", "swift-image-formats",
    "swift-macro-toolkit", "swift-mutex", "swift-winui", "zlib",
}


def fail(message: str) -> None:
    raise SystemExit(f"linux desktop graph verification failed: {message}")


def run(*arguments: str) -> str:
    result = subprocess.run(
        arguments,
        cwd=ROOT,
        env={**os.environ, "SCUI_DEFAULT_BACKEND": "GtkBackend"},
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        fail(f"{' '.join(arguments)} exited {result.returncode}\n{result.stdout}{result.stderr}")
    return result.stdout


def dump_package(path: Path) -> dict:
    return json.loads(run("swift", "package", "--package-path", str(path), "dump-package"))


def dependency_identities(manifest: dict) -> set[str]:
    identities: set[str] = set()
    for dependency in manifest["dependencies"]:
        for values in dependency.values():
            identities.update(value["identity"] for value in values)
    return identities


def target_dependencies(target: dict) -> set[tuple[str, str]]:
    dependencies: set[tuple[str, str]] = set()
    for dependency in target.get("dependencies", []):
        if "product" in dependency:
            name, package, *_ = dependency["product"]
            dependencies.add(("product:" + name, package))
        elif "byName" in dependency:
            name, *_ = dependency["byName"]
            dependencies.add(("target:" + name, ""))
    return dependencies


def verify_manifests() -> None:
    root_manifest = dump_package(ROOT)
    root_dependencies = dependency_identities(root_manifest)
    root_lock = json.loads((ROOT / "Package.resolved").read_text())
    root_pins = {pin["identity"] for pin in root_lock["pins"]}
    leaked_root_identities = sorted((root_dependencies | root_pins) & DESKTOP_ONLY_IDENTITIES)
    if leaked_root_identities:
        fail("desktop-only identities entered the root package graph: " + ", ".join(leaked_root_identities))

    desktop_manifest = dump_package(DESKTOP)
    products = {product["name"] for product in desktop_manifest["products"]}
    if products != {PRODUCT}:
        fail(f"nested package products are {sorted(products)}, expected only {PRODUCT}")

    desktop_dependencies = desktop_manifest["dependencies"]
    local_parent = any(
        Path(value["path"]).resolve() == ROOT
        for dependency in desktop_dependencies
        for value in dependency.get("fileSystem", [])
    )
    swift_cross_ui_dependencies = [
        value
        for dependency in desktop_dependencies
        for value in dependency.get("sourceControl", [])
        if value["identity"] == "swift-cross-ui"
    ]
    exact_pin = (
        len(swift_cross_ui_dependencies) == 1
        and swift_cross_ui_dependencies[0]["requirement"] == {"exact": [VERSION]}
        and swift_cross_ui_dependencies[0]["location"] == {
            "remote": [{"urlString": SWIFT_CROSS_UI_URL}]
        }
    )
    if not local_parent:
        fail("nested package does not use the local parent package")
    if not exact_pin:
        fail(f"nested manifest does not pin {SWIFT_CROSS_UI_URL} exactly to {VERSION}")

    desktop_lock = json.loads((DESKTOP / "Package.resolved").read_text())
    swift_cross_ui = [pin for pin in desktop_lock["pins"] if pin["identity"] == "swift-cross-ui"]
    expected_lock = {
        "location": SWIFT_CROSS_UI_URL,
        "state": {"revision": SWIFT_CROSS_UI_REVISION, "version": VERSION},
    }
    if len(swift_cross_ui) != 1 or any(
        swift_cross_ui[0].get(key) != value for key, value in expected_lock.items()
    ):
        fail(f"nested lockfile does not resolve the approved SwiftCrossUI {VERSION} revision")

    targets = {target["name"]: target for target in desktop_manifest["targets"]}
    expected_targets = {
        "RepoPromptLinuxDesktopKit": {
            ("product:RepoPromptHeadless", "repoprompt-portable"),
            ("product:SwiftCrossUI", "swift-cross-ui"),
        },
        "RepoPromptLinuxDesktop": {
            ("target:RepoPromptLinuxDesktopKit", ""),
            ("product:RepoPromptHeadless", "repoprompt-portable"),
            ("product:SwiftCrossUI", "swift-cross-ui"),
            ("product:DefaultBackend", "swift-cross-ui"),
        },
        "RepoPromptLinuxDesktopKitTests": {
            ("target:RepoPromptLinuxDesktopKit", ""),
            ("product:RepoPromptHeadless", "repoprompt-portable"),
        },
    }
    if set(targets) != set(expected_targets):
        fail(f"nested package targets are {sorted(targets)}, expected {sorted(expected_targets)}")
    for name, expected in expected_targets.items():
        actual = target_dependencies(targets[name])
        if actual != expected:
            fail(f"{name} dependencies are {sorted(actual)}, expected {sorted(expected)}")

    dockerfile = (ROOT / "Dockerfile.headless").read_text()
    leaked = sorted(term for term in DOCKERFILE_FORBIDDEN if term in dockerfile)
    if leaked:
        fail("desktop dependencies entered Dockerfile.headless: " + ", ".join(leaked))
    if re.search(
        r"^\s*(?:COPY|ADD)\s+(?:--\S+\s+)*(?:\.|\./|\*|\./\*)\s",
        dockerfile,
        re.MULTILINE,
    ) or re.search(r'^\s*(?:COPY|ADD)\s+\[\s*"(?:\.|\./|\*|\./\*)"', dockerfile, re.MULTILINE):
        fail("Dockerfile.headless uses a broad COPY/ADD source")


def verify_owned_imports() -> None:
    import_pattern = re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:(?:public|package|internal|private|fileprivate)\s+)?"
        r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
        r"([A-Za-z_]\w*)",
        re.MULTILINE,
    )
    roots = [
        ROOT / "RepoPromptCore",
        ROOT / "RepoPromptHeadless",
        ROOT / "RepoPromptHeadlessServer",
        ROOT / "RepoPromptPortableCLI",
        DESKTOP / "Sources",
        DESKTOP / "Tests",
    ]
    violations: list[str] = []
    for source_root in roots:
        for path in source_root.rglob("*.swift"):
            imports = set(import_pattern.findall(path.read_text()))
            forbidden = sorted(imports & FORBIDDEN_IMPORTS)
            if forbidden:
                violations.append(f"{path.relative_to(ROOT)}: {', '.join(forbidden)}")
    if violations:
        fail("forbidden Apple imports found:\n" + "\n".join(violations))


def verify_linux_binary() -> None:
    if platform.system() != "Linux":
        fail("compile/link verification requires Linux")

    bin_path = Path(
        run("swift", "build", "--package-path", str(DESKTOP), "--show-bin-path").strip()
    )
    run("swift", "package", "--package-path", str(DESKTOP), "clean")
    if any(bin_path.rglob("*.swiftmodule")):
        fail("swift package clean left stale compiled modules in the active build directory")

    run(
        "swift",
        "build",
        "--package-path",
        str(DESKTOP),
        "--product",
        PRODUCT,
        "--disable-automatic-resolution",
    )
    checkout = DESKTOP / ".build" / "checkouts" / "swift-cross-ui"
    if not checkout.is_dir():
        fail("SwiftCrossUI checkout is missing after build")
    if run("git", "-C", str(checkout), "rev-parse", "HEAD").strip() != SWIFT_CROSS_UI_REVISION:
        fail("compiled SwiftCrossUI checkout is not at the approved revision")
    checkout_origin = run("git", "-C", str(checkout), "remote", "get-url", "origin").strip()
    origin_repository = Path(checkout_origin)
    source_url = (
        run("git", "-C", str(origin_repository), "remote", "get-url", "origin").strip()
        if origin_repository.is_dir()
        else checkout_origin
    )
    if source_url != SWIFT_CROSS_UI_URL:
        fail("compiled SwiftCrossUI checkout has an unexpected source URL")
    if run("git", "-C", str(checkout), "status", "--porcelain").strip():
        fail("compiled SwiftCrossUI checkout has local modifications")

    binary = bin_path / PRODUCT
    if not binary.is_file():
        fail(f"built executable is missing at {binary}")

    modules = {path.stem for path in bin_path.rglob("*.swiftmodule")}
    if "GtkBackend" not in modules:
        fail("GtkBackend was not compiled")
    forbidden_modules = sorted(modules & FORBIDDEN_BACKENDS)
    if forbidden_modules:
        fail(f"forbidden Apple backends were compiled: {', '.join(forbidden_modules)}")

    linkage = run("ldd", str(binary))
    if "libgtk-4.so" not in linkage:
        fail("executable is not linked to GTK 4")
    if "not found" in linkage:
        fail("executable has missing libraries:\n" + linkage)
    if re.search(r"AppKit|UIKit|\.framework", linkage, re.IGNORECASE):
        fail("executable linkage references an Apple framework")


if __name__ == "__main__":
    verify_manifests()
    verify_owned_imports()
    verify_linux_binary()
    print("Linux desktop graph verified: isolated root, SwiftCrossUI 0.8.0, GTK 4 linkage, no Apple backend or missing library.")
