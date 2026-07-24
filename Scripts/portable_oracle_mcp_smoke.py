#!/usr/bin/env python3
"""Exercise the portable RepoPrompt headless image through real stdio MCP."""

from __future__ import annotations

import argparse
import json
import select
from dataclasses import dataclass
import subprocess
import sys
import tempfile
import time
from typing import Any


PROTOCOL_VERSION = "2025-03-26"
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


def run_smoke(client: StdioMCPClient) -> None:
	initialized = rpc_result(client.request("initialize", {
		"protocolVersion": PROTOCOL_VERSION,
		"capabilities": {},
		"clientInfo": {"name": "portable-oracle-docker-smoke", "version": "1"},
	}), "initialize")
	assert initialized.get("protocolVersion") == PROTOCOL_VERSION, initialized
	client.notify("notifications/initialized")

	listed = rpc_result(client.request("tools/list"), "tools/list")
	tools = listed.get("tools")
	assert isinstance(tools, list), listed
	tool_names = {tool.get("name") for tool in tools if isinstance(tool, dict)}
	assert {"manage_selection", "context_builder", "oracle_send"} <= tool_names, tool_names
	assert "workspace_context" not in tool_names, tool_names

	selection = tool_json(client, "manage_selection", {
		"op": "set",
		"mode": "full",
		"paths": ["fixture.txt"],
	})
	selected = selection.get("selection")
	assert isinstance(selected, dict), selection
	assert selected.get("selected_paths") == ["fixture.txt"], selected
	assert selected.get("selected_count") == 1, selected

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
	assert plan.get("model_raw_id") == "portable-primary-model", plan
	plan_results = plan.get("oracle_results")
	assert isinstance(plan_results, dict), plan
	plan_primary = plan_results.get("primary")
	plan_secondary = plan_results.get("secondary")
	assert isinstance(plan_primary, dict) and isinstance(plan_secondary, dict), plan_results
	assert plan_primary.get("oracle_lane") == "primary" and plan_primary.get("status") == "completed", plan_primary
	assert plan_secondary.get("oracle_lane") == "secondary" and plan_secondary.get("status") == "completed", plan_secondary
	plan_primary_response = plan_primary.get("response")
	plan_secondary_response = plan_secondary.get("response")
	assert isinstance(plan_primary_response, str) and "lane=primary" in plan_primary_response, plan_primary
	assert isinstance(plan_secondary_response, str) and "lane=secondary" in plan_secondary_response, plan_secondary
	assert "sentinel=true" in plan_primary_response and "sentinel=true" in plan_secondary_response
	assert plan.get("response") == plan_primary_response, plan
	assert plan.get("response") != plan_secondary_response, plan
	forbidden = {"chat_id", "new_chat", "oracle_export_path", "winner", "synthesis"}
	assert nested_keys(plan).isdisjoint(forbidden), plan

	oracle = tool_json(client, "oracle_send", {
		"message": "Review the selected fixture sentinel.",
		"mode": "review",
	})
	assert oracle.get("ok") is True, oracle
	assert oracle.get("pair_status") == "completed", oracle
	assert oracle.get("model_raw_id") == "portable-primary-model", oracle
	results = oracle.get("oracle_results")
	assert isinstance(results, dict), oracle
	primary = results.get("primary")
	secondary = results.get("secondary")
	assert isinstance(primary, dict) and isinstance(secondary, dict), results
	assert primary.get("oracle_lane") == "primary" and primary.get("status") == "completed", primary
	assert secondary.get("oracle_lane") == "secondary" and secondary.get("status") == "completed", secondary
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
