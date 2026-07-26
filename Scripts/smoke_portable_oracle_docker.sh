#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
IMAGE="${RP_PORTABLE_IMAGE:-repoprompt-headless:portable-smoke}"
PLATFORM="${RP_PORTABLE_PLATFORM:-}"
PYTHON_IMAGE="${RP_PORTABLE_PYTHON_IMAGE:-python:3.12-alpine@sha256:6d43704baacd1bfbe7c295d7f13079d5d8104ed33568873133f8fc69980419df}"
SKIP_BUILD="${RP_PORTABLE_SKIP_BUILD:-0}"
SMOKE_TIMEOUT="${RP_PORTABLE_SMOKE_TIMEOUT_SECONDS:-30}"
TOKEN="portable-oracle-smoke-token"
NETWORK="rp-portable-oracle-${RANDOM}-$$"
FIXTURE_CONTAINER="rp-portable-oracle-fixture-${RANDOM}-$$"
FIXTURE_DIR=""
SMOKE_ARTIFACT_DIR=""
EXPORT_DIR=""

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
	if [[ -n "$SMOKE_ARTIFACT_DIR" && -d "$SMOKE_ARTIFACT_DIR" ]]; then
		python3 - "$SMOKE_ARTIFACT_DIR" <<'PY'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
	fi
	if [[ -n "$EXPORT_DIR" && -d "$EXPORT_DIR" ]]; then
		python3 - "$EXPORT_DIR" <<'PY'
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
hardened_run() {
	docker run --rm "${PLATFORM_ARGS[@]}" "${HARDENED_ARGS[@]}" "$@"
}

if grep -Eiq '"apiKey"[[:space:]]*:|sk-[[:alnum:]]{20,}' "$REPO_ROOT/opencode.docker.json"; then
	echo "opencode.docker.json must not contain embedded credentials" >&2
	exit 1
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
	docker build -f "$REPO_ROOT/Dockerfile.headless" -t "$IMAGE" "$REPO_ROOT"
fi

docker image inspect "$IMAGE" >/dev/null
hardened_run --network none --entrypoint /bin/sh "$IMAGE" -c '
	set -eu
	test "$(id -u)" = 10001
	test "$(id -g)" = 10001
	test -x /usr/local/bin/repoprompt-headless
	test -x /usr/local/bin/repoprompt-portable-cli
	/usr/local/bin/repoprompt-portable-cli --help >/dev/null
	test -r /etc/opencode/opencode.json
	! grep -Eiq "\"apiKey\"[[:space:]]*:|sk-[[:alnum:]]{20,}" /etc/opencode/opencode.json
'
hardened_run --network none --env HOME=/tmp --entrypoint opencode "$IMAGE" --version
hardened_run --network none --env HOME=/tmp --entrypoint opencode "$IMAGE" mcp list --pure | grep -q 'repoprompt-portable.*connected'
docker network create "$NETWORK" >/dev/null

docker run -d \
	"${HARDENED_ARGS[@]}" \
	--user 65534:65534 \
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
SMOKE_ARTIFACT_DIR="$(mktemp -d "$REPO_ROOT/.build/portable-oracle-artifacts.XXXXXX")"
workspace_hash() {
	python3 - "$FIXTURE_DIR" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
	relative = path.relative_to(root).as_posix()
	if path.is_dir():
		digest.update(f"directory\0{relative}\0".encode())
	elif path.is_file():
		digest.update(f"file\0{relative}\0".encode())
		digest.update(path.read_bytes())
	else:
		raise AssertionError(f"unexpected workspace entry: {relative}")
print(digest.hexdigest())
PY
}
ORIGINAL_WORKSPACE_HASH="$(workspace_hash)"
assert_workspace_unchanged() {
	local actual
	actual="$(workspace_hash)"
	[[ "$actual" == "$ORIGINAL_WORKSPACE_HASH" ]] || {
		echo "portable workspace changed: expected $ORIGINAL_WORKSPACE_HASH, got $actual" >&2
		exit 1
	}
}

python3 "$REPO_ROOT/Scripts/portable_oracle_mcp_smoke.py" \
	--timeout-seconds "$SMOKE_TIMEOUT" \
	-- \
	docker run --rm -i \
		"${PLATFORM_ARGS[@]}" \
		"${HARDENED_ARGS[@]}" \
		--network "$NETWORK" \
		--mount "type=bind,src=$FIXTURE_DIR,dst=/workspace,readonly" \
		--env "REPOPROMPT_ORACLE_ENDPOINT=http://portable-oracle-fixture:8080/v1/chat/completions" \
		--env "REPOPROMPT_ORACLE_PRIMARY_MODEL=gpt-5.6-sol" \
		--env "REPOPROMPT_ORACLE_SECONDARY_MODEL=openrouter/team:gpt-5.6-sol[variant=secondary]" \
		--env "REPOPROMPT_ORACLE_REASONING_EFFORT=xhigh" \
		--env "REPOPROMPT_ORACLE_API_KEY=$TOKEN" \
		--env "REPOPROMPT_ORACLE_TIMEOUT_SECONDS=2700" \
		"$IMAGE" \
		--no-persist \
		--root /workspace
assert_workspace_unchanged

CLI_STDOUT="$SMOKE_ARTIFACT_DIR/cli.stdout"
CLI_STDERR="$SMOKE_ARTIFACT_DIR/cli.stderr"
if hardened_run --network "$NETWORK" \
	--entrypoint /usr/local/bin/repoprompt-portable-cli \
	--mount "type=bind,src=$FIXTURE_DIR,dst=/workspace,readonly" \
	--env "REPOPROMPT_ORACLE_ENDPOINT=http://portable-oracle-fixture:8080/v1/chat/completions" \
	--env "REPOPROMPT_ORACLE_PRIMARY_MODEL=gpt-5.6-sol" \
	--env "REPOPROMPT_ORACLE_SECONDARY_MODEL=openrouter/team:gpt-5.6-sol[variant=secondary]" \
	--env "REPOPROMPT_ORACLE_REASONING_EFFORT=xhigh" \
	--env "REPOPROMPT_ORACLE_API_KEY=$TOKEN" \
	--env "REPOPROMPT_ORACLE_TIMEOUT_SECONDS=2700" \
	"$IMAGE" \
	--root /workspace \
	-e 'manage_selection {"op":"set","mode":"full","paths":["fixture.txt"]}' \
	-e 'context_builder {"instructions":"Produce direct CLI Pro Edit instructions for the selected fixture sentinel.","response_type":"pro_edit"}' \
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

python3 - "$CLI_STDOUT" "$REPO_ROOT/Scripts" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, sys.argv[2])
from portable_oracle_mcp_smoke import assert_pro_edit_pair

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert len(lines) == 2 and all(lines), lines
rows = [json.loads(line) for line in lines]
assert rows[0]["selection"]["selected_paths"] == ["fixture.txt"], rows[0]
assert rows[1]["prompt"] == "Produce direct CLI Pro Edit instructions for the selected fixture sentinel.", rows[1]
assert "PORTABLE_ORACLE_FIXTURE_SENTINEL" in rows[1]["workspace_context"]["content"], rows[1]
assert_pro_edit_pair(rows[1])
print("installed portable CLI Pro Edit smoke passed")
PY
assert_workspace_unchanged

EXPORT_DIR="$(mktemp -d "$REPO_ROOT/.build/portable-export-smoke.XXXXXX")"
chmod 0700 "$EXPORT_DIR"
MAPPED_STDOUT="$SMOKE_ARTIFACT_DIR/mapped.stdout"
MAPPED_STDERR="$SMOKE_ARTIFACT_DIR/mapped.stderr"
hardened_run --network none \
	--user "$(id -u):$(id -g)" \
	--env HOME=/tmp \
	--entrypoint /usr/local/bin/repoprompt-portable-cli \
	--mount "type=bind,src=$FIXTURE_DIR,dst=/workspace,readonly" \
	--mount "type=bind,src=$EXPORT_DIR,dst=/output" \
	"$IMAGE" \
	--root /workspace \
	--export-jsonl /output/result.jsonl \
	-e 'manage_selection {"op":"set","mode":"full","paths":["fixture.txt"]}' \
	-e 'context_builder {"instructions":"Assemble the selected fixture.","response_type":"clarify"}' \
	>"$MAPPED_STDOUT" 2>"$MAPPED_STDERR"

test ! -s "$MAPPED_STDERR"
cmp "$MAPPED_STDOUT" "$EXPORT_DIR/result.jsonl"
python3 - "$EXPORT_DIR/result.jsonl" "$(id -u)" "$(id -g)" <<'PY'
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
metadata = path.stat()
assert stat.S_IMODE(metadata.st_mode) == 0o600, oct(stat.S_IMODE(metadata.st_mode))
if sys.platform.startswith("linux"):
	assert metadata.st_uid == int(sys.argv[2]), (metadata.st_uid, sys.argv[2])
	assert metadata.st_gid == int(sys.argv[3]), (metadata.st_gid, sys.argv[3])
PY

before_hash="$(python3 - "$EXPORT_DIR/result.jsonl" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
set +e
hardened_run --network none \
	--user "$(id -u):$(id -g)" \
	--env HOME=/tmp \
	--entrypoint /usr/local/bin/repoprompt-portable-cli \
	--mount "type=bind,src=$FIXTURE_DIR,dst=/workspace,readonly" \
	--mount "type=bind,src=$EXPORT_DIR,dst=/output" \
	"$IMAGE" \
	--root /workspace \
	--export-jsonl /output/result.jsonl \
	context_builder '{"instructions":"Do not overwrite.","response_type":"clarify"}' \
	>/dev/null 2>"$MAPPED_STDERR"
no_overwrite_status=$?
set -e
[[ "$no_overwrite_status" == "73" ]]
after_hash="$(python3 - "$EXPORT_DIR/result.jsonl" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
[[ "$after_hash" == "$before_hash" ]]
echo "mapped-user private JSONL export smoke passed"

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

successful_provider_calls=(mcp_plan mcp_pro_edit mcp_oracle_review cli_pro_edit)
forced_error_provider_calls=(mcp_forced_error)
SUCCESSFUL_PROVIDER_PAIRS="${#successful_provider_calls[@]}"
FORCED_ERROR_PROVIDER_PAIRS="${#forced_error_provider_calls[@]}"
TOTAL_PROVIDER_PAIRS="$((SUCCESSFUL_PROVIDER_PAIRS + FORCED_ERROR_PROVIDER_PAIRS))"
EXPECTED_TOTAL_REQUESTS="$((TOTAL_PROVIDER_PAIRS * 2))"
EXPECTED_FORCED_ERROR_REQUESTS="$((FORCED_ERROR_PROVIDER_PAIRS * 2))"

SUCCESSFUL_PROVIDER_PAIRS="$SUCCESSFUL_PROVIDER_PAIRS" \
TOTAL_PROVIDER_PAIRS="$TOTAL_PROVIDER_PAIRS" \
EXPECTED_TOTAL_REQUESTS="$EXPECTED_TOTAL_REQUESTS" \
EXPECTED_FORCED_ERROR_REQUESTS="$EXPECTED_FORCED_ERROR_REQUESTS" \
COUNTERS_JSON="$COUNTERS_JSON" python3 - <<'PY'
import json
import os

counters = json.loads(os.environ["COUNTERS_JSON"])
successful_pairs = int(os.environ["SUCCESSFUL_PROVIDER_PAIRS"])
total_pairs = int(os.environ["TOTAL_PROVIDER_PAIRS"])
expected = {
	"total_requests": int(os.environ["EXPECTED_TOTAL_REQUESTS"]),
	"primary_requests": total_pairs,
	"secondary_requests": total_pairs,
	"completed_pairs": successful_pairs,
	"forced_error_requests": int(os.environ["EXPECTED_FORCED_ERROR_REQUESTS"]),
	"barrier_timeouts": 0,
	"authorization_failures": 0,
	"invalid_requests": 0,
	"duplicate_lane_requests": 0,
	"prompt_mismatches": 0,
	"unique_prompt_hashes": successful_pairs,
	"active_pairs": 0,
}
assert counters == expected, {"expected": expected, "actual": counters}
print("portable Oracle fixture counters:", json.dumps(counters, sort_keys=True))
PY

echo "portable Oracle Docker smoke passed"
