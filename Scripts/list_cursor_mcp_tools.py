#!/usr/bin/env python3
"""List the MCP tools exposed by a server configured in a Cursor mcp.json.

This launches the configured server exactly the way Cursor's agent does (running its
`command`/`args` with the config's `env` applied), performs the MCP initialize
handshake, and prints the advertised tools. Use it to confirm a Cursor-registered
MCP server (e.g. repoprompt-portable) starts and responds correctly.

Usage:
  python3 Scripts/list_cursor_mcp_tools.py [--config PATH] [--server NAME] [--timeout SECONDS]

Defaults: --config ~/.cursor/mcp.json, --server repoprompt-portable, --timeout 60
Exit code is 0 only if the server initializes and reports at least one tool.
"""
from __future__ import annotations

import argparse
import json
import os
import select
import subprocess
import sys
import time

PROTOCOL_VERSION = "2025-03-26"


def load_server(config_path: str, server_name: str) -> dict:
    with open(os.path.expanduser(config_path), "r", encoding="utf-8") as handle:
        config = json.load(handle)
    # Cursor uses "mcpServers"; the OpenCode variant uses "mcp". Accept both.
    servers = config.get("mcpServers") or config.get("mcp") or {}
    if server_name not in servers:
        raise SystemExit(
            f"server {server_name!r} not found in {config_path}; "
            f"available: {sorted(servers)}"
        )
    return servers[server_name]


def build_command(server: dict) -> list[str]:
    command = server.get("command")
    if command is None:
        raise SystemExit("server config has no 'command'")
    if isinstance(command, list):
        argv = list(command)
    else:
        argv = [command, *server.get("args", [])]
    return argv


class StdioMCPClient:
    def __init__(self, argv: list[str], env: dict[str, str], timeout: float) -> None:
        self.timeout = timeout
        self.next_id = 1
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
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
        return self._read(request_id)

    def notify(self, method: str, params: dict | None = None) -> None:
        payload: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)

    def _read(self, request_id: int) -> dict:
        assert self.proc.stdout is not None
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.proc.stdout], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            line = self.proc.stdout.readline()
            if not line:
                break
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue  # ignore any non-JSON server chatter on stdout
            if payload.get("id") == request_id:
                return payload
        raise SystemExit(f"timed out after {self.timeout}s waiting for response id {request_id}")

    def close(self) -> str:
        if self.proc.stdin is not None and not self.proc.stdin.closed:
            self.proc.stdin.close()
        try:
            self.proc.wait(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        assert self.proc.stderr is not None
        return self.proc.stderr.read()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default="~/.cursor/mcp.json")
    parser.add_argument("--server", default="repoprompt-portable")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()

    server = load_server(args.config, args.server)
    argv = build_command(server)
    env = dict(os.environ)
    env.update({str(k): str(v) for k, v in server.get("env", {}).items()})

    print(f"Launching MCP server {args.server!r}: {' '.join(argv)}")
    client = StdioMCPClient(argv, env, args.timeout)

    stderr = ""
    try:
        init = client.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "list-cursor-mcp-tools", "version": "1"},
            },
        )
        result = init.get("result", {})
        info = result.get("serverInfo", {})
        print(f"Connected: {info.get('name', '?')} v{info.get('version', '?')} "
              f"(protocol {result.get('protocolVersion', '?')})")
        client.notify("notifications/initialized")

        listed = client.request("tools/list").get("result", {})
        tools = listed.get("tools", [])
        if not isinstance(tools, list) or not tools:
            print("No tools reported.", file=sys.stderr)
            return 1
        print(f"\n{len(tools)} tool(s):")
        for tool in sorted(tools, key=lambda t: t.get("name", "")):
            name = tool.get("name", "?")
            desc = (tool.get("description") or "").strip().splitlines()
            summary = desc[0] if desc else ""
            print(f"  - {name}" + (f": {summary}" if summary else ""))
        return 0
    finally:
        stderr = client.close()
        if stderr.strip():
            print("\n[server stderr]", file=sys.stderr)
            print(stderr[-4000:], file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
