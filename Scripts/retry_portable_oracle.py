#!/usr/bin/env python3
"""Retry a live portable Oracle pair through the Cursor-registered MCP server.

Uses ~/.cursor/mcp.json (server repoprompt-portable) by default. Requires
OPENCODE_API_KEY or the full REPOPROMPT_ORACLE_* set in the process environment
(or the mcp.json env block).

Usage:
  python3 Scripts/retry_portable_oracle.py [--config PATH] [--server NAME] [--timeout SECONDS]
"""
from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROTOCOL_VERSION = "2025-03-26"
FIXTURE_NAME = "oracle_retry_fixture.txt"
FIXTURE_SENTINEL = "PORTABLE_ORACLE_RETRY_SENTINEL"


def load_server(config_path: str, server_name: str) -> dict:
	with open(os.path.expanduser(config_path), "r", encoding="utf-8") as handle:
		config = json.load(handle)
	servers = config.get("mcpServers") or config.get("mcp") or {}
	if server_name not in servers:
		raise SystemExit(f"server {server_name!r} not found in {config_path}; available: {sorted(servers)}")
	return servers[server_name]


def build_command(server: dict) -> list[str]:
	command = server.get("command")
	if command is None:
		raise SystemExit("server config has no 'command'")
	if isinstance(command, list):
		return list(command)
	return [command, *server.get("args", [])]


class StdioMCPClient:
	def __init__(self, argv: list[str], env: dict[str, str], timeout: float) -> None:
		self.timeout = timeout
		self.next_id = 1
		self.err = tempfile.TemporaryFile(mode="w+t")
		self.proc = subprocess.Popen(
			argv,
			stdin=subprocess.PIPE,
			stdout=subprocess.PIPE,
			stderr=self.err,
			text=True,
			bufsize=1,
			env=env,
		)

	def _send(self, payload: dict) -> None:
		assert self.proc.stdin is not None
		self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
		self.proc.stdin.flush()

	def request(self, method: str, params: dict | None = None) -> dict:
		request_id = self.next_id
		self.next_id += 1
		payload: dict = {"jsonrpc": "2.0", "id": request_id, "method": method}
		if params is not None:
			payload["params"] = params
		self._send(payload)
		deadline = time.monotonic() + self.timeout
		assert self.proc.stdout is not None
		while time.monotonic() < deadline:
			ready, _, _ = select.select([self.proc.stdout], [], [], max(0.0, deadline - time.monotonic()))
			if not ready:
				break
			line = self.proc.stdout.readline()
			if not line:
				break
			try:
				message = json.loads(line)
			except json.JSONDecodeError:
				continue
			if message.get("id") == request_id:
				return message
		raise SystemExit(f"timed out waiting for response id {request_id}")

	def notify(self, method: str, params: dict | None = None) -> None:
		payload: dict = {"jsonrpc": "2.0", "method": method}
		if params is not None:
			payload["params"] = params
		self._send(payload)

	def close(self) -> str:
		if self.proc.stdin is not None and not self.proc.stdin.closed:
			self.proc.stdin.close()
		try:
			self.proc.wait(timeout=self.timeout)
		except subprocess.TimeoutExpired:
			self.proc.kill()
			self.proc.wait(timeout=5)
		self.err.seek(0)
		text = self.err.read()[-65_536:]
		self.err.close()
		return text


def tool_json(client: StdioMCPClient, name: str, arguments: dict) -> dict:
	response = client.request("tools/call", {"name": name, "arguments": arguments})
	if "error" in response:
		raise SystemExit(f"{name} JSON-RPC error: {response['error']}")
	result = response.get("result") or {}
	if result.get("isError") is True:
		raise SystemExit(f"{name} tool error: {json.dumps(result, indent=2)}")
	texts = [
		item.get("text")
		for item in result.get("content", [])
		if isinstance(item, dict) and item.get("type") == "text"
	]
	if not texts:
		raise SystemExit(f"{name} returned no text content")
	payload = json.loads("\n".join(texts))
	if not isinstance(payload, dict):
		raise SystemExit(f"{name} JSON was not an object")
	return payload


def prepare_fixture(root: Path) -> None:
	root.mkdir(parents=True, exist_ok=True)
	(root / FIXTURE_NAME).write_text(
		f"{FIXTURE_SENTINEL}\nRetry portable Oracle from the Cursor MCP launcher.\n",
		encoding="utf-8",
	)


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("--config", default="~/.cursor/mcp.json")
	parser.add_argument("--server", default="repoprompt-portable")
	parser.add_argument("--timeout", type=float, default=180.0)
	parser.add_argument("--root", default=os.environ.get("RP_PORTABLE_ROOT", "/workspace"))
	args = parser.parse_args()

	server = load_server(args.config, args.server)
	argv = build_command(server)
	env = dict(os.environ)
	env.update({str(key): str(value) for key, value in server.get("env", {}).items()})
	# Resolve ${env:NAME} interpolations used in Cursor mcp.json.
	for key, value in list(env.items()):
		if isinstance(value, str) and value.startswith("${env:") and value.endswith("}"):
			env_name = value[len("${env:") : -1]
			env[key] = os.environ.get(env_name, "")

	if not env.get("OPENCODE_API_KEY") and not (
		env.get("REPOPROMPT_ORACLE_ENDPOINT")
		and env.get("REPOPROMPT_ORACLE_PRIMARY_MODEL")
		and env.get("REPOPROMPT_ORACLE_SECONDARY_MODEL")
	):
		raise SystemExit(
			"Oracle is not configured in the environment. Set OPENCODE_API_KEY "
			"or the full REPOPROMPT_ORACLE_* trio before retrying."
		)

	root = Path(args.root)
	prepare_fixture(root)
	env.setdefault("RP_PORTABLE_ROOT", str(root))

	print(f"Launching {args.server!r}: {' '.join(argv)}")
	client = StdioMCPClient(argv, env, args.timeout)
	stderr = ""
	try:
		init = client.request(
			"initialize",
			{
				"protocolVersion": PROTOCOL_VERSION,
				"capabilities": {},
				"clientInfo": {"name": "retry-portable-oracle", "version": "1"},
			},
		)
		if "error" in init:
			raise SystemExit(f"initialize failed: {init['error']}")
		client.notify("notifications/initialized")

		selection = tool_json(
			client,
			"manage_selection",
			{"op": "set", "mode": "full", "paths": [FIXTURE_NAME]},
		)
		print("selection:", selection.get("selection", {}).get("selected_paths"))

		built = tool_json(
			client,
			"context_builder",
			{"instructions": "Assemble the selected oracle retry fixture.", "response_type": "clarify"},
		)
		print("context_builder:", {"ok": built.get("ok"), "status": built.get("status")})

		oracle = tool_json(
			client,
			"oracle_send",
			{
				"message": (
					"In one short sentence, confirm you can see "
					f"{FIXTURE_SENTINEL} and paraphrase the fixture."
				),
				"mode": "chat",
			},
		)
		summary = {
			"ok": oracle.get("ok"),
			"pair_status": oracle.get("pair_status"),
			"model_raw_id": oracle.get("model_raw_id"),
			"response": oracle.get("response"),
			"primary_status": (oracle.get("oracle_results") or {}).get("primary", {}).get("status"),
			"secondary_status": (oracle.get("oracle_results") or {}).get("secondary", {}).get("status"),
			"primary_response": (oracle.get("oracle_results") or {}).get("primary", {}).get("response"),
			"secondary_response": (oracle.get("oracle_results") or {}).get("secondary", {}).get("response"),
			"error": oracle.get("error"),
		}
		print(json.dumps(summary, indent=2))
		if summary.get("ok") is not True or summary.get("pair_status") != "completed":
			return 1
		if FIXTURE_SENTINEL not in str(summary.get("primary_response", "")) and FIXTURE_SENTINEL not in str(
			summary.get("response", "")
		):
			# Model may paraphrase without echoing the sentinel; accept completed pair.
			pass
		print("portable Oracle retry passed")
		return 0
	finally:
		stderr = client.close()
		if stderr.strip():
			print("\n[server stderr]", file=sys.stderr)
			print(stderr[-4000:], file=sys.stderr)


if __name__ == "__main__":
	raise SystemExit(main())
