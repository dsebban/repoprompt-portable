#!/usr/bin/env python3
"""Exercise the portable RepoPrompt headless image through real stdio MCP."""

from __future__ import annotations

import argparse
import json
import re
import select
from dataclasses import dataclass
import subprocess
import sys
import tempfile
import time
from typing import Any
import xml.etree.ElementTree as ET


PROTOCOL_VERSION = "2025-03-26"
SOFTWARE_VERSION = "0.3.0"
TOOL_SCHEMA_VERSION = "1.1.0"
TOOL_SCHEMA_VERSION_KEY = "x-repoprompt-portable-schema-version"
EXPECTED_TOOL_NAMES = {
	"bind_context",
	"get_file_tree",
	"read_file",
	"manage_selection",
	"file_search",
	"context_builder",
	"oracle_send",
}
FIXTURE_SENTINEL = "PORTABLE_ORACLE_FIXTURE_SENTINEL"


class StdioMCPClient:
	def __init__(self, command: list[str], timeout: float) -> None:
		self.timeout = timeout
		self.next_id = 1
		self.stderr_file = tempfile.TemporaryFile(mode="w+t")
		self.process = subprocess.Popen(
			command,
			stdin=subprocess.PIPE,
			stdout=subprocess.PIPE,
			stderr=self.stderr_file,
			text=True,
			bufsize=1,
		)

	def send(self, payload: dict[str, Any]) -> None:
		assert self.process.stdin is not None
		self.process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
		self.process.stdin.flush()

	def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
		request_id = self.next_id
		self.next_id += 1
		payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
		if params is not None:
			payload["params"] = params
		self.send(payload)
		return self.read_response(request_id)

	def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
		payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
		if params is not None:
			payload["params"] = params
		self.send(payload)

	def read_response(self, request_id: int) -> dict[str, Any]:
		assert self.process.stdout is not None
		deadline = time.monotonic() + self.timeout
		while time.monotonic() < deadline:
			remaining = deadline - time.monotonic()
			ready, _, _ = select.select([self.process.stdout], [], [], max(0.0, remaining))
			if not ready:
				break
			line = self.process.stdout.readline()
			if not line:
				break
			try:
				payload = json.loads(line)
			except json.JSONDecodeError as error:
				raise AssertionError(f"headless stdout contained non-JSON protocol data: {line[:500]!r}") from error
			if payload.get("id") == request_id:
				return payload
		raise AssertionError(f"timed out waiting for JSON-RPC response id {request_id}")

	def close_and_wait(self) -> tuple[int, str, bool]:
		if self.process.stdin is not None and not self.process.stdin.closed:
			self.process.stdin.close()
		timed_out = False
		try:
			return_code = self.process.wait(timeout=self.timeout)
		except subprocess.TimeoutExpired:
			timed_out = True
			self.process.terminate()
			try:
				return_code = self.process.wait(timeout=2.0)
			except subprocess.TimeoutExpired:
				self.process.kill()
				return_code = self.process.wait(timeout=2.0)
		self.stderr_file.seek(0)
		stderr = self.stderr_file.read()[-65_536:]
		self.stderr_file.close()
		return return_code, stderr, timed_out


def rpc_result(response: dict[str, Any], label: str) -> dict[str, Any]:
	if "error" in response:
		raise AssertionError(f"{label} returned JSON-RPC error: {response['error']}")
	result = response.get("result")
	if not isinstance(result, dict):
		raise AssertionError(f"{label} result is not an object: {result!r}")
	return result


@dataclass(frozen=True)
class ToolJSONOutcome:
	value: dict[str, Any]
	is_error: bool
	raw_result: dict[str, Any]


def tool_json_outcome(client: StdioMCPClient, name: str, arguments: dict[str, Any]) -> ToolJSONOutcome:
	result = rpc_result(client.request("tools/call", {"name": name, "arguments": arguments}), name)
	content = result.get("content")
	if not isinstance(content, list):
		raise AssertionError(f"{name} content is not an array")
	texts = [item.get("text") for item in content if isinstance(item, dict) and item.get("type") == "text"]
	if not texts or any(not isinstance(text, str) for text in texts):
		raise AssertionError(f"{name} did not return text content")
	try:
		value = json.loads("\n".join(texts))
	except json.JSONDecodeError as error:
		raise AssertionError(f"{name} text content is not JSON") from error
	if not isinstance(value, dict):
		raise AssertionError(f"{name} JSON result is not an object")
	return ToolJSONOutcome(value=value, is_error=result.get("isError") is True, raw_result=result)


def tool_json(client: StdioMCPClient, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
	outcome = tool_json_outcome(client, name, arguments)
	if outcome.is_error:
		raise AssertionError(f"{name} returned an MCP tool error: {outcome.raw_result}")
	return outcome.value


def nested_keys(value: Any) -> set[str]:
	if isinstance(value, dict):
		return {str(key).lower() for key in value} | set().union(*(nested_keys(item) for item in value.values()))
	if isinstance(value, list):
		return set().union(*(nested_keys(item) for item in value))
	return set()


def assert_pro_edit_artifact(value: Any, lane: str) -> None:
	assert isinstance(value, str), value
	match = re.fullmatch(
		r'\s*<chatName="([^"]+)"/>\s*<Plan>(.*?)</Plan>\s*(.*)',
		value,
		re.DOTALL,
	)
	assert match is not None, value
	chat_name, plan, file_blocks = match.groups()
	assert chat_name and lane in chat_name.lower(), chat_name
	assert plan.strip() and lane in plan.lower(), plan
	root = ET.fromstring(f"<root>{file_blocks}</root>")
	files = list(root)
	assert not (root.text or "").strip(), value
	for file in files:
		assert not (file.tail or "").strip(), value
	assert len(files) == 1 and files[0].tag == "file", value
	file = files[0]
	assert file.attrib == {"path": "fixture.txt", "action": "delegate edit"}, file.attrib
	changes = list(file)
	assert len(changes) == 1 and changes[0].tag == "change", value
	change = changes[0]
	assert [child.tag for child in change] == ["description", "content", "complexity"], value
	description, content, complexity = change
	assert description.attrib == content.attrib == complexity.attrib == {}, value
	assert description.text and description.text.strip(), value
	assert content.text and content.text.strip(), value
	assert complexity.text is not None and 1 <= int(complexity.text) <= 10, value
	for element in root.iter():
		assert element.tag.lower() not in {"execute", "execution", "apply", "applied", "tool_call", "tool_calls"}, value
		assert not ({key.lower() for key in element.attrib} & {"execute", "execution", "apply", "applied"}), value


def assert_pro_edit_pair(value: dict[str, Any]) -> None:
	assert value.get("ok") is True, value
	assert value.get("status") == "response_generated", value
	assert value.get("response_type") == "pro_edit", value
	assert value.get("pair_status") == "completed", value
	assert value.get("oracle_decision_policy") == "caller_decides", value
	assert value.get("model_raw_id") == "gpt-5.6-sol", value
	results = value.get("oracle_results")
	assert isinstance(results, dict), value
	primary = results.get("primary")
	secondary = results.get("secondary")
	assert isinstance(primary, dict) and isinstance(secondary, dict), results
	assert primary.get("oracle_lane") == "primary" and primary.get("status") == "completed", primary
	assert secondary.get("oracle_lane") == "secondary" and secondary.get("status") == "completed", secondary
	assert primary.get("model_raw_id") == "gpt-5.6-sol", primary
	assert secondary.get("model_raw_id") == "openrouter/team:gpt-5.6-sol[variant=secondary]", secondary
	primary_response = primary.get("response")
	secondary_response = secondary.get("response")
	assert_pro_edit_artifact(primary_response, "primary")
	assert_pro_edit_artifact(secondary_response, "secondary")
	assert primary_response != secondary_response, results
	assert value.get("response") == primary_response, value
	assert value.get("response") != secondary_response, value
	forbidden = {
		"execute", "execution", "executed", "apply", "applied", "apply_edits",
		"file_actions", "tool_call", "tool_calls", "chat_id", "new_chat",
		"oracle_export_path", "winner", "synthesis",
	}
	assert nested_keys(value).isdisjoint(forbidden), value


def assert_provider_metadata(value: Any, lane: str, model: str) -> None:
	assert isinstance(value, dict), value
	assert value.get("http_status") == 200, value
	assert isinstance(value.get("latency_ms"), int) and value["latency_ms"] >= 0, value
	assert value.get("id") == f"chatcmpl-fixture-{lane}", value
	assert value.get("request_id") == f"chatcmpl-fixture-{lane}", value
	assert value.get("model") == model, value
	assert value.get("finish_reason") == "stop", value
	assert value.get("conversation_id") == f"conversation-{lane}", value
	assert value.get("baseline_assistant_message_id") == f"assistant-baseline-{lane}", value
	assert value.get("usage") == {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}, value
	assert value.get("recovery") == {"attempted": True, "recovered": True, "source": "fixture"}, value


def assert_surf_error(value: Any, lane: str) -> None:
	assert isinstance(value, dict), value
	assert value.get("code") == "http_error", value
	assert value.get("message") == "token [REDACTED] rejected", value
	assert value.get("http_status") == 429, value
	assert isinstance(value.get("latency_ms"), int) and value["latency_ms"] >= 0, value
	assert value.get("request_id") == f"chatcmpl-error-{lane}", value
	assert value.get("retryable") is True, value
	assert value.get("retry_after_seconds") == 30, value
	assert value.get("provider_error") == {
		"message": "token [REDACTED] rejected",
		"type": "rate_limit_error",
		"param": "reasoning_effort",
		"code": "rate_limited",
		"failure_reason": "active_recovery",
	}, value
	assert value.get("recovery") == {"attempted": True, "recovered": False, "source": "fixture"}, value
	raw_body = value.get("raw_error_body")
	assert isinstance(raw_body, str), value
	assert "portable-oracle-smoke-token" not in raw_body, raw_body
	assert "\\u0070ortable-oracle-smoke-token" not in raw_body, raw_body
	assert json.loads(raw_body)["error"]["message"] == "token [REDACTED] rejected", raw_body
	assert value.get("raw_error_body_truncated") is None, value


def run_smoke(client: StdioMCPClient) -> None:
	initialized = rpc_result(client.request("initialize", {
		"protocolVersion": PROTOCOL_VERSION,
		"capabilities": {},
		"clientInfo": {"name": "portable-oracle-docker-smoke", "version": "1"},
	}), "initialize")
	assert initialized.get("protocolVersion") == PROTOCOL_VERSION, initialized
	server_info = initialized.get("serverInfo")
	assert isinstance(server_info, dict), initialized
	assert server_info.get("version") == SOFTWARE_VERSION, server_info
	instructions = initialized.get("instructions")
	assert isinstance(instructions, str), initialized
	assert "manage_selection is the only selection mutation interface" in instructions, instructions
	assert "context_builder renders only the current explicit" in instructions, instructions
	assert "provider-backed plan/review/pro_edit" in instructions, instructions
	assert "pro_edit produces instructions only and never writes or executes" in instructions, instructions
	assert (
		"oracle_send remains limited to chat/question/plan/review, always snapshots and attaches the current explicit selection"
		in instructions
	), instructions
	assert f"Portable tool schema version: {TOOL_SCHEMA_VERSION}." in instructions, instructions
	client.notify("notifications/initialized")

	listed = rpc_result(client.request("tools/list"), "tools/list")
	tools = listed.get("tools")
	assert isinstance(tools, list), listed
	assert len(tools) == len(EXPECTED_TOOL_NAMES), tools
	tools_by_name = {
		tool.get("name"): tool
		for tool in tools
		if isinstance(tool, dict) and isinstance(tool.get("name"), str)
	}
	assert len(tools_by_name) == len(tools), tools
	assert set(tools_by_name) == EXPECTED_TOOL_NAMES, set(tools_by_name)
	for name, tool in tools_by_name.items():
		schema = tool.get("inputSchema")
		assert isinstance(schema, dict), {name: tool}
		assert schema.get(TOOL_SCHEMA_VERSION_KEY) == TOOL_SCHEMA_VERSION, {name: schema}
	builder_description = tools_by_name["context_builder"].get("description", "")
	assert "current explicit in-memory" in builder_description, builder_description
	assert "never discovers or changes selection" in builder_description, builder_description
	oracle_description = tools_by_name["oracle_send"].get("description", "")
	assert "Always snapshot and attach the current explicit selection" in oracle_description, oracle_description
	assert "no context-free mode" in oracle_description, oracle_description
	builder_properties = tools_by_name["context_builder"]["inputSchema"].get("properties", {})
	oracle_properties = tools_by_name["oracle_send"]["inputSchema"].get("properties", {})
	assert set(builder_properties) == {"instructions", "response_type", "review_diff", "max_context_bytes"}, builder_properties
	assert builder_properties["response_type"].get("enum") == ["clarify", "plan", "review", "pro_edit"], builder_properties
	assert "pro_edit returns instructions only" in builder_properties["instructions"].get("description", ""), builder_properties
	assert set(oracle_properties) == {"message", "mode", "review_diff", "clarify_handoff", "max_context_bytes"}, oracle_properties
	assert oracle_properties["mode"].get("enum") == ["chat", "question", "plan", "review"], oracle_properties

	selection = tool_json(client, "manage_selection", {
		"op": "set",
		"mode": "full",
		"paths": ["fixture.txt"],
	})
	selected = selection.get("selection")
	assert isinstance(selected, dict), selection
	assert selected.get("selected_paths") == ["fixture.txt"], selected
	assert selected.get("selected_count") == 1, selected
	source_before = tool_json(client, "read_file", {"path": "fixture.txt"})
	assert FIXTURE_SENTINEL in source_before.get("content", ""), source_before

	built = tool_json(client, "context_builder", {
		"instructions": "Assemble the selected fixture source.",
		"response_type": "clarify",
	})
	assert built.get("ok") is True, built
	assert built.get("status") == "context_built", built
	assert built.get("response_type") == "clarify", built
	workspace = built.get("workspace_context")
	assert isinstance(workspace, dict), built
	assert FIXTURE_SENTINEL in str(workspace.get("content", "")), workspace
	oracle_fields = {
		"response", "error", "pair_status", "oracle_pair_id", "oracle_decision_policy",
		"model_raw_id", "oracle_results", "chat_id", "oracle_export_path", "winner", "synthesis",
	}
	assert nested_keys(built).isdisjoint(oracle_fields), built

	plan = tool_json(client, "context_builder", {
		"instructions": "Plan around the selected fixture sentinel.",
		"response_type": "plan",
	})
	assert plan.get("ok") is True, plan
	assert plan.get("status") == "response_generated", plan
	assert plan.get("response_type") == "plan", plan
	assert plan.get("prompt") == "Plan around the selected fixture sentinel.", plan
	assert plan.get("pair_status") == "completed", plan
	assert plan.get("model_raw_id") == "gpt-5.6-sol", plan
	plan_results = plan.get("oracle_results")
	assert isinstance(plan_results, dict), plan
	plan_primary = plan_results.get("primary")
	plan_secondary = plan_results.get("secondary")
	assert isinstance(plan_primary, dict) and isinstance(plan_secondary, dict), plan_results
	assert plan_primary.get("oracle_lane") == "primary" and plan_primary.get("status") == "completed", plan_primary
	assert plan_secondary.get("oracle_lane") == "secondary" and plan_secondary.get("status") == "completed", plan_secondary
	assert plan_primary.get("model_raw_id") == "gpt-5.6-sol", plan_primary
	assert plan_secondary.get("model_raw_id") == "openrouter/team:gpt-5.6-sol[variant=secondary]", plan_secondary
	assert_provider_metadata(plan.get("provider_metadata"), "primary", "gpt-5.6-sol")
	assert_provider_metadata(plan_primary.get("provider_metadata"), "primary", "gpt-5.6-sol")
	assert_provider_metadata(
		plan_secondary.get("provider_metadata"),
		"secondary",
		"openrouter/team:gpt-5.6-sol[variant=secondary]",
	)
	plan_primary_response = plan_primary.get("response")
	plan_secondary_response = plan_secondary.get("response")
	assert isinstance(plan_primary_response, str) and "lane=primary" in plan_primary_response, plan_primary
	assert isinstance(plan_secondary_response, str) and "lane=secondary" in plan_secondary_response, plan_secondary
	assert "sentinel=true" in plan_primary_response and "sentinel=true" in plan_secondary_response
	assert plan.get("response") == plan_primary_response, plan
	assert plan.get("response") != plan_secondary_response, plan
	forbidden = {"chat_id", "new_chat", "oracle_export_path", "winner", "synthesis"}
	assert nested_keys(plan).isdisjoint(forbidden), plan

	pro_edit_prompt = "Produce read-only Pro Edit instructions for the selected fixture sentinel."
	pro_edit = tool_json(client, "context_builder", {
		"instructions": pro_edit_prompt,
		"response_type": "pro_edit",
	})
	assert pro_edit.get("prompt") == pro_edit_prompt, pro_edit
	assert_pro_edit_pair(pro_edit)
	assert_provider_metadata(pro_edit.get("provider_metadata"), "primary", "gpt-5.6-sol")
	pro_edit_results = pro_edit["oracle_results"]
	assert_provider_metadata(pro_edit_results["primary"].get("provider_metadata"), "primary", "gpt-5.6-sol")
	assert_provider_metadata(
		pro_edit_results["secondary"].get("provider_metadata"),
		"secondary",
		"openrouter/team:gpt-5.6-sol[variant=secondary]",
	)
	pro_edit_workspace = pro_edit.get("workspace_context")
	assert isinstance(pro_edit_workspace, dict), pro_edit
	assert FIXTURE_SENTINEL in str(pro_edit_workspace.get("content", "")), pro_edit_workspace

	invalid_oracle_mode = tool_json_outcome(client, "oracle_send", {
		"message": "Pro Edit must remain unavailable here.",
		"mode": "pro_edit",
	})
	assert invalid_oracle_mode.is_error is True, invalid_oracle_mode.raw_result
	assert invalid_oracle_mode.value.get("code") == "invalid_params", invalid_oracle_mode.value

	oracle = tool_json(client, "oracle_send", {
		"message": "Review the selected fixture sentinel.",
		"mode": "review",
		"review_diff": "diff --git a/fixture.txt b/fixture.txt\n+PORTABLE_REVIEW_DIFF_SENTINEL",
		"clarify_handoff": json.dumps(built, sort_keys=True, separators=(",", ":")),
	})
	assert oracle.get("ok") is True, oracle
	assert oracle.get("pair_status") == "completed", oracle
	assert oracle.get("model_raw_id") == "gpt-5.6-sol", oracle
	results = oracle.get("oracle_results")
	assert isinstance(results, dict), oracle
	primary = results.get("primary")
	secondary = results.get("secondary")
	assert isinstance(primary, dict) and isinstance(secondary, dict), results
	assert primary.get("oracle_lane") == "primary" and primary.get("status") == "completed", primary
	assert secondary.get("oracle_lane") == "secondary" and secondary.get("status") == "completed", secondary
	assert_provider_metadata(oracle.get("provider_metadata"), "primary", "gpt-5.6-sol")
	assert_provider_metadata(primary.get("provider_metadata"), "primary", "gpt-5.6-sol")
	assert_provider_metadata(
		secondary.get("provider_metadata"),
		"secondary",
		"openrouter/team:gpt-5.6-sol[variant=secondary]",
	)
	primary_response = primary.get("response")
	secondary_response = secondary.get("response")
	assert isinstance(primary_response, str) and "lane=primary" in primary_response, primary
	assert isinstance(secondary_response, str) and "lane=secondary" in secondary_response, secondary
	assert primary_response != secondary_response
	assert "sentinel=true" in primary_response and "sentinel=true" in secondary_response
	assert oracle.get("response") == primary_response, oracle
	assert oracle.get("response") != secondary_response, oracle
	assert {"response_type", "prompt", "status"}.isdisjoint(oracle), oracle
	forbidden = {"chat_id", "new_chat", "oracle_export_path", "winner", "synthesis", "placeholder"}
	assert nested_keys(oracle).isdisjoint(forbidden), oracle
	assert "placeholder" not in json.dumps(oracle, sort_keys=True).lower(), oracle

	forced_error = tool_json(client, "oracle_send", {
		"message": "PORTABLE_ORACLE_FORCE_ERROR",
		"mode": "chat",
	})
	assert forced_error.get("ok") is False, forced_error
	assert forced_error.get("pair_status") == "failed", forced_error
	assert forced_error.get("response") is None, forced_error
	assert_surf_error(forced_error.get("error"), "primary")
	forced_results = forced_error.get("oracle_results")
	assert isinstance(forced_results, dict), forced_error
	forced_primary = forced_results.get("primary")
	forced_secondary = forced_results.get("secondary")
	assert isinstance(forced_primary, dict) and isinstance(forced_secondary, dict), forced_results
	assert forced_primary.get("oracle_lane") == "primary" and forced_primary.get("status") == "failed", forced_primary
	assert forced_secondary.get("oracle_lane") == "secondary" and forced_secondary.get("status") == "failed", forced_secondary
	assert_surf_error(forced_primary.get("error"), "primary")
	assert_surf_error(forced_secondary.get("error"), "secondary")

	source_after = tool_json(client, "read_file", {"path": "fixture.txt"})
	assert source_after == source_before, {"before": source_before, "after": source_after}
	selection_after = tool_json(client, "manage_selection", {"op": "get"})
	assert selection_after.get("selection") == selected, {"before": selected, "after": selection_after}


def main() -> int:
	if sys.flags.optimize:
		raise RuntimeError("Run this smoke without Python optimization so assertions remain active")
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--timeout-seconds", type=float, default=30.0)
	parser.add_argument("command", nargs=argparse.REMAINDER, help="Command that launches the stdio MCP server")
	args = parser.parse_args()
	command = args.command
	if command and command[0] == "--":
		command = command[1:]
	if not command:
		parser.error("provide the stdio server command after --")
	if args.timeout_seconds <= 0:
		parser.error("--timeout-seconds must be positive")

	client = StdioMCPClient(command, args.timeout_seconds)
	failure: BaseException | None = None
	try:
		run_smoke(client)
	except BaseException as error:  # Preserve assertion details after process cleanup.
		failure = error
	return_code, stderr, timed_out = client.close_and_wait()
	if failure is not None:
		raise AssertionError(f"{failure}\nheadless stderr:\n{stderr}") from failure
	assert not timed_out, f"headless process did not exit after stdin closed\nstderr:\n{stderr}"
	assert return_code == 0, f"headless process exited {return_code}\nstderr:\n{stderr}"
	print("portable Oracle stdio MCP smoke passed")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
