#!/usr/bin/env python3
"""Run one end-to-end portable context_builder plan/review quality iteration."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))

from portable_oracle_mcp_smoke import (  # noqa: E402
	PROTOCOL_VERSION,
	StdioMCPClient,
	rpc_result,
	tool_json_outcome,
)

REPOSITORY = "https://github.com/sindresorhus/p-limit"
PINNED_COMMIT = "df476048d023ff868cd45b35ee47f5fb0ca2b25a"
ORACLE_ENDPOINT = "https://opencode.ai/zen/go/v1/chat/completions"
ORACLE_MODEL = "deepseek-v4-flash"
IMPLEMENTATION_MODEL = "opencode-go/deepseek-v4-flash"
FORWARDED_ORACLE_ENV = (
	"OPENCODE_API_KEY",
	"REPOPROMPT_ORACLE_ENDPOINT",
	"REPOPROMPT_ORACLE_PRIMARY_MODEL",
	"REPOPROMPT_ORACLE_SECONDARY_MODEL",
	"REPOPROMPT_ORACLE_API_KEY",
	"REPOPROMPT_ORACLE_TIMEOUT_SECONDS",
)
DEFAULT_PROVIDER_TIMEOUT_SECONDS = 600
TRANSPORT_GRACE_SECONDS = 30
DEFAULT_STDIO_TIMEOUT_SECONDS = DEFAULT_PROVIDER_TIMEOUT_SECONDS + TRANSPORT_GRACE_SECONDS
TASK = """Add AbortSignal support to pLimit options. When the signal aborts, reject queued tasks with signal.reason, reject future submissions immediately, and leave already-running tasks untouched. Update runtime implementation, TypeScript declarations, tests, and README documentation. Preserve existing rejectOnClear behavior and avoid abort-listener leaks."""
PLAN_REQUIRED_FILES = ("index.js", "index.d.ts", "index.test-d.ts", "test.js", "readme.md")
SELECTED_PATHS = [*PLAN_REQUIRED_FILES, "package.json"]
ALLOWED_PRODUCT_PATHS = set(PLAN_REQUIRED_FILES)
REVIEW_PATHS = [*SELECTED_PATHS, ".repoprompt-benchmark/review-evidence.json"]
COVERAGE_KEYS = [
	"queued_exact_reason", "future_immediate_rejection", "running_untouched", "pre_aborted_signal",
	"falsey_reason", "pending_count", "reject_on_clear", "listener_lifecycle", "derived_apis",
	"type_declarations", "tests", "documentation",
]
REVIEW_CATEGORY_IDS = {*COVERAGE_KEYS, "scope", "test_infrastructure", "other"}
PROBE_CASES = [
	"queued_exact_reason", "future_immediate_rejection", "running_untouched", "pre_aborted_signal",
	"falsey_reason_matrix", "reject_on_clear_enabled", "reject_on_clear_disabled", "listener_lifecycle",
	"map_propagation", "limit_function_propagation",
]
PLAN_RESULT_SCHEMA_VERSION = 3
PLAN_REQUIRED_TEST_CASE_IDS = {
	"abort-listener-queue-state-machine",
	"expected-rejections-observed-before-trigger",
}
PLAN_REQUIRED_SEMANTICS = {
	"listener_lifecycle": {
		"attach_transition": "queue_0_to_1",
		"detach_transition": "queue_1_to_0",
		"initial_idle_listener_count": 0,
		"pre_aborted_listener_count": 0,
		"running_only_listener_count": 0,
		"queued_listener_count": 1,
		"after_natural_drain_listener_count": 0,
		"after_clear_queue_listener_count": 0,
		"after_abort_listener_count": 0,
		"repeated_waves_accumulate": False,
		"once_alone_sufficient": False,
		"future_submission_abort_check": "signal_state_per_submission",
	},
	"rejection_observation": {
		"observer_timing": "before_abort_or_clear",
		"scope": "every_intentionally_rejected_promise",
		"awaiting": "all_observers_after_trigger",
		"unhandled_rejections_allowed": False,
	},
}
PLAN_INSTRUCTIONS = TASK + """

Return a concrete implementation plan.

Adversarial semantic requirements for plan eligibility:

1. Treat the abort listener as queue-scoped state, not limiter-lifetime state. For a limiter configured with a present, not-yet-aborted signal, attach the single abort listener only on the queue-size 0 -> 1 transition and remove it on the queue-size 1 -> 0 transition. The 1 -> 0 transition includes promotion of the final queued task to running, natural drain, clearQueue(), and abort. Initial idle state, a pre-aborted signal, running-only work, natural drain, either clearQueue() mode, and post-abort state must each retain zero abort listeners. Un-aborted queued work must retain exactly one abort listener in total, whether registered through addEventListener or onabort. Repeated queue waves may reattach the listener but must not accumulate listeners. `{once: true}` may supplement cleanup after abort, but it is not sufficient by itself because it does not clean up after natural drain or clearQueue().

2. Because abort may occur while the queue is empty and no listener is installed, every future submission must consult the signal's current aborted state and exact reason. Do not rely only on a cached flag written by the queue-scoped listener.

3. For every promise intentionally expected to reject because of abort or rejecting clearQueue(), attach a rejection observer before invoking abort() or clearQueue(), then await every observer after the trigger. This also applies to tests whose primary assertion concerns pendingCount or listener cleanup. Creating raw promises, triggering rejection, and only then attaching assertions is invalid because it can produce unhandled rejections.

4. The prose plan must describe the queue 0 -> 1 attach transition, every queue 1 -> 0 detach path, the per-submission aborted-state check, and the pre-trigger rejection-observer pattern. `test_case_ids` must include `abort-listener-queue-state-machine` and `expected-rejections-observed-before-trigger`.

5. `files_to_modify` must contain exactly `index.js`, `index.d.ts`, `index.test-d.ts`, `test.js`, and `readme.md`, each exactly once. Reordering is allowed; omissions, duplicates, and additional paths are invalid.

End the response with exactly one machine-readable block and no text after it. The `semantic_requirements` object must exactly match the literal values below:
<portable_plan_result>
{"schema_version":3,"verdict":"ready|needs_changes","blocking_issues":[{"category":"one of the coverage keys","summary":"concise"}],"coverage":{"queued_exact_reason":"covered|missing","future_immediate_rejection":"covered|missing","running_untouched":"covered|missing","pre_aborted_signal":"covered|missing","falsey_reason":"covered|missing","pending_count":"covered|missing","reject_on_clear":"covered|missing","listener_lifecycle":"covered|missing","derived_apis":"covered|missing","type_declarations":"covered|missing","tests":"covered|missing","documentation":"covered|missing"},"semantic_requirements":{"listener_lifecycle":{"attach_transition":"queue_0_to_1","detach_transition":"queue_1_to_0","initial_idle_listener_count":0,"pre_aborted_listener_count":0,"running_only_listener_count":0,"queued_listener_count":1,"after_natural_drain_listener_count":0,"after_clear_queue_listener_count":0,"after_abort_listener_count":0,"repeated_waves_accumulate":false,"once_alone_sufficient":false,"future_submission_abort_check":"signal_state_per_submission"},"rejection_observation":{"observer_timing":"before_abort_or_clear","scope":"every_intentionally_rejected_promise","awaiting":"all_observers_after_trigger","unhandled_rejections_allowed":false}},"files_to_modify":["index.js","index.d.ts","index.test-d.ts","test.js","readme.md"],"test_case_ids":["abort-listener-queue-state-machine","expected-rejections-observed-before-trigger","other-stable-ids"]}
</portable_plan_result>"""
REVIEW_INSTRUCTIONS = TASK + """

Review the selected changed implementation and review-evidence.json. Report concrete defects only. End with exactly one block and no text after it:
<portable_review_result>
{"schema_version":1,"verdict":"pass|changes_requested","findings":[{"category":"coverage key, scope, test_infrastructure, or other","severity":"blocking|non_blocking","file":"path or null","summary":"concise"}],"coverage":{"queued_exact_reason":"pass|fail|not_verified","future_immediate_rejection":"pass|fail|not_verified","running_untouched":"pass|fail|not_verified","pre_aborted_signal":"pass|fail|not_verified","falsey_reason":"pass|fail|not_verified","pending_count":"pass|fail|not_verified","reject_on_clear":"pass|fail|not_verified","listener_lifecycle":"pass|fail|not_verified","derived_apis":"pass|fail|not_verified","type_declarations":"pass|fail|not_verified","tests":"pass|fail|not_verified","documentation":"pass|fail|not_verified"},"evidence_considered":{"diff":true,"semantic_probe":true,"npm_test":true}}
</portable_review_result>"""


@dataclass(frozen=True)
class CommandResult:
	command: str
	exit_code: int
	duration_seconds: float
	stdout: str
	stderr: str
	timed_out: bool


def utc_now() -> str:
	return datetime.now(timezone.utc).isoformat()


def sha256_bytes(value: bytes) -> str:
	return hashlib.sha256(value).hexdigest()


def sha256_text(value: str) -> str:
	return sha256_bytes(value.encode())


def file_sha256(path: Path) -> str:
	return sha256_bytes(path.read_bytes())


def redact(value: Any, secret: str) -> Any:
	if isinstance(value, str):
		redacted = value.replace(secret, "[REDACTED]") if secret else value
		return re.sub(r"(?i)(authorization\s*:\s*bearer\s+)[^\s\"']+", r"\1[REDACTED]", redacted)
	if isinstance(value, list):
		return [redact(item, secret) for item in value]
	if isinstance(value, dict):
		return {key: redact(item, secret) for key, item in value.items()}
	return value


def sanitize_endpoint(endpoint: str) -> dict[str, Any]:
	parsed = urlsplit(endpoint)
	if parsed.scheme not in {"http", "https"} or not parsed.hostname:
		raise ValueError("Oracle endpoint must be an absolute HTTP(S) URL")
	return {
		"scheme": parsed.scheme,
		"host": parsed.hostname,
		"port": parsed.port or (443 if parsed.scheme == "https" else 80),
		"path": parsed.path or "/",
		"query_present": bool(parsed.query),
		"source": "explicit_harness_environment",
	}


def image_provenance(requested: str, inspect_payload: Any) -> dict[str, Any]:
	if not isinstance(inspect_payload, list) or len(inspect_payload) != 1 or not isinstance(inspect_payload[0], dict):
		raise ValueError("docker image inspect returned an unexpected payload")
	row = inspect_payload[0]
	image_id = row.get("Id")
	if not isinstance(image_id, str) or not image_id.startswith("sha256:"):
		raise ValueError("docker image inspect did not return an immutable image ID")
	digests = row.get("RepoDigests") or []
	return {
		"requested": requested,
		"image_id": image_id,
		"repo_digest": next((item for item in digests if isinstance(item, str)), None),
	}


def run_command(command: list[str], timeout: float, secret: str = "", cwd: Path | None = None) -> CommandResult:
	started = time.monotonic()
	try:
		completed = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=timeout, check=False)
		code, stdout, stderr, timed_out = completed.returncode, completed.stdout, completed.stderr, False
	except subprocess.TimeoutExpired as error:
		code, stdout, stderr, timed_out = 124, error.stdout or "", error.stderr or "", True
		if isinstance(stdout, bytes):
			stdout = stdout.decode(errors="replace")
		if isinstance(stderr, bytes):
			stderr = stderr.decode(errors="replace")
	return CommandResult(
		command=redact(shlex.join(command), secret),
		exit_code=code,
		duration_seconds=round(time.monotonic() - started, 3),
		stdout=redact(stdout[-65_536:], secret),
		stderr=redact(stderr[-65_536:], secret),
		timed_out=timed_out,
	)


def resolve_image(requested: str, secret: str) -> dict[str, Any]:
	result = run_command(["docker", "image", "inspect", requested], 30, secret)
	if result.exit_code != 0:
		raise RuntimeError(f"image is not available locally: {requested}: {result.stderr}")
	return image_provenance(requested, json.loads(result.stdout))


def docker_version(image_id: str, entrypoint: str, arguments: list[str], secret: str) -> str:
	result = run_command(["docker", "run", "--rm", "--entrypoint", entrypoint, image_id, *arguments], 60, secret)
	if result.exit_code != 0:
		raise RuntimeError(f"failed to inspect {entrypoint} version: {result.stderr}")
	return result.stdout.strip()


def git_output(repository: Path, arguments: list[str], timeout: float = 60) -> str:
	result = run_command(["git", "-C", str(repository), *arguments], timeout)
	if result.exit_code != 0:
		raise RuntimeError(f"git {' '.join(arguments)} failed: {result.stderr}")
	return result.stdout.strip()


def clone_at_pin(source: Path, destination: Path) -> dict[str, Any]:
	clone = run_command(["git", "clone", "--quiet", "--no-hardlinks", str(source), str(destination)], 120)
	if clone.exit_code != 0:
		raise RuntimeError(f"git clone failed: {clone.stderr}")
	checkout = run_command(["git", "-C", str(destination), "checkout", "--quiet", "--detach", PINNED_COMMIT], 60)
	if checkout.exit_code != 0:
		raise RuntimeError(f"p-limit checkout failed: {checkout.stderr}")
	head = git_output(destination, ["rev-parse", "HEAD"])
	status = git_output(destination, ["status", "--porcelain=v1", "--untracked-files=all"])
	if head != PINNED_COMMIT or status:
		raise RuntimeError(f"disposable p-limit clone is not pristine at {PINNED_COMMIT}")
	return {
		"commit": head,
		"tree": git_output(destination, ["rev-parse", "HEAD^{tree}"]),
		"package_lock_sha256": file_sha256(destination / "package-lock.json") if (destination / "package-lock.json").exists() else None,
	}


def normalize_context_path(path: str) -> str:
	return path.split(":", 1)[-1] if path.startswith("root[") else path


def validate_pair(
	value: dict[str, Any],
	expected_paths: Iterable[str],
	response_type: str,
	instructions: str,
) -> tuple[bool, list[str]]:
	errors: list[str] = []
	if value.get("ok") is not True or value.get("status") != "response_generated":
		errors.append("builder_status")
	if value.get("response_type") != response_type or value.get("prompt") != instructions.strip():
		errors.append("builder_request_projection")
	if value.get("pair_status") != "completed" or value.get("oracle_decision_policy") != "caller_decides":
		errors.append("pair_status")
	try:
		uuid.UUID(value.get("oracle_pair_id", ""))
	except (ValueError, TypeError, AttributeError):
		errors.append("oracle_pair_id")
	if value.get("model_raw_id") != ORACLE_MODEL:
		errors.append("primary_model_projection")
	results = value.get("oracle_results")
	if not isinstance(results, dict):
		errors.append("oracle_results")
		results = {}
	for lane in ("primary", "secondary"):
		row = results.get(lane)
		if not isinstance(row, dict) or row.get("status") != "completed" or row.get("oracle_lane") != lane:
			errors.append(f"{lane}_status")
		elif row.get("provider") != "openai_compatible" or row.get("model_raw_id") != ORACLE_MODEL or not isinstance(row.get("response"), str):
			errors.append(f"{lane}_model_or_response")
	primary = results.get("primary") if isinstance(results.get("primary"), dict) else {}
	if value.get("response") != primary.get("response"):
		errors.append("primary_projection")
	context = value.get("workspace_context")
	if not isinstance(context, dict):
		errors.append("workspace_context")
	else:
		entries = context.get("entries") or []
		paths = [normalize_context_path(row.get("path", "")) for row in entries if isinstance(row, dict)]
		selection = context.get("selection") if isinstance(context.get("selection"), dict) else {}
		selected_paths = [normalize_context_path(path) for path in selection.get("selected_paths", []) if isinstance(path, str)]
		if paths != list(expected_paths) or selected_paths != list(expected_paths):
			errors.append("context_entries")
		if context.get("truncated") is not False or context.get("omissions") != []:
			errors.append("context_completeness")
	return not errors, errors


def normalize_prior_feedback(artifact: dict[str, Any]) -> dict[str, Any]:
	review = artifact.get("review") if isinstance(artifact.get("review"), dict) else {}
	lane_categories = []
	for lane in ("primary", "secondary"):
		row = review.get(lane) if isinstance(review.get(lane), dict) else {}
		contract = row.get("contract") if row.get("parse_status") == "valid" and isinstance(row.get("contract"), dict) else {}
		findings = contract.get("findings") if isinstance(contract.get("findings"), list) else []
		lane_categories.append({
			finding["category"]
			for finding in findings
			if isinstance(finding, dict)
			and finding.get("severity") == "blocking"
			and finding.get("category") in REVIEW_CATEGORY_IDS
		})

	gates = artifact.get("score", {}).get("gates", {}) if isinstance(artifact.get("score"), dict) else {}
	verification = artifact.get("verification") if isinstance(artifact.get("verification"), dict) else {}
	application = artifact.get("application") if isinstance(artifact.get("application"), dict) else {}
	failed_gates: dict[str, Any] = {}
	if gates.get("application_scope") is False:
		failed_gates["application_scope"] = {
			"apply_exit_code": application.get("outcome", {}).get("exit_code"),
			"scope_valid": application.get("scope", {}).get("valid"),
		}
	probe = verification.get("semantic_probe") if isinstance(verification.get("semantic_probe"), dict) else {}
	if probe.get("passed") is False:
		cases = probe.get("cases") if isinstance(probe.get("cases"), list) else []
		failed_gates["semantic_probe"] = {
			"passed_count": probe.get("passed_count"),
			"failed_case_ids": sorted(
				row["id"] for row in cases
				if isinstance(row, dict) and row.get("passed") is not True and row.get("id") in PROBE_CASES
			),
		}
	if gates.get("npm_test") is False:
		npm_test = verification.get("npm_test") if isinstance(verification.get("npm_test"), dict) else {}
		failed_gates["npm_test"] = {"exit_code": npm_test.get("exit_code"), "timed_out": npm_test.get("timed_out")}
	if gates.get("static_contract") is False:
		static = verification.get("static_contract") if isinstance(verification.get("static_contract"), dict) else {}
		failed_gates["static_contract"] = {"failed_checks": sorted(
			key for key in ("required_files_modified", "signal_type", "signal_type_tests", "runtime_signal", "readme_semantics")
			if static.get(key) is False
		)}

	return {
		"dual_lane_blocking_categories": sorted(lane_categories[0] & lane_categories[1]),
		"deterministic_failed_gates": failed_gates,
	}


def prior_feedback_instructions(feedback: dict[str, Any]) -> str:
	categories = ", ".join(feedback["dual_lane_blocking_categories"]) or "none"
	facts = json.dumps(feedback["deterministic_failed_gates"], sort_keys=True, separators=(",", ":"))
	return f"""

Prior-artifact feedback for this plan only (normalized categories and deterministic facts; never prior review prose):
- Recurring dual-lane blocking categories: {categories}.
- Deterministic failed-gate facts: {facts}.
- Preserve the three existing `index.js` ESLint suppression directives: `// eslint-disable-line promise/param-names`, `// eslint-disable-line promise/prefer-await-to-then`, and `// eslint-disable-next-line no-unmodified-loop-condition`.
- Place README `signal` documentation under the `pLimit(concurrency)` options beside `rejectOnClear` and under `limitFunction(fn, options)` options; retain the exact terms `signal`, `queued`, `running`, `reason`, and `rejectOnClear`.
Do not change the plan-result schema, delimiter, or selection contract.
"""


def parse_delimited(text: str, tag: str) -> dict[str, Any] | None:
	matches = list(re.finditer(rf"<{tag}>\s*(.*?)\s*</{tag}>", text, re.DOTALL))
	if len(matches) != 1 or text[matches[0].end():].strip():
		return None
	try:
		value = json.loads(matches[0].group(1))
	except json.JSONDecodeError:
		return None
	return value if isinstance(value, dict) else None


def parse_plan_lane(lane: str, raw: str) -> dict[str, Any]:
	contract = parse_delimited(raw, "portable_plan_result")
	valid = isinstance(contract, dict) and contract.get("schema_version") == PLAN_RESULT_SCHEMA_VERSION
	if valid:
		coverage = contract.get("coverage")
		test_case_ids = contract.get("test_case_ids")
		valid = (
			set(contract) == {
				"schema_version", "verdict", "blocking_issues", "coverage", "semantic_requirements",
				"files_to_modify", "test_case_ids",
			}
			and contract.get("verdict") in {"ready", "needs_changes"}
			and isinstance(contract.get("blocking_issues"), list)
			and isinstance(coverage, dict)
			and set(coverage) == set(COVERAGE_KEYS)
			and all(value in {"covered", "missing"} for value in coverage.values())
			and json.dumps(contract.get("semantic_requirements"), sort_keys=True, separators=(",", ":")) == json.dumps(PLAN_REQUIRED_SEMANTICS, sort_keys=True, separators=(",", ":"))
			and isinstance(contract.get("files_to_modify"), list)
			and all(isinstance(item, str) for item in contract["files_to_modify"])
			and len(contract["files_to_modify"]) == len(PLAN_REQUIRED_FILES)
			and set(contract["files_to_modify"]) == ALLOWED_PRODUCT_PATHS
			and isinstance(test_case_ids, list)
			and all(isinstance(item, str) and item for item in test_case_ids)
			and PLAN_REQUIRED_TEST_CASE_IDS <= set(test_case_ids)
		)
	result = {"lane": lane, "raw_response": raw, "response_sha256": sha256_text(raw), "parse_status": "valid" if valid else "invalid", "contract": contract if valid else None, "eligible": False, "score": 0}
	if not valid:
		return result
	coverage = contract["coverage"]
	files = set(contract["files_to_modify"])
	eligible = contract["verdict"] == "ready" and not contract["blocking_issues"] and all(value == "covered" for value in coverage.values()) and ALLOWED_PRODUCT_PATHS <= files and files <= set(SELECTED_PATHS)
	score = sum(value == "covered" for value in coverage.values())
	score += 5 if contract["verdict"] == "ready" and not contract["blocking_issues"] else 0
	score += 5 if ALLOWED_PRODUCT_PATHS <= files and files <= set(SELECTED_PATHS) else 0
	score += min(10, len(contract["test_case_ids"]))
	result.update(eligible=eligible, score=score)
	return result


def select_plan(primary: dict[str, Any], secondary: dict[str, Any]) -> dict[str, Any]:
	eligible = [row for row in (primary, secondary) if row["eligible"]]
	if not eligible:
		return {"selected_lane": None, "reason": "neither lane produced an eligible structured plan", "score": None}
	selected = sorted(eligible, key=lambda row: (row["score"], row["lane"] == "primary"), reverse=True)[0]
	return {"selected_lane": selected["lane"], "reason": "highest eligibility score; Primary wins exact ties", "score": selected["score"], "response_sha256": selected["response_sha256"]}


def parse_review_lane(lane: str, raw: str) -> dict[str, Any]:
	contract = parse_delimited(raw, "portable_review_result")
	valid = isinstance(contract, dict) and contract.get("schema_version") == 1
	if valid:
		coverage = contract.get("coverage")
		findings = contract.get("findings")
		valid = (
			contract.get("verdict") in {"pass", "changes_requested"}
			and isinstance(findings, list)
			and isinstance(coverage, dict)
			and set(coverage) == set(COVERAGE_KEYS)
			and all(value in {"pass", "fail", "not_verified"} for value in coverage.values())
			and isinstance(contract.get("evidence_considered"), dict)
		)
	return {"lane": lane, "raw_response": raw, "response_sha256": sha256_text(raw), "parse_status": "valid" if valid else "invalid", "contract": contract if valid else None}


def review_agreement(primary: dict[str, Any], secondary: dict[str, Any], deterministic_gates: bool) -> dict[str, Any]:
	contracts = [primary.get("contract"), secondary.get("contract")]
	if any(not isinstance(item, dict) for item in contracts):
		return {"verdict_agreement": False, "finding_category_agreement": False, "finding_category_jaccard": 0.0, "acceptance_agreement": False}
	categories = [{item.get("category") for item in contract["findings"] if isinstance(item, dict)} for contract in contracts]
	union = categories[0] | categories[1]
	intersection = categories[0] & categories[1]
	verdict_agreement = contracts[0]["verdict"] == contracts[1]["verdict"]
	blocking = any(item.get("severity") == "blocking" for contract in contracts for item in contract["findings"] if isinstance(item, dict))
	coverage_pass = all(all(value == "pass" for value in contract["coverage"].values()) for contract in contracts)
	acceptance = deterministic_gates and verdict_agreement and all(contract["verdict"] == "pass" for contract in contracts) and not blocking and coverage_pass
	return {
		"verdict_agreement": verdict_agreement,
		"finding_category_agreement": categories[0] == categories[1],
		"finding_category_jaccard": round(len(intersection) / len(union), 3) if union else 1.0,
		"acceptance_agreement": acceptance,
	}


def run_builder_phase(workspace: Path, image_id: str, timeout: float, response_type: str, instructions: str, paths: list[str], max_context_bytes: int, secret: str) -> dict[str, Any]:
	name = f"rp-quality-{response_type}-{uuid.uuid4().hex[:10]}"
	command = [
		"docker", "run", "--rm", "-i", "--name", name,
		"--mount", f"type=bind,src={workspace},dst=/workspace,readonly",
	]
	for variable in FORWARDED_ORACLE_ENV:
		command += ["--env", variable]
	command += [image_id, "--no-persist", "--root", "/workspace"]
	started = time.monotonic()
	client: StdioMCPClient | None = None
	failure: str | None = None
	initialized: dict[str, Any] | None = None
	selection: dict[str, Any] | None = None
	tool: dict[str, Any] | None = None
	is_error = False
	return_code = -1
	stderr = ""
	timed_out = False
	try:
		client = StdioMCPClient(command, timeout)
		initialized = rpc_result(client.request("initialize", {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "portable-quality-benchmark", "version": "1"}}), "initialize")
		client.notify("notifications/initialized")
		selection = tool_json_outcome(client, "manage_selection", {"op": "set", "mode": "full", "paths": paths, "view": "files"}).value
		outcome = tool_json_outcome(client, "context_builder", {"instructions": instructions, "response_type": response_type, "max_context_bytes": max_context_bytes})
		tool, is_error = outcome.value, outcome.is_error
	except BaseException as error:
		failure = str(error)
	finally:
		if client is not None:
			return_code, stderr, timed_out = client.close_and_wait()
		if timed_out:
			run_command(["docker", "rm", "-f", name], 30, secret)
	valid, validation_errors = validate_pair(tool or {}, paths, response_type, instructions) if tool and not is_error else (False, ["tool_error"])
	if return_code != 0 or timed_out or failure is not None:
		valid = False
		validation_errors.append("transport")
	return redact({
		"status": "completed" if valid else "failed", "duration_seconds": round(time.monotonic() - started, 3),
		"command": shlex.join(command), "initialize": initialized, "selection": selection, "tool_result": tool,
		"tool_is_error": is_error, "transport": {"exit_code": return_code, "timed_out": timed_out, "stderr": stderr},
		"validation_errors": validation_errors, "error": failure,
	}, secret)


def write_opencode_config(provider_timeout: int) -> Path:
	config_handle = tempfile.NamedTemporaryFile("w", prefix="rp-quality-", suffix=".json", delete=False)
	json.dump({
		"model": IMPLEMENTATION_MODEL,
		"small_model": IMPLEMENTATION_MODEL,
		"mcp": {"repoprompt-portable": {"type": "local", "command": ["/usr/local/bin/repoprompt-headless", "--no-persist", "--root", "/workspace"], "enabled": True, "timeout": (provider_timeout + TRANSPORT_GRACE_SECONDS) * 1_000}},
	}, config_handle)
	config_handle.close()
	os.chmod(config_handle.name, 0o600)
	return Path(config_handle.name)


def remove_generated(path: Path, sensitive: bool = False) -> None:
	if not path.exists():
		return
	if sensitive:
		path.unlink()
		return
	trash = shutil.which("trash")
	if trash:
		subprocess.run([trash, str(path)], check=False, capture_output=True)


def package_install_command(workspace: Path) -> str:
	return "npm ci --no-audit --no-fund" if (workspace / "package-lock.json").exists() else "npm install --no-package-lock --no-audit --no-fund"


def node_command(image_id: str, workspace: Path, shell_command: str, timeout: float, secret: str, network_none: bool = False, extra_mounts: list[str] | None = None) -> CommandResult:
	command = ["docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}", "--env", "HOME=/tmp", "--workdir", "/workspace", "--mount", f"type=bind,src={workspace},dst=/workspace"]
	if network_none:
		command += ["--network", "none"]
	for mount in extra_mounts or []:
		command += ["--mount", mount]
	command += [image_id, "sh", "-lc", shell_command]
	return run_command(command, timeout, secret)


def apply_selected_plan(workspace: Path, image_id: str, config_file: Path, timeout: float, secret: str) -> CommandResult:
	name = f"rp-quality-apply-{uuid.uuid4().hex[:10]}"
	instruction = "Read .repoprompt-benchmark/task.md and selected-plan.md. Implement only that task. Modify only index.js, index.d.ts, index.test-d.ts, test.js, and readme.md. Do not change dependencies, package.json, lockfiles, or benchmark metadata. Do not commit. The task is authoritative if the plan conflicts."
	command = [
		"docker", "run", "--rm", "--name", name, "--user", f"{os.getuid()}:{os.getgid()}", "--workdir", "/workspace",
		"--mount", f"type=bind,src={workspace},dst=/workspace", "--mount", f"type=bind,src={config_file},dst=/run/repoprompt/opencode.json,readonly",
	]
	for variable in FORWARDED_ORACLE_ENV:
		command += ["--env", variable]
	command += [
		"--env", "OPENCODE_CONFIG=/run/repoprompt/opencode.json", "--env", "HOME=/tmp",
		"--entrypoint", "/usr/local/bin/opencode", image_id, "run", instruction,
	]
	result = run_command(command, timeout, secret)
	if result.timed_out:
		run_command(["docker", "rm", "-f", name], 30, secret)
	return result


def scope_is_valid(tracked_rows: list[list[str]], untracked: list[str], metadata_unchanged: bool) -> bool:
	tracked_paths = [part for row in tracked_rows for part in row[1:]]
	outside_untracked = [path for path in untracked if not path.startswith(".repoprompt-benchmark/")]
	return bool(tracked_paths) and set(tracked_paths) <= ALLOWED_PRODUCT_PATHS and not outside_untracked and all(row[0] == "M" for row in tracked_rows) and metadata_unchanged


def scope_result(workspace: Path, metadata_hashes: dict[str, str]) -> dict[str, Any]:
	name_status = git_output(workspace, ["diff", "--name-status", "HEAD"])
	tracked_rows = [line.split("\t") for line in name_status.splitlines() if line]
	tracked_paths = [part for row in tracked_rows for part in row[1:]]
	untracked = [line for line in git_output(workspace, ["ls-files", "--others", "--exclude-standard"]).splitlines() if line]
	reserved = [path for path in untracked if path.startswith(".repoprompt-benchmark/")]
	outside_untracked = [path for path in untracked if path not in reserved]
	metadata_unchanged = all((workspace / path).exists() and file_sha256(workspace / path) == digest for path, digest in metadata_hashes.items())
	valid = scope_is_valid(tracked_rows, untracked, metadata_unchanged)
	diff = git_output(workspace, ["diff", "--no-ext-diff", "--binary", "HEAD"], 60)
	return {
		"valid": valid, "changed_files": sorted(set(tracked_paths)), "tracked_status": tracked_rows,
		"outside_untracked": outside_untracked, "metadata_unchanged": metadata_unchanged,
		"diff_sha256": sha256_text(diff), "diff_bytes": len(diff.encode()), "diff": diff,
	}


def static_contract(workspace: Path, changed_files: list[str]) -> dict[str, bool]:
	js = (workspace / "index.js").read_text()
	types = (workspace / "index.d.ts").read_text()
	type_tests = (workspace / "index.test-d.ts").read_text()
	readme = (workspace / "readme.md").read_text()
	return {
		"required_files_modified": ALLOWED_PRODUCT_PATHS <= set(changed_files),
		"signal_type": bool(re.search(r"readonly\s+signal\??\s*:\s*AbortSignal", types)),
		"signal_type_tests": "signal" in type_tests and ("expectError" in type_tests or "expectType" in type_tests),
		"runtime_signal": "signal" in js and "signal.reason" in js,
		"readme_semantics": all(term in readme.lower() for term in ("signal", "queued", "running", "reason", "rejectonclear")),
	}


def command_evidence(result: CommandResult, tail_bytes: int = 4_000) -> dict[str, Any]:
	value = asdict(result)
	value["stdout"] = value["stdout"][-tail_bytes:]
	value["stderr"] = value["stderr"][-tail_bytes:]
	return value


def parse_probe(result: CommandResult) -> dict[str, Any]:
	try:
		payload = json.loads(result.stdout.strip().splitlines()[-1])
	except (json.JSONDecodeError, IndexError):
		payload = {"schema_version": 1, "passed": False, "cases": [], "parse_error": True}
	cases = payload.get("cases") if isinstance(payload, dict) else []
	case_map = {row.get("id"): row.get("passed") is True for row in cases if isinstance(row, dict)}
	payload["complete"] = set(case_map) == set(PROBE_CASES)
	payload["passed_count"] = sum(case_map.values())
	payload["passed"] = result.exit_code == 0 and payload.get("passed") is True and payload["complete"] and all(case_map.values())
	payload["command"] = asdict(result)
	return payload


def quality_score(gates: dict[str, bool], probe_passed_count: int) -> int:
	return (
		(10 if gates.get("provenance_isolation") else 0)
		+ (10 if gates.get("plan_transport") else 0)
		+ (5 if gates.get("plan_selection") else 0)
		+ (10 if gates.get("application_scope") else 0)
		+ 3 * probe_passed_count
		+ (15 if gates.get("npm_test") else 0)
		+ (5 if gates.get("static_contract") else 0)
		+ (5 if gates.get("review_transport") else 0)
		+ (5 if gates.get("review_verdict_agreement") else 0)
		+ (5 if gates.get("review_acceptance") else 0)
	)


def decision(iteration: int, end_to_end_pass: bool, invalid_environment: bool = False) -> dict[str, str]:
	if invalid_environment:
		return {"action": "invalid_environment", "reason": "pristine npm verification failed"}
	if end_to_end_pass:
		return {"action": "stop_success", "reason": "all deterministic gates and both review lanes passed"}
	if iteration >= 5:
		return {"action": "stop_iteration_cap", "reason": "hardening iteration cap reached"}
	return {"action": "continue", "reason": "one or more mandatory gates failed"}


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
	path.parent.mkdir(parents=True, exist_ok=True)
	temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
	temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
	os.replace(temporary, path)


def append_scoreboard(path: Path, artifact: dict[str, Any], artifact_path: Path) -> None:
	run = artifact["run"]
	marker = f"### Iteration {run['iteration']} — `{run['run_id']}`"
	existing = path.read_text() if path.exists() else "# Portable context_builder Plan/Review Quality Runs\n"
	if marker in existing or f"run_id: `{run['run_id']}`" in existing:
		raise ValueError(f"scoreboard already contains run {run['run_id']}")
	plan = artifact.get("plan", {})
	review = artifact.get("review", {})
	score = artifact["score"]
	provenance = artifact["provenance"]
	portable_image = provenance["portable_image"]
	node_image = provenance["node_image"]
	oracle = provenance.get("oracle", {})
	endpoint = oracle.get("endpoint_identity", {})
	timeouts = provenance["timeouts"]
	section = f"""

{marker}

- run_id: `{run['run_id']}`
- Label/candidate: {run['label']} / {run['candidate_id']} — {run['attributed_change']}
- Images: portable `{portable_image.get('requested')}` → `{portable_image['image_id']}` / `{portable_image.get('repo_digest')}`; Node `{node_image.get('requested')}` → `{node_image['image_id']}` / `{node_image.get('repo_digest')}`
- Endpoint/models: `{endpoint.get('scheme')}://{endpoint.get('host')}:{endpoint.get('port')}{endpoint.get('path')}`; `{oracle.get('primary_model', ORACLE_MODEL)}` + `{oracle.get('secondary_model', ORACLE_MODEL)}`; agent `{oracle.get('implementation_model')}`
- Timeouts: provider {timeouts['provider_seconds']}s, stdio {timeouts['stdio_seconds']}s, agent MCP {timeouts.get('agent_mcp_seconds')}s, application {timeouts.get('application_seconds')}s, test {timeouts.get('test_seconds')}s
- p-limit: `{artifact['p_limit']['commit']}` / tree `{artifact['p_limit']['tree']}`
- Plan pair/selected: {plan.get('phase', {}).get('status', 'skipped')} / {plan.get('selection', {}).get('selected_lane')}
- Application/scope: exit {artifact.get('application', {}).get('outcome', {}).get('exit_code')} / {artifact.get('application', {}).get('scope', {}).get('valid')}
- Probe/npm: {artifact.get('verification', {}).get('semantic_probe', {}).get('passed_count', 0)}/10 / exit {artifact.get('verification', {}).get('npm_test', {}).get('exit_code')}
- Review verdicts/agreement: {review.get('primary', {}).get('contract', {}).get('verdict') if review.get('primary', {}).get('contract') else None} / {review.get('secondary', {}).get('contract', {}).get('verdict') if review.get('secondary', {}).get('contract') else None} / {review.get('agreement', {}).get('acceptance_agreement', False)}
- Score/decision: **{score['points']}/100** / `{artifact['decision']['action']}`
- Artifact: `{artifact_path}`
"""
	with path.open("a") as handle:
		handle.write(section)
		handle.flush()
		os.fsync(handle.fileno())


def portable_fingerprint(repository: Path, exclusions: list[Path]) -> dict[str, Any]:
	rel_exclusions = []
	for path in exclusions:
		try:
			rel_exclusions.append(path.resolve().relative_to(repository.resolve()).as_posix())
		except ValueError:
			pass
	pathspec = [".", *[f":(exclude){path}" for path in rel_exclusions]]
	tracked = git_output(repository, ["diff", "--binary", "HEAD", "--", *pathspec], 120)
	staged = git_output(repository, ["diff", "--cached", "--binary", "HEAD", "--", *pathspec], 120)
	untracked_rows = []
	for relative in git_output(repository, ["ls-files", "--others", "--exclude-standard"]).splitlines():
		if relative and relative not in rel_exclusions and not any(relative.startswith(path + "/") for path in rel_exclusions):
			path = repository / relative
			if path.is_file():
				untracked_rows.append((relative, file_sha256(path)))
	payload = {"head": git_output(repository, ["rev-parse", "HEAD"]), "tracked_sha256": sha256_text(tracked), "staged_sha256": sha256_text(staged), "untracked": untracked_rows}
	payload["fingerprint_sha256"] = sha256_text(json.dumps(payload, sort_keys=True))
	return payload


def comparable_provenance(artifact: dict[str, Any]) -> dict[str, Any]:
	provenance = artifact["provenance"]
	return {
		"portable_image": provenance["portable_image"], "node_image": provenance["node_image"],
		"endpoint": provenance["oracle"]["endpoint_identity"], "primary_model": provenance["oracle"]["primary_model"],
		"secondary_model": provenance["oracle"]["secondary_model"], "implementation_model": provenance["oracle"]["implementation_model"],
		"timeouts": provenance["timeouts"], "commit": artifact["p_limit"]["commit"], "probe_sha256": provenance["probe_sha256"],
		"selected_paths": artifact["p_limit"]["selected_paths"], "max_context_bytes": provenance["max_context_bytes"],
	}


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--workspace", required=True, type=Path, help="Read-only source Git repository containing the pinned p-limit commit")
	parser.add_argument("--image", default="ghcr.io/dsebban/repoprompt-portable:latest")
	parser.add_argument("--node-image", default="node:22-bookworm-slim")
	parser.add_argument("--output", required=True, type=Path)
	parser.add_argument("--scoreboard", type=Path, default=Path("prompt-exports/optimize-portable-plan-review-runs.md"))
	parser.add_argument("--iteration", type=int, default=0)
	parser.add_argument("--baseline-artifact", type=Path)
	parser.add_argument("--prior-artifact", type=Path)
	parser.add_argument("--label", default="baseline")
	parser.add_argument("--candidate-id", default="baseline")
	parser.add_argument("--attributed-change", default="Measurement harness only; no quality hardening candidate")
	parser.add_argument("--credential-source", default="host_env:OPENCODE_API_KEY")
	try:
		provider_timeout_default = int(os.environ.get("REPOPROMPT_ORACLE_TIMEOUT_SECONDS", DEFAULT_PROVIDER_TIMEOUT_SECONDS))
	except ValueError as error:
		raise SystemExit("REPOPROMPT_ORACLE_TIMEOUT_SECONDS must be an integer") from error
	parser.add_argument("--provider-timeout-seconds", type=int, default=provider_timeout_default)
	parser.add_argument("--stdio-timeout-seconds", type=float, default=DEFAULT_STDIO_TIMEOUT_SECONDS)
	parser.add_argument("--timeout-seconds", type=float, help="Deprecated alias for --stdio-timeout-seconds")
	parser.add_argument("--apply-timeout-seconds", type=float, default=900)
	parser.add_argument("--test-timeout-seconds", type=float, default=600)
	parser.add_argument("--max-context-bytes", type=int, default=1_048_576)
	parser.add_argument("--work-root", type=Path)
	parser.add_argument("--keep-workspace", action="store_true")
	return parser.parse_args()


def main() -> int:
	args = parse_args()
	if args.timeout_seconds is not None:
		if args.stdio_timeout_seconds != DEFAULT_STDIO_TIMEOUT_SECONDS:
			raise SystemExit("do not combine --timeout-seconds with --stdio-timeout-seconds")
		args.stdio_timeout_seconds = args.timeout_seconds
	if not 0 <= args.iteration <= 5:
		raise SystemExit("--iteration must be between 0 and 5")
	if args.iteration > 0 and (not args.baseline_artifact or args.candidate_id == "baseline"):
		raise SystemExit("hardening iterations require --baseline-artifact and a non-baseline --candidate-id")
	if not 1 <= args.provider_timeout_seconds <= DEFAULT_PROVIDER_TIMEOUT_SECONDS:
		raise SystemExit(f"provider timeout must be between 1 and {DEFAULT_PROVIDER_TIMEOUT_SECONDS} seconds")
	if args.stdio_timeout_seconds < args.provider_timeout_seconds + TRANSPORT_GRACE_SECONDS:
		raise SystemExit(f"stdio timeout must be at least provider timeout plus {TRANSPORT_GRACE_SECONDS} seconds")
	if min(args.provider_timeout_seconds, args.apply_timeout_seconds, args.test_timeout_seconds, args.max_context_bytes) <= 0:
		raise SystemExit("timeouts and max context bytes must be positive")
	secret = os.environ.get("OPENCODE_API_KEY", "")
	if not secret:
		raise SystemExit("OPENCODE_API_KEY is required")
	if "\n" in secret or "\r" in secret:
		raise SystemExit("OPENCODE_API_KEY may not contain a newline")
	os.environ.update({
		"REPOPROMPT_ORACLE_ENDPOINT": ORACLE_ENDPOINT,
		"REPOPROMPT_ORACLE_PRIMARY_MODEL": ORACLE_MODEL,
		"REPOPROMPT_ORACLE_SECONDARY_MODEL": ORACLE_MODEL,
		"REPOPROMPT_ORACLE_API_KEY": secret,
		"REPOPROMPT_ORACLE_TIMEOUT_SECONDS": str(args.provider_timeout_seconds),
	})

	repository = Path(__file__).resolve().parents[1]
	output = args.output.resolve()
	if output.exists():
		raise SystemExit(f"output already exists; choose a new artifact path: {output}")
	scoreboard = args.scoreboard.resolve()
	probe_path = repository / "benchmarks/p_limit_abortsignal_probe.mjs"
	before = portable_fingerprint(repository, [output, scoreboard])
	run_id = str(uuid.uuid4())
	started_at = utc_now()
	work_root = args.work_root.resolve() if args.work_root else Path(tempfile.mkdtemp(prefix=f"rp-portable-quality-{run_id[:8]}-"))
	if args.work_root:
		work_root.mkdir(parents=True, exist_ok=True)
	config_file: Path | None = None
	artifact: dict[str, Any] | None = None
	try:
		source = args.workspace.resolve()
		if git_output(source, ["rev-parse", f"{PINNED_COMMIT}^{{commit}}"] ) != PINNED_COMMIT:
			raise RuntimeError("source workspace does not contain the pinned p-limit commit")
		portable_image = resolve_image(args.image, secret)
		node_image = resolve_image(args.node_image, secret)
		opencode_version = docker_version(portable_image["image_id"], "opencode", ["--version"], secret)
		node_version = docker_version(node_image["image_id"], "node", ["--version"], secret)
		npm_version = docker_version(node_image["image_id"], "npm", ["--version"], secret)
		config_file = write_opencode_config(args.provider_timeout_seconds)

		pristine = work_root / "pristine"
		pristine_identity = clone_at_pin(source, pristine)
		pristine_test = node_command(node_image["image_id"], pristine, f"{package_install_command(pristine)} && npm test", args.test_timeout_seconds, secret)
		pristine_clean = not git_output(pristine, ["status", "--porcelain=v1", "--untracked-files=all"])
		invalid_environment = pristine_test.exit_code != 0 or not pristine_clean

		iteration_workspace = work_root / "iteration"
		identity = clone_at_pin(source, iteration_workspace)
		provenance = {
			"portable_repository": {"head": before["head"], "dirty_worktree_fingerprint": before["fingerprint_sha256"]},
			"portable_image": portable_image, "node_image": node_image, "opencode_version": opencode_version,
			"node_version": node_version, "npm_version": npm_version,
			"oracle": {"endpoint_identity": sanitize_endpoint(ORACLE_ENDPOINT), "primary_model": ORACLE_MODEL, "secondary_model": ORACLE_MODEL, "implementation_model": IMPLEMENTATION_MODEL, "credential_source": args.credential_source, "credential_present": True, "credential_persisted": False},
			"timeouts": {"provider_seconds": args.provider_timeout_seconds, "stdio_seconds": args.stdio_timeout_seconds, "agent_mcp_seconds": args.provider_timeout_seconds + TRANSPORT_GRACE_SECONDS, "application_seconds": args.apply_timeout_seconds, "test_seconds": args.test_timeout_seconds},
			"max_context_bytes": args.max_context_bytes, "probe_sha256": file_sha256(probe_path),
			"harness_sha256": sha256_text("".join(file_sha256(path) for path in (Path(__file__), repository / "Scripts/portable_oracle_mcp_smoke.py", probe_path))),
		}
		artifact = {
			"schema_version": 1,
			"run": {"run_id": run_id, "iteration": args.iteration, "label": args.label, "candidate_id": args.candidate_id, "attributed_change": args.attributed_change, "started_at": started_at},
			"provenance": provenance,
			"p_limit": {"repository": REPOSITORY, **identity, "source_workspace_head": git_output(source, ["rev-parse", "HEAD"]), "selected_paths": SELECTED_PATHS},
			"pristine_verification": {"outcome": asdict(pristine_test), "clean_after_test": pristine_clean, "identity": pristine_identity},
		}
		prior_feedback = normalize_prior_feedback(json.loads(args.prior_artifact.read_text())) if args.prior_artifact else None
		if prior_feedback is not None:
			artifact["prior_feedback"] = prior_feedback
		if args.iteration > 0:
			baseline = json.loads(args.baseline_artifact.read_text())
			baseline_comparable = baseline.get("plan", {}).get("phase", {}).get("status") == "completed"
			artifact["run"]["baseline_comparison"] = "enforced" if baseline_comparable else "skipped_incomplete_plan_transport"
			if baseline_comparable and comparable_provenance(baseline) != comparable_provenance(artifact):
				raise RuntimeError("iteration provenance differs from baseline campaign")

		plan: dict[str, Any] = {"phase": {"status": "skipped"}, "lanes": {}, "selection": {"selected_lane": None}}
		application: dict[str, Any] = {"outcome": {"exit_code": None}, "scope": {"valid": False}}
		verification: dict[str, Any] = {"semantic_probe": {"passed": False, "passed_count": 0}, "npm_test": {"exit_code": None}, "static_contract": {}}
		review: dict[str, Any] = {"phase": {"status": "skipped"}, "primary": {}, "secondary": {}, "agreement": {"verdict_agreement": False, "acceptance_agreement": False}}

		if not invalid_environment:
			plan_instructions = PLAN_INSTRUCTIONS + (prior_feedback_instructions(prior_feedback) if prior_feedback is not None else "")
			plan_phase = run_builder_phase(iteration_workspace, portable_image["image_id"], args.stdio_timeout_seconds, "plan", plan_instructions, SELECTED_PATHS, args.max_context_bytes, secret)
			plan = {"phase": plan_phase, "lanes": {}, "selection": {"selected_lane": None}}
			if plan_phase["status"] == "completed":
				results = plan_phase["tool_result"]["oracle_results"]
				primary = parse_plan_lane("primary", results["primary"]["response"])
				secondary = parse_plan_lane("secondary", results["secondary"]["response"])
				selection = select_plan(primary, secondary)
				plan.update(lanes={"primary": primary, "secondary": secondary}, selection=selection, agreement={"verdict_agreement": primary.get("contract", {}).get("verdict") == secondary.get("contract", {}).get("verdict") if primary.get("contract") and secondary.get("contract") else False})
				if selection["selected_lane"]:
					metadata = iteration_workspace / ".repoprompt-benchmark"
					metadata.mkdir()
					selected = plan["lanes"][selection["selected_lane"]]
					(metadata / "task.md").write_text(TASK + "\n")
					(metadata / "selected-plan.md").write_text(selected["raw_response"] + "\n")
					(metadata / "apply-instructions.md").write_text(f"Selected {selection['selected_lane']} plan {selection['response_sha256']}\n")
					metadata_hashes = {path.relative_to(iteration_workspace).as_posix(): file_sha256(path) for path in metadata.iterdir()}
					apply_outcome = apply_selected_plan(iteration_workspace, portable_image["image_id"], config_file, args.apply_timeout_seconds, secret)
					scope = scope_result(iteration_workspace, metadata_hashes)
					application = {"outcome": asdict(apply_outcome), "scope": scope}
					static = static_contract(iteration_workspace, scope["changed_files"])
					npm_ci = node_command(node_image["image_id"], iteration_workspace, package_install_command(iteration_workspace), args.test_timeout_seconds, secret)
					probe_command = node_command(node_image["image_id"], iteration_workspace, "node --expose-gc /benchmark/p_limit_abortsignal_probe.mjs /workspace/index.js", args.test_timeout_seconds, secret, True, [f"type=bind,src={probe_path},dst=/benchmark/p_limit_abortsignal_probe.mjs,readonly"])
					probe = parse_probe(probe_command)
					npm_test = node_command(node_image["image_id"], iteration_workspace, "npm test", args.test_timeout_seconds, secret, True)
					verification = {"npm_ci": asdict(npm_ci), "semantic_probe": probe, "npm_test": asdict(npm_test), "static_contract": static}
					evidence = {
						"task": TASK, "base_commit": PINNED_COMMIT, "base_tree": identity["tree"], "selected_plan": selection,
						"changed_files": scope["changed_files"], "diff": scope["diff"][:120_000], "scope_valid": scope["valid"],
						"pristine_npm": command_evidence(pristine_test), "post_change_npm": command_evidence(npm_test),
						"semantic_probe": {key: value for key, value in probe.items() if key != "command"},
						"static_contract": static, "provenance": redact(provenance, secret),
					}
					(metadata / "review-evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
					if (metadata / "review-evidence.json").stat().st_size <= 262_144:
						review_phase = run_builder_phase(iteration_workspace, portable_image["image_id"], args.stdio_timeout_seconds, "review", REVIEW_INSTRUCTIONS, REVIEW_PATHS, args.max_context_bytes, secret)
						review = {"phase": review_phase, "primary": {}, "secondary": {}, "agreement": {"verdict_agreement": False, "acceptance_agreement": False}}
						if review_phase["status"] == "completed":
							results = review_phase["tool_result"]["oracle_results"]
							review["primary"] = parse_review_lane("primary", results["primary"]["response"])
							review["secondary"] = parse_review_lane("secondary", results["secondary"]["response"])
							deterministic = scope["valid"] and probe["passed"] and npm_test.exit_code == 0 and all(static.values())
							review["agreement"] = review_agreement(review["primary"], review["secondary"], deterministic)

		artifact["plan"], artifact["application"], artifact["verification"], artifact["review"] = plan, application, verification, review
		gates = {
			"provenance_isolation": not invalid_environment,
			"plan_transport": plan.get("phase", {}).get("status") == "completed",
			"plan_selection": bool(plan.get("selection", {}).get("selected_lane")),
			"application_scope": application.get("outcome", {}).get("exit_code") == 0 and application.get("scope", {}).get("valid") is True,
			"npm_test": verification.get("npm_test", {}).get("exit_code") == 0,
			"static_contract": bool(verification.get("static_contract")) and all(verification["static_contract"].values()),
			"review_transport": review.get("phase", {}).get("status") == "completed" and review.get("primary", {}).get("parse_status") == "valid" and review.get("secondary", {}).get("parse_status") == "valid",
			"review_verdict_agreement": review.get("agreement", {}).get("verdict_agreement") is True,
			"review_acceptance": review.get("agreement", {}).get("acceptance_agreement") is True,
		}
		points = quality_score(gates, verification.get("semantic_probe", {}).get("passed_count", 0))
		end_to_end_pass = points == 100 and all(gates.values()) and verification.get("semantic_probe", {}).get("passed") is True
		artifact["score"] = {"points": points, "maximum": 100, "gates": gates, "end_to_end_pass": end_to_end_pass}
		artifact["decision"] = decision(args.iteration, end_to_end_pass, invalid_environment)
		artifact["run"].update(completed_at=utc_now(), retained_workspace=str(work_root) if args.keep_workspace else None)
		artifact = redact(artifact, secret)
		after = portable_fingerprint(repository, [output, scoreboard])
		preserved = before["fingerprint_sha256"] == after["fingerprint_sha256"]
		artifact["provenance"]["portable_repository"].update(after_dirty_worktree_fingerprint=after["fingerprint_sha256"], preserved=preserved)
		if not preserved:
			artifact["score"]["gates"]["provenance_isolation"] = False
			artifact["score"]["points"] = quality_score(artifact["score"]["gates"], verification.get("semantic_probe", {}).get("passed_count", 0))
			artifact["score"]["end_to_end_pass"] = False
			artifact["decision"] = {"action": "continue", "reason": "portable worktree changed outside declared artifacts"}
		atomic_write_json(output, artifact)
		append_scoreboard(scoreboard, artifact, output)
		print(output)
		return 0 if artifact["score"]["end_to_end_pass"] else 1
	except BaseException as error:
		print(f"benchmark harness failed: {redact(str(error), secret)}", file=sys.stderr)
		return 2
	finally:
		if config_file:
			remove_generated(config_file)
		if not args.keep_workspace and not args.work_root and work_root.exists():
			remove_generated(work_root)


if __name__ == "__main__":
	raise SystemExit(main())
