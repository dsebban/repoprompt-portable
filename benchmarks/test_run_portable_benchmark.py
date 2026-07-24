from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "benchmarks"))
sys.path.insert(0, str(ROOT / "Scripts"))

import run_portable_benchmark as harness
from portable_oracle_mcp_smoke import tool_json_outcome


def plan_contract(**overrides):
	value = {
		"schema_version": harness.PLAN_RESULT_SCHEMA_VERSION,
		"verdict": "ready",
		"blocking_issues": [],
		"coverage": {key: "covered" for key in harness.COVERAGE_KEYS},
		"semantic_requirements": json.loads(json.dumps(harness.PLAN_REQUIRED_SEMANTICS)),
		"files_to_modify": list(harness.PLAN_REQUIRED_FILES),
		"test_case_ids": sorted(harness.PLAN_REQUIRED_TEST_CASE_IDS) + [f"case-{index}" for index in range(8)],
	}
	value.update(overrides)
	return value


def tagged(tag: str, value: dict) -> str:
	return f"explanation\n<{tag}>\n{json.dumps(value)}\n</{tag}>"


def review_contract(verdict="pass", findings=None):
	return {
		"schema_version": 1,
		"verdict": verdict,
		"findings": findings or [],
		"coverage": {key: "pass" for key in harness.COVERAGE_KEYS},
		"evidence_considered": {"diff": True, "semantic_probe": True, "npm_test": True},
	}


class FakeClient:
	def __init__(self, result):
		self.result = result

	def request(self, _method, _params):
		return {"jsonrpc": "2.0", "id": 1, "result": self.result}


class HarnessTests(unittest.TestCase):
	def test_non_throwing_tool_decoder_preserves_error_payload(self):
		payload = {"content": [{"type": "text", "text": '{"code":"bad"}'}], "isError": True}
		outcome = tool_json_outcome(FakeClient(payload), "fixture", {})
		self.assertTrue(outcome.is_error)
		self.assertEqual(outcome.value, {"code": "bad"})
		self.assertIs(outcome.raw_result, payload)

	def test_legacy_artifact_does_not_parse_as_structured_plan(self):
		legacy = json.loads((ROOT / "benchmarks/p-limit-portable.json").read_text())
		raw = legacy["oracle_send"]["oracle_results"]["primary"]["response"]
		self.assertEqual(harness.parse_plan_lane("primary", raw)["parse_status"], "invalid")

	def test_plan_parser_rejects_duplicate_or_trailing_blocks(self):
		body = tagged("portable_plan_result", plan_contract())
		self.assertIsNone(harness.parse_delimited(body + body, "portable_plan_result"))
		self.assertIsNone(harness.parse_delimited(body + "\ntrailing", "portable_plan_result"))

	def test_plan_instructions_publish_v3_adversarial_semantics_and_file_manifest(self):
		contract = harness.parse_delimited(harness.PLAN_INSTRUCTIONS, "portable_plan_result")
		self.assertEqual(contract["schema_version"], 3)
		self.assertEqual(contract["semantic_requirements"], harness.PLAN_REQUIRED_SEMANTICS)
		self.assertEqual(contract["files_to_modify"], list(harness.PLAN_REQUIRED_FILES))
		self.assertEqual(harness.ALLOWED_PRODUCT_PATHS, set(harness.PLAN_REQUIRED_FILES))
		self.assertTrue(harness.PLAN_REQUIRED_TEST_CASE_IDS <= set(contract["test_case_ids"]))
		self.assertIn("`{once: true}` may supplement cleanup after abort, but it is not sufficient by itself", harness.PLAN_INSTRUCTIONS)
		self.assertIn("attach a rejection observer before invoking abort() or clearQueue()", harness.PLAN_INSTRUCTIONS)
		self.assertIn("each exactly once. Reordering is allowed", harness.PLAN_INSTRUCTIONS)

	def test_prior_feedback_normalizes_iteration_three_without_review_prose(self):
		prior = json.loads((ROOT / "prompt-exports/portable-plan-review-artifacts/iteration-03.json").read_text())
		feedback = harness.normalize_prior_feedback(prior)
		self.assertEqual(feedback, {
			"dual_lane_blocking_categories": ["test_infrastructure"],
			"deterministic_failed_gates": {
				"npm_test": {"exit_code": 1, "timed_out": False},
				"static_contract": {"failed_checks": ["readme_semantics"]},
			},
		})
		serialized = json.dumps(feedback)
		for forbidden in ("raw_response", "summary", "Lint errors", "Signal option is documented", "stdout"):
			self.assertNotIn(forbidden, serialized)

	def test_prior_feedback_is_dual_lane_blocking_only_and_plan_only(self):
		artifact = {
			"review": {
				"primary": {"parse_status": "valid", "contract": {"findings": [
					{"category": "test_infrastructure", "severity": "blocking", "summary": "primary raw prose"},
					{"category": "scope", "severity": "blocking"},
					{"category": "raw prose category", "severity": "blocking"},
				]}},
				"secondary": {"parse_status": "valid", "contract": {"findings": [
					{"category": "test_infrastructure", "severity": "blocking", "summary": "secondary raw prose"},
					{"category": "other", "severity": "non_blocking"},
					{"category": "raw prose category", "severity": "blocking"},
				]}},
			},
			"score": {"gates": {"application_scope": True, "npm_test": True, "static_contract": True}},
			"verification": {"semantic_probe": {"passed": True}},
		}
		feedback = harness.normalize_prior_feedback(artifact)
		self.assertEqual(feedback, {"dual_lane_blocking_categories": ["test_infrastructure"], "deterministic_failed_gates": {}})
		instructions = harness.prior_feedback_instructions(feedback)
		for directive in ("promise/param-names", "promise/prefer-await-to-then", "no-unmodified-loop-condition"):
			self.assertIn(directive, instructions)
		for term in ("pLimit(concurrency)", "limitFunction(fn, options)", "signal", "queued", "running", "reason", "rejectOnClear"):
			self.assertIn(term, instructions)
		self.assertNotIn("primary raw prose", instructions)
		self.assertNotIn("secondary raw prose", instructions)
		self.assertNotIn("Prior-artifact feedback", harness.REVIEW_INSTRUCTIONS)

	def test_plan_parser_requires_exact_file_manifest_without_duplicates(self):
		reordered = plan_contract(files_to_modify=list(reversed(harness.PLAN_REQUIRED_FILES)))
		self.assertEqual(harness.parse_plan_lane("primary", tagged("portable_plan_result", reordered))["parse_status"], "valid")
		invalid_manifests = (
			list(harness.PLAN_REQUIRED_FILES[:-1]),
			[*harness.PLAN_REQUIRED_FILES, "package.json"],
			[*harness.PLAN_REQUIRED_FILES[:-1], harness.PLAN_REQUIRED_FILES[0]],
		)
		for files_to_modify in invalid_manifests:
			with self.subTest(files_to_modify=files_to_modify):
				parsed = harness.parse_plan_lane("primary", tagged("portable_plan_result", plan_contract(files_to_modify=files_to_modify)))
				self.assertEqual(parsed["parse_status"], "invalid")

	def test_plan_parser_rejects_pre_v3_and_obsolete_strategy_field(self):
		for schema_version in (1, 2):
			with self.subTest(schema_version=schema_version):
				contract = plan_contract(schema_version=schema_version)
				self.assertEqual(harness.parse_plan_lane("primary", tagged("portable_plan_result", contract))["parse_status"], "invalid")
		obsolete = plan_contract(listener_lifecycle_strategy="once")
		self.assertEqual(harness.parse_plan_lane("primary", tagged("portable_plan_result", obsolete))["parse_status"], "invalid")

	def test_plan_parser_rejects_incomplete_or_weakened_semantics(self):
		contracts = []
		missing_state = plan_contract()
		del missing_state["semantic_requirements"]["listener_lifecycle"]["after_natural_drain_listener_count"]
		contracts.append(missing_state)
		once_only = plan_contract()
		once_only["semantic_requirements"]["listener_lifecycle"]["once_alone_sufficient"] = True
		contracts.append(once_only)
		late_observation = plan_contract()
		late_observation["semantic_requirements"]["rejection_observation"]["observer_timing"] = "after_abort_or_clear"
		contracts.append(late_observation)
		unhandled = plan_contract()
		unhandled["semantic_requirements"]["rejection_observation"]["unhandled_rejections_allowed"] = True
		contracts.append(unhandled)
		for contract in contracts:
			with self.subTest(contract=contract["semantic_requirements"]):
				self.assertEqual(harness.parse_plan_lane("primary", tagged("portable_plan_result", contract))["parse_status"], "invalid")

	def test_plan_parser_requires_adversarial_test_ids_and_nonempty_strings(self):
		for test_case_ids in (["abort-listener-queue-state-machine"], ["expected-rejections-observed-before-trigger"], [*harness.PLAN_REQUIRED_TEST_CASE_IDS, ""]):
			with self.subTest(test_case_ids=test_case_ids):
				self.assertEqual(harness.parse_plan_lane("primary", tagged("portable_plan_result", plan_contract(test_case_ids=test_case_ids)))["parse_status"], "invalid")

	def test_plan_selection_scores_and_primary_tie_break(self):
		primary = harness.parse_plan_lane("primary", tagged("portable_plan_result", plan_contract()))
		secondary = harness.parse_plan_lane("secondary", tagged("portable_plan_result", plan_contract(test_case_ids=sorted(harness.PLAN_REQUIRED_TEST_CASE_IDS))))
		self.assertEqual(harness.select_plan(primary, secondary)["selected_lane"], "primary")
		secondary = harness.parse_plan_lane("secondary", tagged("portable_plan_result", plan_contract()))
		self.assertEqual(harness.select_plan(primary, secondary)["selected_lane"], "primary")
		invalid_semantics = plan_contract(test_case_ids=[f"case-{index}" for index in range(20)] + sorted(harness.PLAN_REQUIRED_TEST_CASE_IDS))
		invalid_semantics["semantic_requirements"]["listener_lifecycle"]["once_alone_sufficient"] = True
		secondary = harness.parse_plan_lane("secondary", tagged("portable_plan_result", invalid_semantics))
		self.assertEqual(harness.select_plan(primary, secondary)["selected_lane"], "primary")
		invalid_primary = harness.parse_plan_lane("primary", tagged("portable_plan_result", plan_contract(schema_version=1)))
		self.assertIsNone(harness.select_plan(invalid_primary, secondary)["selected_lane"])

	def test_review_agreement_never_overrides_deterministic_failure(self):
		primary = harness.parse_review_lane("primary", tagged("portable_review_result", review_contract()))
		secondary = harness.parse_review_lane("secondary", tagged("portable_review_result", review_contract()))
		self.assertTrue(harness.review_agreement(primary, secondary, True)["acceptance_agreement"])
		self.assertFalse(harness.review_agreement(primary, secondary, False)["acceptance_agreement"])

	def test_endpoint_and_recursive_redaction(self):
		endpoint = harness.sanitize_endpoint("https://user:secret@opencode.ai/zen/go/v1/chat/completions?token=nope")
		self.assertEqual(endpoint["host"], "opencode.ai")
		self.assertTrue(endpoint["query_present"])
		self.assertNotIn("secret", json.dumps(endpoint))
		value = harness.redact({"rows": ["key-123", "Authorization: Bearer abc"]}, "key-123")
		self.assertNotIn("key-123", json.dumps(value))
		self.assertNotIn("Bearer abc", json.dumps(value))

	def test_image_provenance_requires_immutable_id(self):
		value = harness.image_provenance("portable:tag", [{"Id": "sha256:abc", "RepoDigests": ["portable@sha256:def"]}])
		self.assertEqual(value["requested"], "portable:tag")
		self.assertEqual(value["image_id"], "sha256:abc")
		self.assertEqual(value["repo_digest"], "portable@sha256:def")
		with self.assertRaises(ValueError):
			harness.image_provenance("bad", [{"Id": "mutable"}])

	def test_pair_validation_asserts_direct_builder_semantics(self):
		paths = ["index.js"]
		value = {
			"ok": True,
			"status": "response_generated",
			"response_type": "plan",
			"prompt": "plan this",
			"pair_status": "completed",
			"oracle_pair_id": "46774746-1A93-4428-915A-7543BE10EA1B",
			"oracle_decision_policy": "caller_decides",
			"model_raw_id": harness.ORACLE_MODEL,
			"response": "primary",
			"oracle_results": {
				"primary": {"status": "completed", "oracle_lane": "primary", "provider": "openai_compatible", "model_raw_id": harness.ORACLE_MODEL, "response": "primary"},
				"secondary": {"status": "completed", "oracle_lane": "secondary", "provider": "openai_compatible", "model_raw_id": harness.ORACLE_MODEL, "response": "secondary"},
			},
			"workspace_context": {
				"entries": [{"path": "index.js"}],
				"selection": {"selected_paths": ["index.js"]},
				"truncated": False,
				"omissions": [],
			},
		}
		self.assertEqual(harness.validate_pair(value, paths, "plan", " plan this "), (True, []))
		value["response"] = "secondary"
		valid, errors = harness.validate_pair(value, paths, "plan", "plan this")
		self.assertFalse(valid)
		self.assertIn("primary_projection", errors)

	def test_timeout_and_non_persisting_credential_forwarding(self):
		self.assertEqual(harness.DEFAULT_PROVIDER_TIMEOUT_SECONDS, 600)
		self.assertEqual(harness.DEFAULT_STDIO_TIMEOUT_SECONDS, 630)
		self.assertIn("REPOPROMPT_ORACLE_API_KEY", harness.FORWARDED_ORACLE_ENV)
		self.assertIn("REPOPROMPT_ORACLE_TIMEOUT_SECONDS", harness.FORWARDED_ORACLE_ENV)
		config_file = harness.write_opencode_config(600)
		try:
			config = json.loads(config_file.read_text())
			self.assertEqual(config["mcp"]["repoprompt-portable"]["timeout"], 630_000)
			self.assertNotIn("apiKey", config_file.read_text())
		finally:
			config_file.unlink(missing_ok=True)

	def test_install_command_respects_lockfile_presence(self):
		with tempfile.TemporaryDirectory() as directory:
			workspace = Path(directory)
			self.assertIn("npm install --no-package-lock", harness.package_install_command(workspace))
			(workspace / "package-lock.json").write_text("{}")
			self.assertTrue(harness.package_install_command(workspace).startswith("npm ci"))

	def test_scope_allowlist_and_reserved_paths(self):
		self.assertTrue(harness.scope_is_valid([["M", "index.js"]], [".repoprompt-benchmark/task.md"], True))
		self.assertFalse(harness.scope_is_valid([["M", "package.json"]], [], True))
		self.assertFalse(harness.scope_is_valid([["M", "index.js"]], ["extra.js"], True))
		self.assertFalse(harness.scope_is_valid([["D", "index.js"]], [], True))

	def test_quality_score_and_iteration_cap(self):
		gates = {key: True for key in (
			"provenance_isolation", "plan_transport", "plan_selection", "application_scope", "npm_test",
			"static_contract", "review_transport", "review_verdict_agreement", "review_acceptance",
		)}
		self.assertEqual(harness.quality_score(gates, 10), 100)
		gates["provenance_isolation"] = False
		self.assertEqual(harness.quality_score(gates, 10), 90)
		self.assertEqual(harness.decision(0, True)["action"], "stop_success")
		self.assertEqual(harness.decision(5, False)["action"], "stop_iteration_cap")

	def test_atomic_artifact_and_scoreboard_duplicate_protection(self):
		with tempfile.TemporaryDirectory() as directory:
			root = Path(directory)
			artifact_path = root / "artifact.json"
			harness.atomic_write_json(artifact_path, {"ok": True})
			self.assertEqual(json.loads(artifact_path.read_text()), {"ok": True})
			artifact = {
				"run": {"run_id": "run-1", "iteration": 0, "label": "baseline", "candidate_id": "baseline", "attributed_change": "harness"},
				"provenance": {"portable_image": {"image_id": "sha256:p"}, "node_image": {"image_id": "sha256:n"}, "timeouts": {"provider_seconds": 120, "stdio_seconds": 300}},
				"p_limit": {"commit": harness.PINNED_COMMIT, "tree": "tree"},
				"score": {"points": 0}, "decision": {"action": "continue"},
			}
			scoreboard = root / "scoreboard.md"
			harness.append_scoreboard(scoreboard, artifact, artifact_path)
			with self.assertRaises(ValueError):
				harness.append_scoreboard(scoreboard, artifact, artifact_path)

	def test_fingerprint_excludes_only_declared_artifact(self):
		with tempfile.TemporaryDirectory() as directory:
			repository = Path(directory)
			subprocess.run(["git", "init", "-q", repository], check=True)
			subprocess.run(["git", "-C", repository, "config", "user.email", "test@example.com"], check=True)
			subprocess.run(["git", "-C", repository, "config", "user.name", "Test"], check=True)
			(repository / "tracked.txt").write_text("base\n")
			subprocess.run(["git", "-C", repository, "add", "tracked.txt"], check=True)
			subprocess.run(["git", "-C", repository, "commit", "-qm", "base"], check=True)
			output = repository / "artifact.json"
			before = harness.portable_fingerprint(repository, [output])
			output.write_text("generated\n")
			self.assertEqual(before["fingerprint_sha256"], harness.portable_fingerprint(repository, [output])["fingerprint_sha256"])
			(repository / "other.txt").write_text("user\n")
			self.assertNotEqual(before["fingerprint_sha256"], harness.portable_fingerprint(repository, [output])["fingerprint_sha256"])


if __name__ == "__main__":
	unittest.main()
