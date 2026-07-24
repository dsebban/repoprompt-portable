#!/usr/bin/env bash
# Cursor stdio MCP launcher for repoprompt-portable.
# Prefers a native repoprompt-headless binary; falls back to the Docker image.
set -euo pipefail

ROOT="${RP_PORTABLE_ROOT:-/workspace}"
IMAGE="${RP_PORTABLE_IMAGE:-repoprompt-headless:portable}"
DOCKERFILE="${RP_PORTABLE_DOCKERFILE:-$ROOT/Dockerfile.headless}"

find_native() {
	local candidate
	for candidate in \
		"${RP_PORTABLE_NATIVE_BIN:-}" \
		"/usr/local/bin/repoprompt-headless" \
		"$ROOT/.build/x86_64-unknown-linux-gnu/debug/repoprompt-headless" \
		"$ROOT/.build/aarch64-unknown-linux-gnu/debug/repoprompt-headless" \
		"$ROOT/.build/debug/repoprompt-headless" \
		"$ROOT/.build/release/repoprompt-headless"
	do
		if [[ -n "$candidate" && -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

if [[ "${RP_PORTABLE_FORCE_DOCKER:-}" != "1" ]]; then
	if native="$(find_native)"; then
		exec "$native" --no-persist --root "$ROOT" "$@"
	fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x /usr/local/bin/ensure-docker ]]; then
	/usr/local/bin/ensure-docker || true
elif [[ -x "$SCRIPT_DIR/ensure-docker.sh" ]]; then
	"$SCRIPT_DIR/ensure-docker.sh" || true
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
	printf 'repoprompt-portable-mcp: Docker unavailable and no native binary found under %s\n' "$ROOT" >&2
	exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	if [[ ! -f "$DOCKERFILE" ]]; then
		printf 'repoprompt-portable-mcp: missing image %s and Dockerfile %s\n' "$IMAGE" "$DOCKERFILE" >&2
		exit 1
	fi
	printf 'repoprompt-portable-mcp: building %s from %s\n' "$IMAGE" "$DOCKERFILE" >&2
	docker build -f "$DOCKERFILE" -t "$IMAGE" "$ROOT"
fi

docker_env_args=()
for var in \
	OPENCODE_API_KEY \
	REPOPROMPT_ORACLE_ENDPOINT \
	REPOPROMPT_ORACLE_PRIMARY_MODEL \
	REPOPROMPT_ORACLE_SECONDARY_MODEL \
	REPOPROMPT_ORACLE_API_KEY \
	REPOPROMPT_ORACLE_TIMEOUT_SECONDS
do
	if [[ -n "${!var:-}" ]]; then
		docker_env_args+=(--env "$var")
	fi
done

exec docker run --rm -i \
	--mount "type=bind,src=${ROOT},dst=/workspace,readonly" \
	"${docker_env_args[@]}" \
	"$IMAGE" \
	--no-persist --root /workspace \
	"$@"
