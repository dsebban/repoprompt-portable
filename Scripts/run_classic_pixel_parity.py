#!/usr/bin/env python3
"""Build, launch, capture, and score the deterministic Classic parity scenario."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import queue
import shutil
import statistics
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Iterable, Mapping

from classic_pixel_parity_metrics import (
    CANVAS,
    MASK_POLICY,
    METRIC_ID,
    NORMALIZATION_ID,
    RAW_WINDOW_SIZE,
    SEMANTIC_MASK_POLICY_V2,
    SEMANTIC_METRIC_ID_V2,
    PixelParityError,
    compute_metrics,
    compute_semantic_mask_metrics_v2,
    normalize_image,
    save_diagnostics,
    save_semantic_mask_diagnostics_v2,
    sha256_path,
    stable_json,
)


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPTS = REPOSITORY / "Scripts"
SCENARIO_PATH = SCRIPTS / "fixtures/classic-pixel-parity/scenario.json"
TARGET_PATH = REPOSITORY / "docs/visual-contracts/classic-parity-target-v1.png"
TARGET_STATE_CONTRACT_V2_PATH = (
    REPOSITORY / "docs/visual-contracts/classic-target-state-contract-v2.json"
)
SCOREBOARD_PATH = REPOSITORY / "prompt-exports/optimize-classic-pixel-parity-runs.md"
ARTIFACT_ROOT = REPOSITORY / "prompt-exports/classic-pixel-parity-artifacts"
EXPECTED_TARGET_SHA256 = "07ec2644bcbf4f3a9f4eec7aa56d53404d8cbd933b75f7f490e11a25339ba916"
WINDOW_POINTS = (1504, 949)
CANDIDATE_RAW_SIZE = (3008, 1898)
PROCESS_NAME = "repoprompt-linux-desktop"
APP_NAME = "RepoPrompt Portable"
APP_IDENTIFIER = "com.repoprompt.portable.desktop.pixel-parity"
PROVIDER_VARIABLE_PREFIXES = ("OPENCODE_", "REPOPROMPT_ORACLE_")
PROVENANCE_MARKER = "<!-- CAMPAIGN_PROVENANCE -->"
RUN_MARKER = "<!-- RUN_RECORDS -->"
EXCLUDED_FINGERPRINT_PREFIXES = (
    "prompt-exports/classic-pixel-parity-artifacts/",
    "prompt-exports/optimize-classic-pixel-parity-runs.md",
)


class HarnessFailure(RuntimeError):
    pass


def run_command(
    arguments: list[str],
    *,
    environment: Mapping[str, str] | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        arguments,
        cwd=REPOSITORY,
        env=dict(environment) if environment is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise HarnessFailure(f"{' '.join(arguments)} failed ({result.returncode}): {stderr}")
    return result


def load_scenario() -> dict[str, Any]:
    try:
        scenario = json.loads(SCENARIO_PATH.read_text(encoding="utf-8"))
    except Exception as error:
        raise HarnessFailure(f"cannot load scenario: {error}") from error
    if scenario.get("schema_version") != 1:
        raise HarnessFailure("unsupported scenario schema")
    files = scenario.get("files")
    if not isinstance(files, list) or not files:
        raise HarnessFailure("scenario must contain a non-empty files list")
    if len(files) != scenario.get("expected_fixture_file_count"):
        raise HarnessFailure("scenario file count does not match expected_fixture_file_count")
    paths = [entry.get("path") for entry in files]
    if any(not isinstance(path, str) or not path for path in paths):
        raise HarnessFailure("scenario contains an invalid fixture path")
    if len(set(paths)) != len(paths):
        raise HarnessFailure("scenario contains duplicate fixture paths")
    return scenario


def fixture_hash(scenario: Mapping[str, Any]) -> str:
    manifest = [
        {"path": entry["path"], "content": entry["content"]}
        for entry in scenario["files"]
    ]
    payload = json.dumps(
        manifest,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def create_fixture(scenario: Mapping[str, Any], fixture_root: Path) -> None:
    if fixture_root.exists():
        raise HarnessFailure(f"fixture path already exists: {fixture_root}")
    fixture_root.mkdir(parents=True)
    for entry in scenario["files"]:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise HarnessFailure(f"unsafe fixture path: {entry['path']}")
        destination = fixture_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(entry["content"], encoding="utf-8", newline="\n")


def git_paths() -> list[str]:
    result = run_command(
        ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"]
    ).stdout
    entries = result.split(b"\0")
    paths: list[str] = []
    index = 0
    while index < len(entries):
        entry = entries[index]
        index += 1
        if not entry:
            continue
        decoded = entry.decode("utf-8", errors="surrogateescape")
        status = decoded[:2]
        path = decoded[3:]
        if status[0] in ("R", "C") and index < len(entries):
            path = entries[index].decode("utf-8", errors="surrogateescape")
            index += 1
        if any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in EXCLUDED_FINGERPRINT_PREFIXES):
            continue
        paths.append(path)
    return sorted(set(paths))


def worktree_fingerprint() -> dict[str, Any]:
    paths = git_paths()
    manifest: list[dict[str, Any]] = []
    for relative in paths:
        path = REPOSITORY / relative
        if path.is_file():
            manifest.append(
                {
                    "path": relative,
                    "sha256": sha256_path(path),
                    "bytes": path.stat().st_size,
                }
            )
        else:
            manifest.append({"path": relative, "kind": "missing-or-non-file"})
    payload = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return {
        "sha256": hashlib.sha256(payload).hexdigest(),
        "entries": manifest,
    }


def sanitized_environment() -> dict[str, str]:
    environment = dict(os.environ)
    for name in list(environment):
        if any(name.startswith(prefix) for prefix in PROVIDER_VARIABLE_PREFIXES):
            environment.pop(name, None)
    environment.update(
        {
            "SCUI_DEFAULT_BACKEND": "AppKitBackend",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TZ": "UTC",
            "NSAutomaticWindowAnimationsEnabled": "NO",
            "NSScrollAnimationEnabled": "NO",
        }
    )
    return environment


def build_desktop(environment: Mapping[str, str]) -> tuple[Path, str]:
    command = [
        "swift",
        "build",
        "--package-path",
        str(REPOSITORY / "LinuxDesktop"),
        "--product",
        PROCESS_NAME,
        "-c",
        "release",
        "--disable-index-store",
        "--disable-automatic-resolution",
    ]
    result = run_command(command, environment=environment, timeout=1800)
    show_path = run_command(
        [
            "swift",
            "build",
            "--package-path",
            str(REPOSITORY / "LinuxDesktop"),
            "-c",
            "release",
            "--disable-index-store",
            "--show-bin-path",
        ],
        environment=environment,
        timeout=120,
    )
    binary = Path(show_path.stdout.decode("utf-8").strip()) / PROCESS_NAME
    if not binary.is_file():
        raise HarnessFailure(f"desktop binary is missing after build: {binary}")
    return binary, (result.stdout + result.stderr).decode("utf-8", errors="replace")


def build_capture_helper(tool_directory: Path) -> tuple[Path, str]:
    source = SCRIPTS / "classic_pixel_parity_capture.swift"
    helper = tool_directory / "classic-pixel-parity-capture"
    result = run_command(
        ["swiftc", "-O", str(source), "-o", str(helper)],
        timeout=120,
    )
    return helper, (result.stdout + result.stderr).decode("utf-8", errors="replace")


def create_app_bundle(binary: Path, bundle_root: Path) -> Path:
    app_bundle = bundle_root / f"{APP_NAME}.app"
    executable_directory = app_bundle / "Contents/MacOS"
    executable_directory.mkdir(parents=True)
    executable = executable_directory / PROCESS_NAME
    shutil.copy2(binary, executable)
    executable.chmod(0o755)
    plist = {
        "CFBundleExecutable": PROCESS_NAME,
        "CFBundleIdentifier": APP_IDENTIFIER,
        "CFBundleName": APP_NAME,
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "13.0",
        "NSPrincipalClass": "NSApplication",
    }
    with (app_bundle / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump(plist, handle, sort_keys=True)
    return executable


def pump_stream(
    source: Any,
    destination: Path,
    messages: queue.Queue[tuple[str, str]],
    label: str,
) -> None:
    with destination.open("wb") as output:
        while True:
            line = source.readline()
            if not line:
                return
            output.write(line)
            output.flush()
            messages.put((label, line.decode("utf-8", errors="replace")))


def wait_for_readiness(
    process: subprocess.Popen[bytes],
    messages: queue.Queue[tuple[str, str]],
    expected_count: int,
    timeout: float = 30,
) -> None:
    expected = f"RepoPrompt Portable ready: {expected_count} files"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise HarnessFailure(f"desktop exited before readiness ({process.returncode})")
        try:
            label, line = messages.get(timeout=0.2)
        except queue.Empty:
            continue
        if "RepoPrompt Portable startup failed:" in line:
            raise HarnessFailure(line.strip())
        if label == "stdout" and expected in line:
            return
    raise HarnessFailure(f"timed out waiting for readiness line: {expected}")


def capture_sample(
    helper: Path,
    process_id: int,
    scenario: Mapping[str, Any],
    output: Path,
) -> dict[str, Any]:
    result = run_command(
        [
            str(helper),
            "--pid",
            str(process_id),
            "--title",
            str(scenario["window_title"]),
            "--scenario",
            str(SCENARIO_PATH),
            "--width",
            str(WINDOW_POINTS[0]),
            "--height",
            str(WINDOW_POINTS[1]),
            "--output",
            str(output),
        ],
        timeout=30,
    )
    try:
        metadata = json.loads(result.stdout)
    except Exception as error:
        raise HarnessFailure(f"capture helper emitted invalid metadata: {error}") from error
    if metadata.get("raw_pixels") != list(CANDIDATE_RAW_SIZE):
        raise HarnessFailure(
            f"capture was {metadata.get('raw_pixels')}, expected {list(CANDIDATE_RAW_SIZE)}"
        )
    if abs(float(metadata.get("backing_scale", 0)) - 2.0) > 0.001:
        raise HarnessFailure(f"capture backing scale was {metadata.get('backing_scale')}, expected 2.0")
    if metadata.get("application_active") is not True or metadata.get("ax_frontmost") is not True:
        raise HarnessFailure("capture did not attest an active, frontmost target application")
    return metadata


def host_provenance(capture_metadata: Mapping[str, Any]) -> dict[str, Any]:
    def text(arguments: list[str]) -> str:
        return run_command(arguments, timeout=30).stdout.decode("utf-8", errors="replace").strip()

    appearance = subprocess.run(
        ["defaults", "read", "-g", "AppleInterfaceStyle"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    ).stdout.decode("utf-8", errors="replace").strip() or "Light"
    if appearance.lower() != "dark":
        raise HarnessFailure(f"official campaign requires dark appearance, found {appearance}")
    return {
        "macos": text(["sw_vers"]),
        "architecture": platform.machine(),
        "swift": text(["swift", "--version"]),
        "python": sys.version,
        "appearance": appearance,
        "apple_accent_color": subprocess.run(
            ["defaults", "read", "-g", "AppleAccentColor"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        ).stdout.decode("utf-8", errors="replace").strip() or "system-default",
        "increase_contrast": subprocess.run(
            ["defaults", "read", "com.apple.universalaccess", "increaseContrast"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        ).stdout.decode("utf-8", errors="replace").strip() or "0",
        "reduce_transparency": subprocess.run(
            ["defaults", "read", "com.apple.universalaccess", "reduceTransparency"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        ).stdout.decode("utf-8", errors="replace").strip() or "0",
        "screen": capture_metadata["screen"],
    }


def swift_cross_ui_revision() -> str:
    lockfile = REPOSITORY / "LinuxDesktop/Package.resolved"
    data = json.loads(lockfile.read_text(encoding="utf-8"))
    pins = data.get("pins", data.get("object", {}).get("pins", []))
    for pin in pins:
        if pin.get("identity") == "swift-cross-ui" or pin.get("package") == "swift-cross-ui":
            state = pin.get("state", {})
            return state.get("revision") or state.get("version") or "unknown"
    return "unknown"


def median_metrics(samples: list[dict[str, Any]]) -> tuple[dict[str, Any], dict[str, Any]]:
    aggregate_values = [float(sample["aggregate_score"]) for sample in samples]
    summary: dict[str, Any] = json.loads(json.dumps(samples[0]))
    summary["aggregate_score"] = statistics.median(aggregate_values)
    summary["baseline_samples"] = {
        "count": len(samples),
        "aggregate_scores": aggregate_values,
        "aggregate_median": statistics.median(aggregate_values),
        "aggregate_population_variance": statistics.pvariance(aggregate_values),
        "aggregate_range": max(aggregate_values) - min(aggregate_values),
    }
    variation: dict[str, Any] = {"aggregate": summary["baseline_samples"]}
    for name in summary["regions"]:
        variation[name] = {}
        for metric in ("nmae", "ssim", "score"):
            values = [float(sample["regions"][name][metric]) for sample in samples]
            summary["regions"][name][metric] = statistics.median(values)
            variation[name][metric] = {
                "median": statistics.median(values),
                "population_variance": statistics.pvariance(values),
                "range": max(values) - min(values),
            }
    return summary, variation


def median_semantic_metrics_v2(
    samples: list[dict[str, Any]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    summary: dict[str, Any] = json.loads(json.dumps(samples[0]))
    variation: dict[str, Any] = {}
    for name in summary["mask_order"]:
        variation[name] = {}
        for metric in ("nmae", "ssim", "score", "changed_pixels", "changed_fraction"):
            values = [float(sample["masks"][name][metric]) for sample in samples]
            median = statistics.median(values)
            summary["masks"][name][metric] = (
                int(median) if metric == "changed_pixels" else median
            )
            variation[name][metric] = {
                "median": median,
                "population_variance": statistics.pvariance(values),
                "range": max(values) - min(values),
            }
    return summary, variation


def markdown_run_record(
    run_id: str,
    metrics: Mapping[str, Any],
    variation: Mapping[str, Any],
    artifact_path: Path,
) -> str:
    lines = [
        f"### Iteration 0 — `{run_id}`",
        "",
        "- Candidate: `baseline` — current UI before any new parity layout/style change.",
        f"- Artifacts: `{artifact_path.relative_to(REPOSITORY)}`",
        f"- Aggregate score: **{metrics['aggregate_score']:.6f}/100**",
        f"- Worst region: `{metrics['worst_region']}`",
        f"- Pixel perfect: `{str(metrics['pixel_perfect']).lower()}`",
        f"- Settled samples: `{metrics['baseline_samples']['count']}`; "
        f"aggregate variance `{variation['aggregate']['aggregate_population_variance']:.12f}`; "
        f"range `{variation['aggregate']['aggregate_range']:.12f}`",
        "",
        "| Region | NMAE | SSIM | Score | Variance (score) |",
        "|---|---:|---:|---:|---:|",
    ]
    for name in ("full", "sidebar", "top", "instructions", "builder_bottom"):
        values = metrics["regions"][name]
        lines.append(
            f"| {name} | {values['nmae']:.6f} | {values['ssim']:.6f} | "
            f"{values['score']:.6f} | {variation[name]['score']['population_variance']:.12f} |"
        )
    lines.extend(
        [
            "",
            "- Decision: `continue`.",
            "- Tests: metric unit suite passed; capture hashes were byte-identical.",
            "- Oracle verdict: baseline only; visual stop gate not evaluated.",
            "",
        ]
    )
    return "\n".join(lines)


def append_scoreboard(
    record: str,
    provenance: Mapping[str, Any],
) -> None:
    scoreboard = SCOREBOARD_PATH.read_text(encoding="utf-8")
    if PROVENANCE_MARKER not in scoreboard or RUN_MARKER not in scoreboard:
        raise HarnessFailure("scoreboard markers are missing")
    if "### Iteration 0 —" in scoreboard:
        raise HarnessFailure("scoreboard already contains an iteration-0 baseline")
    provenance_block = (
        PROVENANCE_MARKER
        + "\n\n```json\n"
        + stable_json(provenance)
        + "```\n"
    )
    scoreboard = scoreboard.replace(PROVENANCE_MARKER, provenance_block, 1)
    scoreboard = scoreboard.replace(RUN_MARKER, RUN_MARKER + "\n\n" + record, 1)
    SCOREBOARD_PATH.write_text(scoreboard, encoding="utf-8", newline="\n")


def run_baseline(
    run_id: str,
    samples: int,
    record: bool,
    *,
    semantic_v2: bool = False,
) -> Path:
    if platform.system() != "Darwin":
        raise HarnessFailure("deterministic parity capture requires macOS/AppKit")
    if samples < 3 or samples > 5:
        raise HarnessFailure("--samples must be between 3 and 5")
    scenario = load_scenario()
    if sha256_path(TARGET_PATH) != EXPECTED_TARGET_SHA256:
        raise HarnessFailure("canonical target hash does not match the supplied Classic screenshot")

    final_directory = ARTIFACT_ROOT / run_id
    partial_directory = ARTIFACT_ROOT / f".{run_id}.partial"
    reference_directory = ARTIFACT_ROOT / f"reference-{EXPECTED_TARGET_SHA256[:12]}"
    if final_directory.exists() or partial_directory.exists():
        raise HarnessFailure(f"run ID already exists: {run_id}")
    partial_directory.mkdir(parents=True)

    before = worktree_fingerprint()
    environment = sanitized_environment()
    temporary_parent = Path("/tmp/repoprompt-classic-pixel-parity")
    if temporary_parent.exists():
        raise HarnessFailure(
            f"fixed fixture parent already exists; inspect and remove it before retrying: {temporary_parent}"
        )
    temporary_parent.mkdir(mode=0o700)
    fixture_root = temporary_parent / scenario["workspace_leaf"]
    process: subprocess.Popen[bytes] | None = None
    try:
        create_fixture(scenario, fixture_root)
        metric_test = run_command(
            [sys.executable, str(SCRIPTS / "test_classic_pixel_parity_metrics.py")],
            environment=environment,
            timeout=120,
        )
        (partial_directory / "metric-tests.log").write_bytes(
            metric_test.stdout + metric_test.stderr
        )
        binary, build_log = build_desktop(environment)
        helper, helper_build_log = build_capture_helper(temporary_parent)
        executable = create_app_bundle(binary, temporary_parent)
        (partial_directory / "build.log").write_text(
            build_log + helper_build_log,
            encoding="utf-8",
        )

        process = subprocess.Popen(
            [str(executable), "--macos", "--root", str(fixture_root)],
            cwd=REPOSITORY,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert process.stdout is not None and process.stderr is not None
        messages: queue.Queue[tuple[str, str]] = queue.Queue()
        stdout_thread = threading.Thread(
            target=pump_stream,
            args=(process.stdout, partial_directory / "stdout.log", messages, "stdout"),
            daemon=True,
        )
        stderr_thread = threading.Thread(
            target=pump_stream,
            args=(process.stderr, partial_directory / "stderr.log", messages, "stderr"),
            daemon=True,
        )
        stdout_thread.start()
        stderr_thread.start()
        wait_for_readiness(
            process,
            messages,
            int(scenario["expected_indexed_file_count"]),
        )
        time.sleep(0.5)

        capture_metadata: list[dict[str, Any]] = []
        raw_paths: list[Path] = []
        for index in range(samples):
            output = partial_directory / (
                "raw-window.png" if index == 0 else f"raw-window-sample-{index + 1}.png"
            )
            capture_metadata.append(capture_sample(helper, process.pid, scenario, output))
            raw_paths.append(output)
        hashes = [sha256_path(path) for path in raw_paths]
        if len(set(hashes)) != 1:
            raise HarnessFailure(f"settled captures were not byte-identical: {hashes}")

        reference_directory.mkdir(parents=True, exist_ok=True)
        normalized_target_path = reference_directory / "normalized-target.png"
        target = normalize_image(
            TARGET_PATH,
            normalized_target_path,
            required_size=RAW_WINDOW_SIZE,
        )
        sample_metrics: list[dict[str, Any]] = []
        semantic_sample_metrics: list[dict[str, Any]] = []
        first_candidate = None
        first_ssim_map = None
        for index, raw_path in enumerate(raw_paths):
            normalized_path = (
                partial_directory / "normalized-candidate.png"
                if index == 0
                else partial_directory / f"normalized-candidate-sample-{index + 1}.png"
            )
            candidate = normalize_image(
                raw_path,
                normalized_path,
                required_size=CANDIDATE_RAW_SIZE,
            )
            metrics, ssim_map = compute_metrics(target, candidate)
            sample_metrics.append(metrics)
            if semantic_v2:
                semantic_sample_metrics.append(
                    compute_semantic_mask_metrics_v2(target, candidate)
                )
            if index == 0:
                first_candidate = candidate
                first_ssim_map = ssim_map
        assert first_candidate is not None and first_ssim_map is not None
        metrics, variation = median_metrics(sample_metrics)
        if semantic_v2:
            semantic_metrics, semantic_variation = median_semantic_metrics_v2(
                semantic_sample_metrics
            )
            semantic_metrics["sample_variation"] = semantic_variation
            metrics["semantic_masks_v2"] = semantic_metrics
        metrics.update(
            {
                "run_id": run_id,
                "iteration": 0,
                "target_path": str(TARGET_PATH.relative_to(REPOSITORY)),
                "target_raw_sha256": EXPECTED_TARGET_SHA256,
                "target_normalized_sha256": sha256_path(normalized_target_path),
                "candidate_raw_sha256": hashes[0],
                "candidate_normalized_sha256": sha256_path(
                    partial_directory / "normalized-candidate.png"
                ),
                "sample_variation": variation,
            }
        )
        save_diagnostics(partial_directory, target, first_candidate, first_ssim_map)
        if semantic_v2:
            save_semantic_mask_diagnostics_v2(partial_directory)
        (partial_directory / "metrics.json").write_text(
            stable_json(metrics),
            encoding="utf-8",
        )

        provenance = {
            "schema_version": 1,
            "run_id": run_id,
            "head": run_command(["git", "rev-parse", "HEAD"]).stdout.decode().strip(),
            "target": {
                "path": str(TARGET_PATH.relative_to(REPOSITORY)),
                "sha256": EXPECTED_TARGET_SHA256,
                "dimensions": list(RAW_WINDOW_SIZE),
            },
            "scenario": {
                "path": str(SCENARIO_PATH.relative_to(REPOSITORY)),
                "sha256": sha256_path(SCENARIO_PATH),
                "fixture_sha256": fixture_hash(scenario),
                "expected_indexed_file_count": scenario["expected_indexed_file_count"],
            },
            "harness": {
                "orchestrator_sha256": sha256_path(Path(__file__)),
                "capture_source_sha256": sha256_path(
                    SCRIPTS / "classic_pixel_parity_capture.swift"
                ),
                "capture_binary_sha256": sha256_path(helper),
                "metrics_sha256": sha256_path(
                    SCRIPTS / "classic_pixel_parity_metrics.py"
                ),
                "requirements_sha256": sha256_path(
                    SCRIPTS / "requirements-classic-pixel-parity.txt"
                ),
            },
            "measurement": {
                "window_points": list(WINDOW_POINTS),
                "candidate_raw_pixels": list(CANDIDATE_RAW_SIZE),
                "target_raw_pixels": list(RAW_WINDOW_SIZE),
                "canvas": list(CANVAS),
                "normalization_id": NORMALIZATION_ID,
                "mask_policy": MASK_POLICY,
                "metric_id": METRIC_ID,
                "semantic_v2": (
                    {
                        "mask_policy": SEMANTIC_MASK_POLICY_V2,
                        "metric_id": SEMANTIC_METRIC_ID_V2,
                        "contract_path": str(
                            TARGET_STATE_CONTRACT_V2_PATH.relative_to(REPOSITORY)
                        ),
                        "contract_sha256": sha256_path(TARGET_STATE_CONTRACT_V2_PATH),
                        "scenario_status": "v1-control-only-v2-exact-state-withheld",
                        "activation_wrapper": (
                            "classic_pixel_parity_capture.swift plus scenario-v1 AX actions"
                        ),
                    }
                    if semantic_v2
                    else None
                ),
            },
            "binary": {
                "path": str(binary),
                "sha256": sha256_path(binary),
                "swift_cross_ui_revision": swift_cross_ui_revision(),
                "nested_lockfile_sha256": sha256_path(
                    REPOSITORY / "LinuxDesktop/Package.resolved"
                ),
            },
            "host": host_provenance(capture_metadata[0]),
            "captures": capture_metadata,
            "worktree_before": before,
        }
        (partial_directory / "provenance.json").write_text(
            stable_json(provenance),
            encoding="utf-8",
        )
        record_markdown = markdown_run_record(run_id, metrics, variation, final_directory)
        (partial_directory / "run-record.md").write_text(
            record_markdown,
            encoding="utf-8",
        )

        after = worktree_fingerprint()
        if before["sha256"] != after["sha256"]:
            raise HarnessFailure(
                "worktree changed during capture outside the artifact directory and scoreboard"
            )
        provenance["worktree_after"] = after
        (partial_directory / "provenance.json").write_text(
            stable_json(provenance),
            encoding="utf-8",
        )
        partial_directory.rename(final_directory)
        if record:
            append_scoreboard(record_markdown, provenance)
        return final_directory
    except Exception:
        # Keep the partial directory for diagnosis; it is never scored or recorded.
        raise
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        shutil.rmtree(temporary_parent, ignore_errors=True)


def check_environment() -> None:
    if platform.system() != "Darwin":
        raise HarnessFailure("deterministic parity capture requires macOS/AppKit")
    for executable in ("swift", "swiftc", "git"):
        if shutil.which(executable) is None:
            raise HarnessFailure(f"required executable is missing: {executable}")
    if not Path("/usr/sbin/screencapture").is_file():
        raise HarnessFailure("required executable is missing: /usr/sbin/screencapture")
    if sha256_path(TARGET_PATH) != EXPECTED_TARGET_SHA256:
        raise HarnessFailure("canonical target hash does not match")
    scenario = load_scenario()
    print(
        stable_json(
            {
                "status": "ready",
                "target_sha256": EXPECTED_TARGET_SHA256,
                "target_dimensions": list(RAW_WINDOW_SIZE),
                "scenario_sha256": sha256_path(SCENARIO_PATH),
                "fixture_sha256": fixture_hash(scenario),
            }
        ),
        end="",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("check-env")
    baseline = subparsers.add_parser("baseline")
    baseline.add_argument("--run-id", default=f"baseline-{uuid.uuid4().hex[:8]}")
    baseline.add_argument("--samples", type=int, default=3)
    baseline.add_argument("--record", action="store_true")
    control_v2 = subparsers.add_parser("control-v2")
    control_v2.add_argument("--run-id", default=f"target-state-v2-control-{uuid.uuid4().hex[:8]}")
    control_v2.add_argument("--samples", type=int, default=3)
    arguments = parser.parse_args()
    try:
        if arguments.command == "check-env":
            check_environment()
        elif arguments.command == "baseline":
            artifact = run_baseline(arguments.run_id, arguments.samples, arguments.record)
            print(artifact)
        else:
            artifact = run_baseline(
                arguments.run_id,
                arguments.samples,
                False,
                semantic_v2=True,
            )
            print(artifact)
        return 0
    except (HarnessFailure, PixelParityError, OSError, subprocess.TimeoutExpired) as error:
        print(f"classic pixel parity harness failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
