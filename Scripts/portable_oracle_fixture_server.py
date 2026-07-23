#!/usr/bin/env python3
"""Deterministic concurrent OpenAI-compatible fixture for portable Oracle smoke tests."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


class FixtureState:
	def __init__(self, token: str, barrier_timeout: float) -> None:
		self.token = token
		self.barrier_timeout = barrier_timeout
		self.condition = threading.Condition()
		self.pairs: dict[str, dict[str, Any]] = {}
		self.prompt_hashes: set[str] = set()
		self.counters = {
			"total_requests": 0,
			"primary_requests": 0,
			"secondary_requests": 0,
			"completed_pairs": 0,
			"barrier_timeouts": 0,
			"authorization_failures": 0,
			"invalid_requests": 0,
			"duplicate_lane_requests": 0,
			"prompt_mismatches": 0,
		}

	def authorize(self, header: str | None) -> bool:
		expected = f"Bearer {self.token}"
		if header is not None and hmac.compare_digest(header, expected):
			return True
		with self.condition:
			self.counters["authorization_failures"] += 1
		return False

	def note_post(self) -> None:
		with self.condition:
			self.counters["total_requests"] += 1

	def note_invalid(self) -> None:
		with self.condition:
			self.counters["invalid_requests"] += 1

	def await_pair(self, lane: str, prompt_hash: str) -> tuple[bool, str | None]:
		with self.condition:
			self.counters[f"{lane}_requests"] += 1
			self.prompt_hashes.add(prompt_hash)

			for other_hash, other in self.pairs.items():
				if (
					other_hash != prompt_hash
					and not other["ready"]
					and not other["failed"]
					and lane not in other["lanes"]
				):
					self.counters["prompt_mismatches"] += 1
					other["failed"] = True
					self.condition.notify_all()
					return False, "Primary and Secondary user prompts differ."

			pair = self.pairs.setdefault(prompt_hash, {
				"lanes": set(),
				"ready": False,
				"failed": False,
				"departures": 0,
			})
			if lane in pair["lanes"]:
				self.counters["duplicate_lane_requests"] += 1
				return False, f"Duplicate {lane} request for one pair."

			pair["lanes"].add(lane)
			if pair["lanes"] == {"primary", "secondary"}:
				pair["ready"] = True
				self.counters["completed_pairs"] += 1
				self.condition.notify_all()
			else:
				deadline = time.monotonic() + self.barrier_timeout
				while not pair["ready"] and not pair["failed"]:
					remaining = deadline - time.monotonic()
					if remaining <= 0:
						pair["failed"] = True
						self.counters["barrier_timeouts"] += 1
						self.condition.notify_all()
						break
					self.condition.wait(remaining)

			succeeded = bool(pair["ready"] and not pair["failed"])
			pair["departures"] += 1
			if pair["departures"] >= len(pair["lanes"]):
				self.pairs.pop(prompt_hash, None)
			if succeeded:
				return True, None
			return False, "The opposite Oracle lane did not reach the synchronized barrier."

	def snapshot(self) -> dict[str, Any]:
		with self.condition:
			return {
				**self.counters,
				"unique_prompt_hashes": len(self.prompt_hashes),
				"active_pairs": len(self.pairs),
			}


class FixtureHTTPServer(ThreadingHTTPServer):
	daemon_threads = True
	allow_reuse_address = True

	def __init__(self, server_address: tuple[str, int], state: FixtureState) -> None:
		super().__init__(server_address, FixtureHandler)
		self.state = state


class FixtureHandler(BaseHTTPRequestHandler):
	server: FixtureHTTPServer
	protocol_version = "HTTP/1.1"

	def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
		if self.path == "/health":
			self.send_json(200, {"ok": True})
			return
		if self.path == "/requests":
			if not self.server.state.authorize(self.headers.get("Authorization")):
				self.send_json(401, {"error": {"message": "Unauthorized"}})
				return
			self.send_json(200, self.server.state.snapshot())
			return
		self.send_json(404, {"error": {"message": "Not found"}})

	def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
		self.server.state.note_post()
		if self.path != "/v1/chat/completions":
			self.server.state.note_invalid()
			self.send_json(404, {"error": {"message": "Not found"}})
			return
		if not self.server.state.authorize(self.headers.get("Authorization")):
			self.send_json(401, {"error": {"message": "Unauthorized"}})
			return

		try:
			length = int(self.headers.get("Content-Length", "0"))
			if length <= 0 or length > 2 * 1024 * 1024:
				raise ValueError("invalid Content-Length")
			body = json.loads(self.rfile.read(length))
			model, system_prompt, user_prompt = self.validate_body(body)
			lane = self.lane_from_system_prompt(system_prompt)
		except (json.JSONDecodeError, TypeError, ValueError) as error:
			self.server.state.note_invalid()
			self.send_json(400, {"error": {"message": f"Invalid request: {error}"}})
			return

		prompt_hash = hashlib.sha256(user_prompt.encode("utf-8")).hexdigest()
		succeeded, error = self.server.state.await_pair(lane, prompt_hash)
		if not succeeded:
			self.send_json(504, {"error": {"message": error}})
			return

		sentinel_present = "PORTABLE_ORACLE_FIXTURE_SENTINEL" in user_prompt
		completion = (
			f"fixture lane={lane} model={model} prompt_sha256={prompt_hash} "
			f"sentinel={str(sentinel_present).lower()}"
		)
		self.send_json(200, {
			"choices": [{"message": {"role": "assistant", "content": completion}}]
		})

	@staticmethod
	def validate_body(body: Any) -> tuple[str, str, str]:
		if not isinstance(body, dict):
			raise TypeError("body must be an object")
		model = body.get("model")
		messages = body.get("messages")
		if not isinstance(model, str) or not model:
			raise TypeError("model must be a non-empty string")
		if body.get("stream") is not False:
			raise ValueError("stream must be false")
		if not isinstance(messages, list) or len(messages) != 2:
			raise TypeError("messages must contain exactly system and user entries")
		system, user = messages
		if not isinstance(system, dict) or system.get("role") != "system" or not isinstance(system.get("content"), str):
			raise TypeError("first message must be system text")
		if not isinstance(user, dict) or user.get("role") != "user" or not isinstance(user.get("content"), str):
			raise TypeError("second message must be user text")
		return model, system["content"], user["content"]

	@staticmethod
	def lane_from_system_prompt(system_prompt: str) -> str:
		primary = "Primary Oracle" in system_prompt
		secondary = "Secondary Oracle" in system_prompt
		if primary == secondary:
			raise ValueError("system prompt must identify exactly one Oracle lane")
		return "primary" if primary else "secondary"

	def send_json(self, status: int, value: Any) -> None:
		data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
		self.send_response(status)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(data)))
		self.end_headers()
		self.wfile.write(data)

	def log_message(self, format: str, *args: Any) -> None:
		return


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--host", default="127.0.0.1")
	parser.add_argument("--port", type=int, default=8080)
	parser.add_argument("--token", required=True)
	parser.add_argument("--barrier-timeout-seconds", type=float, default=10.0)
	args = parser.parse_args()
	if not args.token:
		parser.error("--token must not be empty")
	if args.barrier_timeout_seconds <= 0:
		parser.error("--barrier-timeout-seconds must be positive")

	state = FixtureState(args.token, args.barrier_timeout_seconds)
	server = FixtureHTTPServer((args.host, args.port), state)
	print(f"portable Oracle fixture listening on {args.host}:{server.server_port}", file=sys.stderr, flush=True)
	try:
		server.serve_forever()
	except KeyboardInterrupt:
		pass
	finally:
		server.server_close()
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
