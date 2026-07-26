#!/usr/bin/env python3
"""Verify portable release source, images, archives, and digest metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent.parent
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)", re.MULTILINE)
SECRET_RE = re.compile(r"(?:sk-[A-Za-z0-9]{20,}|Bearer\s+\S+)", re.IGNORECASE)


class VerificationError(RuntimeError):
	pass


def require(condition: bool, message: str) -> None:
	if not condition:
		raise VerificationError(message)


def sha256_bytes(data: bytes) -> str:
	return "sha256:" + hashlib.sha256(data).hexdigest()


def load_json(path: Path) -> Any:
	try:
		return json.loads(path.read_text(encoding="utf-8"))
	except (OSError, json.JSONDecodeError) as error:
		raise VerificationError(f"cannot read JSON {path}: {error}") from error


def contract_value(path: Path, name: str) -> str:
	text = path.read_text(encoding="utf-8")
	match = re.search(rf'public static let {name} = "([^"]+)"', text)
	require(match is not None, f"{name} is missing from {path}")
	return match.group(1)


def iter_json_values(value: Any) -> Iterable[tuple[str | None, Any]]:
	if isinstance(value, dict):
		for key, item in value.items():
			yield str(key), item
			yield from iter_json_values(item)
	elif isinstance(value, list):
		for item in value:
			yield None, item
			yield from iter_json_values(item)


def verify_credential_free_config(path: Path) -> None:
	value = load_json(path)
	for key, item in iter_json_values(value):
		normalized_key = re.sub(r"[^a-z0-9]", "", (key or "").lower())
		require(normalized_key not in {"apikey", "authorization", "bearertoken"}, f"credential key {key!r} is forbidden in {path}")
		if isinstance(item, str):
			require(SECRET_RE.search(item) is None, f"secret-looking value is forbidden in {path}")


def verify_action_pins(path: Path) -> None:
	text = path.read_text(encoding="utf-8")
	for action in USES_RE.findall(text):
		if action.startswith("./") or action.startswith("docker://"):
			continue
		require("@" in action, f"action is not pinned in {path}: {action}")
		name, ref = action.rsplit("@", 1)
		require(bool(name) and FULL_SHA_RE.fullmatch(ref) is not None, f"action must use a full commit SHA in {path}: {action}")


def verify_source(root: Path, expected_version: str, expected_schema_version: str | None = None) -> None:
	contract = root / "RepoPromptHeadless/PortableContract.swift"
	actual_version = contract_value(contract, "softwareVersion")
	actual_schema_version = contract_value(contract, "toolSchemaVersion")
	require(actual_version == expected_version, f"software version is {actual_version}, expected {expected_version}")
	if expected_schema_version is not None:
		require(
			actual_schema_version == expected_schema_version,
			f"tool schema version is {actual_schema_version}, expected {expected_schema_version}",
		)
	verify_credential_free_config(root / "opencode.docker.json")
	workflows = sorted((root / ".github/workflows").glob("*.y*ml"))
	require(bool(workflows), "no GitHub Actions workflows found")
	for workflow in workflows:
		verify_action_pins(workflow)

	dockerfile = (root / "Dockerfile.headless").read_text(encoding="utf-8")
	require(re.search(r"^FROM\s+\S+@sha256:[0-9a-f]{64}", dockerfile, re.MULTILINE) is not None, "Docker base image is not digest-pinned")
	for binary in ("repoprompt-headless", "repoprompt-portable-cli"):
		require(f"swift build -c release --product {binary}" in dockerfile, f"Docker build omits {binary}")
		require(f"/usr/local/bin/{binary}" in dockerfile, f"final image omits {binary}")
	require("sha256sum --check" in dockerfile, "OpenCode archive checksum verification is missing")
	require(re.search(r"^USER\s+repoprompt\s*$", dockerfile, re.MULTILINE) is not None, "final image must default to the repoprompt user")
	require('ENTRYPOINT ["/usr/local/bin/repoprompt-headless"]' in dockerfile, "headless entrypoint is missing")

	smoke = (root / "Scripts/smoke_portable_oracle_docker.sh").read_text(encoding="utf-8")
	require(
		re.search(r'PYTHON_IMAGE=.*python:[^}" ]+@sha256:[0-9a-f]{64}', smoke) is not None,
		"Docker smoke fixture image default is not digest-pinned",
	)
	mcp_smoke = (root / "Scripts/portable_oracle_mcp_smoke.py").read_text(encoding="utf-8")
	require(f'SOFTWARE_VERSION = "{actual_version}"' in mcp_smoke, "MCP smoke software version is stale")
	require(f'TOOL_SCHEMA_VERSION = "{actual_schema_version}"' in mcp_smoke, "MCP smoke tool schema version is stale")

	release_notes = (root / ".github/release-assets/RELEASE_NOTES.md.in").read_text(encoding="utf-8")
	for placeholder in ("@@VERSION@@", "@@SOFTWARE_VERSION@@", "@@SCHEMA_VERSION@@", "@@IMAGE@@"):
		require(placeholder in release_notes, f"release notes template is missing {placeholder}")


def run(command: list[str], *, capture: bool = False) -> str:
	result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE if capture else None)
	return result.stdout.strip() if capture else ""


def hardened_docker_args(platform: str | None = None) -> list[str]:
	args = [
		"--rm",
		"--read-only",
		"--cap-drop", "ALL",
		"--security-opt", "no-new-privileges",
		"--pids-limit", "256",
		"--tmpfs", "/tmp:rw,nosuid,nodev,size=64m",
		"--network", "none",
	]
	if platform:
		args[1:1] = ["--platform", platform]
	return args


def verify_image(
	image: str,
	*,
	platform: str | None,
	expected_revision: str | None,
	expected_version: str | None,
	expected_opencode_version: str | None,
) -> None:
	inspect = json.loads(run(["docker", "image", "inspect", image], capture=True))[0]
	config = inspect.get("Config") or {}
	require(config.get("User") in {"repoprompt", "10001", "10001:10001"}, f"unexpected image user: {config.get('User')!r}")
	require(config.get("Entrypoint") == ["/usr/local/bin/repoprompt-headless"], f"unexpected entrypoint: {config.get('Entrypoint')!r}")
	labels = config.get("Labels") or {}
	if expected_revision:
		require(labels.get("org.opencontainers.image.revision") == expected_revision, "OCI revision label mismatch")
	if expected_version:
		require(labels.get("org.opencontainers.image.version") == expected_version, "OCI version label mismatch")

	check = """
set -eu
test "$(id -u)" = 10001
test "$(id -g)" = 10001
test -x /usr/local/bin/repoprompt-headless
test -x /usr/local/bin/repoprompt-portable-cli
/usr/local/bin/repoprompt-headless --help >/dev/null
/usr/local/bin/repoprompt-portable-cli --help >/dev/null
! grep -Eiq '\"apiKey\"[[:space:]]*:|sk-[[:alnum:]]{20,}' /etc/opencode/opencode.json
"""
	run(["docker", "run", *hardened_docker_args(platform), "--entrypoint", "/bin/sh", image, "-c", check])
	if expected_opencode_version:
		actual = run([
			"docker", "run", *hardened_docker_args(platform), "--env", "HOME=/tmp", "--entrypoint", "opencode", image, "--version",
		], capture=True)
		require(expected_opencode_version in actual, f"OpenCode version mismatch: {actual!r}")


def verify_archive(path: Path, expected_config_digest: str, expected_tag: str | None) -> None:
	require(DIGEST_RE.fullmatch(expected_config_digest) is not None, "expected config digest must be sha256")
	try:
		with tarfile.open(path, "r:gz") as archive:
			members = {member.name: member for member in archive.getmembers()}
			require("manifest.json" in members, "Docker archive has no manifest.json")
			manifest_file = archive.extractfile(members["manifest.json"])
			require(manifest_file is not None, "Docker archive manifest is unreadable")
			manifest = json.loads(manifest_file.read())
			require(isinstance(manifest, list) and len(manifest) == 1, "Docker archive must contain one image")
			entry = manifest[0]
			config_name = entry.get("Config")
			require(isinstance(config_name, str) and config_name in members, "Docker archive config is missing")
			config_file = archive.extractfile(members[config_name])
			require(config_file is not None, "Docker archive config is unreadable")
			require(sha256_bytes(config_file.read()) == expected_config_digest, "Docker archive config digest mismatch")
			if expected_tag:
				require(expected_tag in (entry.get("RepoTags") or []), f"Docker archive tag {expected_tag!r} is missing")
	except (OSError, tarfile.TarError, json.JSONDecodeError) as error:
		raise VerificationError(f"invalid Docker archive {path}: {error}") from error


def verify_metadata(
	path: Path,
	*,
	expected_image: str | None = None,
	expected_index_digest: str | None = None,
	expected_revision: str | None = None,
	expected_version: str | None = None,
) -> None:
	value = load_json(path)
	require(value.get("schema_version") == 1, "release metadata schema_version must be 1")
	require(isinstance(value.get("image"), str) and value["image"].startswith("ghcr.io/"), "release metadata image must be a GHCR name")
	require(DIGEST_RE.fullmatch(str(value.get("index_digest"))) is not None, "release metadata index digest is invalid")
	if expected_image:
		require(value.get("image") == expected_image, "release metadata image mismatch")
	if expected_index_digest:
		require(value.get("index_digest") == expected_index_digest, "release metadata index digest mismatch")
	if expected_revision:
		require(value.get("source_revision") == expected_revision, "release metadata source revision mismatch")
	if expected_version:
		require(value.get("version") == expected_version, "release metadata version mismatch")
	platforms = value.get("platforms")
	require(isinstance(platforms, dict) and set(platforms) == {"linux/amd64", "linux/arm64"}, "release metadata must contain amd64 and arm64")
	for platform, item in platforms.items():
		require(isinstance(item, dict), f"metadata for {platform} must be an object")
		for key in ("digest", "config_digest"):
			require(DIGEST_RE.fullmatch(str(item.get(key))) is not None, f"invalid {platform} {key}")


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	subparsers = parser.add_subparsers(dest="command", required=True)

	source = subparsers.add_parser("source")
	source.add_argument("--root", type=Path, default=ROOT)
	source.add_argument("--expected-version", required=True)
	source.add_argument("--expected-schema-version")

	image = subparsers.add_parser("image")
	image.add_argument("--image", required=True)
	image.add_argument("--platform")
	image.add_argument("--expected-revision")
	image.add_argument("--expected-version")
	image.add_argument("--expected-opencode-version")

	archive = subparsers.add_parser("archive")
	archive.add_argument("--archive", type=Path, required=True)
	archive.add_argument("--expected-config-digest", required=True)
	archive.add_argument("--expected-tag")

	metadata = subparsers.add_parser("metadata")
	metadata.add_argument("--metadata", type=Path, required=True)
	metadata.add_argument("--expected-image")
	metadata.add_argument("--expected-index-digest")
	metadata.add_argument("--expected-revision")
	metadata.add_argument("--expected-version")

	args = parser.parse_args()
	try:
		if args.command == "source":
			verify_source(args.root.resolve(), args.expected_version, args.expected_schema_version)
		elif args.command == "image":
			verify_image(
				args.image,
				platform=args.platform,
				expected_revision=args.expected_revision,
				expected_version=args.expected_version,
				expected_opencode_version=args.expected_opencode_version,
			)
		elif args.command == "archive":
			verify_archive(args.archive, args.expected_config_digest, args.expected_tag)
		else:
			verify_metadata(
				args.metadata,
				expected_image=args.expected_image,
				expected_index_digest=args.expected_index_digest,
				expected_revision=args.expected_revision,
				expected_version=args.expected_version,
			)
	except (VerificationError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
		parser.exit(1, f"release verification failed: {error}\n")
	print(f"portable release {args.command} verification passed")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
