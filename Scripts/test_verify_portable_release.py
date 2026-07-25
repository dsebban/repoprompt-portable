#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from verify_portable_release import VerificationError, verify_action_pins, verify_archive, verify_metadata


class ReleaseVerifierTests(unittest.TestCase):
	def test_action_pins_require_full_commit_sha(self) -> None:
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "workflow.yml"
			path.write_text("steps:\n  - uses: actions/checkout@" + "a" * 40 + " # pinned\n", encoding="utf-8")
			verify_action_pins(path)
			path.write_text("steps:\n  - uses: actions/checkout@v4\n", encoding="utf-8")
			with self.assertRaises(VerificationError):
				verify_action_pins(path)

	def test_archive_locks_config_digest_and_tag(self) -> None:
		config = json.dumps({"config": {"User": "repoprompt"}}, separators=(",", ":")).encode()
		config_digest = "sha256:" + hashlib.sha256(config).hexdigest()
		config_name = config_digest.removeprefix("sha256:") + ".json"
		manifest = json.dumps([{
			"Config": config_name,
			"RepoTags": ["repoprompt-portable-archive:amd64"],
			"Layers": [],
		}]).encode()
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "image.tar.gz"
			with tarfile.open(path, "w:gz") as archive:
				for name, data in (("manifest.json", manifest), (config_name, config)):
					info = tarfile.TarInfo(name)
					info.size = len(data)
					archive.addfile(info, io.BytesIO(data))
			verify_archive(path, config_digest, "repoprompt-portable-archive:amd64")
			with self.assertRaises(VerificationError):
				verify_archive(path, "sha256:" + "0" * 64, None)

	def test_release_metadata_requires_both_platforms(self) -> None:
		digest = "sha256:" + "a" * 64
		value = {
			"schema_version": 1,
			"image": "ghcr.io/example/repoprompt-portable",
			"index_digest": digest,
			"source_revision": "revision",
			"version": "0.2.0",
			"platforms": {
				"linux/amd64": {"digest": digest, "config_digest": digest},
				"linux/arm64": {"digest": digest, "config_digest": digest},
			},
		}
		with tempfile.TemporaryDirectory() as directory:
			path = Path(directory) / "container-digests.json"
			path.write_text(json.dumps(value), encoding="utf-8")
			verify_metadata(
				path,
				expected_image="ghcr.io/example/repoprompt-portable",
				expected_index_digest=digest,
				expected_revision="revision",
				expected_version="0.2.0",
			)
			with self.assertRaises(VerificationError):
				verify_metadata(path, expected_revision="wrong-revision")
			del value["platforms"]["linux/arm64"]
			path.write_text(json.dumps(value), encoding="utf-8")
			with self.assertRaises(VerificationError):
				verify_metadata(path)


if __name__ == "__main__":
	unittest.main()
