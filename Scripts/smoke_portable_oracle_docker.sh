#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IMAGE="${RP_PORTABLE_IMAGE:-repoprompt-headless:portable-smoke}"
PYTHON_IMAGE="${RP_PORTABLE_PYTHON_IMAGE:-python:3.12-alpine}"
SKIP_BUILD="${RP_PORTABLE_SKIP_BUILD:-0}"
SMOKE_TIMEOUT="${RP_PORTABLE_SMOKE_TIMEOUT_SECONDS:-30}"
TOKEN="portable-oracle-smoke-token"
NETWORK="rp-portable-oracle-${RANDOM}-$$"
FIXTURE_CONTAINER="rp-portable-oracle-fixture-${RANDOM}-$$"
FIXTURE_DIR=""

cleanup() {
	docker rm -f "$FIXTURE_CONTAINER" >/dev/null 2>&1 || true
	docker network rm "$NETWORK" >/dev/null 2>&1 || true
	if [[ -n "$FIXTURE_DIR" && -d "$FIXTURE_DIR" ]]; then
		python3 - "$FIXTURE_DIR" <<'PY'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
	fi
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 3.10+ is required" >&2; exit 1; }
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
	|| { echo "python3 3.10+ is required" >&2; exit 1; }
python3 -c 'import sys; raise SystemExit(0 if sys.flags.optimize == 0 else 1)' \
	|| { echo "PYTHONOPTIMIZE must be disabled for smoke assertions" >&2; exit 1; }
docker info >/dev/null

if [[ "$SKIP_BUILD" != "1" ]]; then
	docker build -f "$REPO_ROOT/Dockerfile.headless" -t "$IMAGE" "$REPO_ROOT"
fi

docker image inspect "$IMAGE" >/dev/null
docker run --rm --entrypoint opencode "$IMAGE" --version
docker run --rm --entrypoint opencode "$IMAGE" mcp list --pure | grep -q 'repoprompt-portable.*connected'
docker network create "$NETWORK" >/dev/null

docker run -d \
	--name "$FIXTURE_CONTAINER" \
	--network "$NETWORK" \
	--network-alias portable-oracle-fixture \
	--mount "type=bind,src=$REPO_ROOT/Scripts/portable_oracle_fixture_server.py,dst=/fixture_server.py,readonly" \
	"$PYTHON_IMAGE" \
	python3 /fixture_server.py \
		--host 0.0.0.0 \
		--port 8080 \
		--token "$TOKEN" >/dev/null

fixture_ready=0
for _ in $(seq 1 40); do
	if docker exec "$FIXTURE_CONTAINER" python3 -c \
		'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=1).read()' \
		>/dev/null 2>&1; then
		fixture_ready=1
		break
	fi
	sleep 0.25
done
if [[ "$fixture_ready" != "1" ]]; then
	docker logs "$FIXTURE_CONTAINER" >&2 || true
	echo "portable Oracle fixture server did not become healthy" >&2
	exit 1
fi

mkdir -p "$REPO_ROOT/.build"
FIXTURE_DIR="$(mktemp -d "$REPO_ROOT/.build/portable-oracle-smoke.XXXXXX")"
printf '%s\n' \
	'PORTABLE_ORACLE_FIXTURE_SENTINEL' \
	'This file proves selected source reached both independent Oracle lanes.' \
	> "$FIXTURE_DIR/fixture.txt"
chmod 0755 "$FIXTURE_DIR"
chmod 0644 "$FIXTURE_DIR/fixture.txt"

python3 "$REPO_ROOT/Scripts/portable_oracle_mcp_smoke.py" \
	--timeout-seconds "$SMOKE_TIMEOUT" \
	-- \
	docker run --rm -i \
		--network "$NETWORK" \
		--mount "type=bind,src=$FIXTURE_DIR,dst=/workspace,readonly" \
		--env "REPOPROMPT_ORACLE_ENDPOINT=http://portable-oracle-fixture:8080/v1/chat/completions" \
		--env "REPOPROMPT_ORACLE_PRIMARY_MODEL=portable-primary-model" \
		--env "REPOPROMPT_ORACLE_SECONDARY_MODEL=portable-secondary-model" \
		--env "REPOPROMPT_ORACLE_API_KEY=$TOKEN" \
		--env "REPOPROMPT_ORACLE_TIMEOUT_SECONDS=15" \
		"$IMAGE" \
		--no-persist \
		--root /workspace

CLI_STDOUT="$FIXTURE_DIR/cli.stdout"
CLI_STDERR="$FIXTURE_DIR/cli.stderr"
if docker run --rm \
	--entrypoint /usr/local/bin/repoprompt-portable-cli \
	--mount "type=bind,src=$FIXTURE_DIR,dst=/workspace,readonly" \
	"$IMAGE" \
	--root /workspace \
	-e 'manage_selection {"op":"set","mode":"full","paths":["fixture.txt"]}' \
	-e 'context_builder {"instructions":"Assemble the selected fixture.","response_type":"clarify"}' \
	>"$CLI_STDOUT" 2>"$CLI_STDERR"; then
	:
else
	cli_status=$?
	echo "installed portable CLI exited $cli_status" >&2
	python3 - "$CLI_STDERR" <<'PY' >&2
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text())
PY
	exit "$cli_status"
fi

if [[ -s "$CLI_STDERR" ]]; then
	echo "installed portable CLI wrote to stderr:" >&2
	python3 - "$CLI_STDERR" <<'PY' >&2
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text())
PY
	exit 1
fi

python3 - "$CLI_STDOUT" <<'PY'
import json
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert len(lines) == 2 and all(lines), lines
rows = [json.loads(line) for line in lines]
assert rows[0]["selection"]["selected_paths"] == ["fixture.txt"], rows[0]
assert rows[1]["ok"] is True, rows[1]
assert rows[1]["status"] == "context_built", rows[1]
assert rows[1]["response_type"] == "clarify", rows[1]
assert "PORTABLE_ORACLE_FIXTURE_SENTINEL" in rows[1]["workspace_context"]["content"], rows[1]
print("installed portable CLI clarify smoke passed")
PY

COUNTERS_JSON="$(docker exec -i "$FIXTURE_CONTAINER" python3 - "$TOKEN" <<'PY'
import sys
import urllib.request
request = urllib.request.Request(
	"http://127.0.0.1:8080/requests",
	headers={"Authorization": f"Bearer {sys.argv[1]}"},
)
print(urllib.request.urlopen(request, timeout=2).read().decode("utf-8"))
PY
)"

COUNTERS_JSON="$COUNTERS_JSON" python3 - <<'PY'
import json
import os

counters = json.loads(os.environ["COUNTERS_JSON"])
expected = {
	"total_requests": 4,
	"primary_requests": 2,
	"secondary_requests": 2,
	"completed_pairs": 2,
	"barrier_timeouts": 0,
	"authorization_failures": 0,
	"invalid_requests": 0,
	"duplicate_lane_requests": 0,
	"prompt_mismatches": 0,
	"unique_prompt_hashes": 2,
	"active_pairs": 0,
}
assert counters == expected, {"expected": expected, "actual": counters}
print("portable Oracle fixture counters:", json.dumps(counters, sort_keys=True))
PY

echo "portable Oracle Docker smoke passed"
