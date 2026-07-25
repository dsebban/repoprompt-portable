#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IMAGE="${RP_PORTABLE_IMAGE:-repoprompt-headless:portable-host-smoke}"
PLATFORM="${RP_PORTABLE_PLATFORM:-}"
SKIP_BUILD="${RP_PORTABLE_SKIP_BUILD:-0}"
SMOKE_TIMEOUT="${RP_PORTABLE_SMOKE_TIMEOUT_SECONDS:-30}"
TOKEN="portable-host-gateway-smoke-token"
FIXTURE_PID=""
TEMP_DIR=""

cleanup() {
	if [[ -n "$FIXTURE_PID" ]]; then
		kill "$FIXTURE_PID" >/dev/null 2>&1 || true
		wait "$FIXTURE_PID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
		python3 - "$TEMP_DIR" <<'PY'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
	fi
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == "Linux" ]] || { echo "host-gateway smoke is Linux-only" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
docker info >/dev/null

if [[ "$SKIP_BUILD" != "1" ]]; then
	docker build -f "$REPO_ROOT/Dockerfile.headless" -t "$IMAGE" "$REPO_ROOT"
fi

docker image inspect "$IMAGE" >/dev/null
mkdir -p "$REPO_ROOT/.build"
TEMP_DIR="$(mktemp -d "$REPO_ROOT/.build/portable-host-gateway.XXXXXX")"
chmod 0755 "$TEMP_DIR"
printf '%s\n' \
	'PORTABLE_ORACLE_FIXTURE_SENTINEL' \
	'This file proves authenticated host-gateway source reached both Oracle lanes.' \
	> "$TEMP_DIR/fixture.txt"
chmod 0644 "$TEMP_DIR/fixture.txt"

READY_FILE="$TEMP_DIR/ready"
FIXTURE_LOG="$TEMP_DIR/fixture.log"
python3 "$REPO_ROOT/Scripts/portable_oracle_fixture_server.py" \
	--host 0.0.0.0 \
	--port 0 \
	--token "$TOKEN" \
	--ready-file "$READY_FILE" \
	2>"$FIXTURE_LOG" &
FIXTURE_PID=$!

for _ in $(seq 1 80); do
	[[ -s "$READY_FILE" ]] && break
	kill -0 "$FIXTURE_PID" >/dev/null 2>&1 || { cat "$FIXTURE_LOG" >&2; exit 1; }
	sleep 0.1
done
[[ -s "$READY_FILE" ]] || { cat "$FIXTURE_LOG" >&2; echo "host fixture did not become ready" >&2; exit 1; }
PORT="$(cat "$READY_FILE")"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "invalid fixture port: $PORT" >&2; exit 1; }

python3 - "$PORT" <<'PY'
import sys
import urllib.error
import urllib.request

port = int(sys.argv[1])
assert urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2).status == 200
try:
	urllib.request.urlopen(f"http://127.0.0.1:{port}/requests", timeout=2)
except urllib.error.HTTPError as error:
	assert error.code == 401, error.code
else:
	raise AssertionError("fixture request accounting must require bearer authentication")
PY

PLATFORM_ARGS=()
if [[ -n "$PLATFORM" ]]; then
	PLATFORM_ARGS=(--platform "$PLATFORM")
fi
HARDENED_ARGS=(
	--read-only
	--cap-drop ALL
	--security-opt no-new-privileges
	--pids-limit 256
	--tmpfs /tmp:rw,nosuid,nodev,size=64m
)

python3 "$REPO_ROOT/Scripts/portable_oracle_mcp_smoke.py" \
	--timeout-seconds "$SMOKE_TIMEOUT" \
	-- \
	docker run --rm -i \
		"${PLATFORM_ARGS[@]}" \
		"${HARDENED_ARGS[@]}" \
		--add-host host.docker.internal:host-gateway \
		--mount "type=bind,src=$TEMP_DIR,dst=/workspace,readonly" \
		--env "REPOPROMPT_ORACLE_ENDPOINT=http://host.docker.internal:$PORT/v1/chat/completions" \
		--env "REPOPROMPT_ORACLE_PRIMARY_MODEL=gpt-5.6-sol" \
		--env "REPOPROMPT_ORACLE_SECONDARY_MODEL=openrouter/team:gpt-5.6-sol[variant=secondary]" \
		--env "REPOPROMPT_ORACLE_REASONING_EFFORT=xhigh" \
		--env "REPOPROMPT_ORACLE_API_KEY=$TOKEN" \
		--env "REPOPROMPT_ORACLE_TIMEOUT_SECONDS=2700" \
		"$IMAGE" \
		--no-persist \
		--root /workspace

COUNTERS_JSON="$(python3 - "$PORT" "$TOKEN" <<'PY'
import sys
import urllib.request
request = urllib.request.Request(
	f"http://127.0.0.1:{int(sys.argv[1])}/requests",
	headers={"Authorization": f"Bearer {sys.argv[2]}"},
)
print(urllib.request.urlopen(request, timeout=2).read().decode())
PY
)"
COUNTERS_JSON="$COUNTERS_JSON" python3 - <<'PY'
import json
import os

actual = json.loads(os.environ["COUNTERS_JSON"])
expected = {
	"total_requests": 6,
	"primary_requests": 3,
	"secondary_requests": 3,
	"completed_pairs": 2,
	"forced_error_requests": 2,
	"barrier_timeouts": 0,
	"authorization_failures": 1,
	"invalid_requests": 0,
	"duplicate_lane_requests": 0,
	"prompt_mismatches": 0,
	"unique_prompt_hashes": 2,
	"active_pairs": 0,
}
assert actual == expected, {"expected": expected, "actual": actual}
print("authenticated Linux host-gateway fixture counters:", json.dumps(actual, sort_keys=True))
PY

echo "portable Oracle Linux host-gateway smoke passed"
