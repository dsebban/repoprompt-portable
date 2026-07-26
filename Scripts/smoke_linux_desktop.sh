#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
desktop="$repo_root/LinuxDesktop"
product="repoprompt-linux-desktop"
export SCUI_DEFAULT_BACKEND=GtkBackend
temporary="$(mktemp -d)"
workspace="$temporary/workspace"
missing_workspace="$temporary/missing-workspace"
stdout_log="$temporary/stdout.log"
stderr_log="$temporary/stderr.log"
invalid_stdout_log="$temporary/invalid-stdout.log"
invalid_stderr_log="$temporary/invalid-stderr.log"

cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

for command in swift xvfb-run xauth xwininfo; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

mkdir -p "$workspace"
printf 'RepoPrompt Portable GTK smoke\n' >"$workspace/sentinel.txt"

swift build \
  --package-path "$desktop" \
  --product "$product" \
  --disable-automatic-resolution
bin_path="$(swift build --package-path "$desktop" --show-bin-path)"
binary="$bin_path/$product"

BINARY="$binary" \
WORKSPACE="$workspace" \
MISSING_WORKSPACE="$missing_workspace" \
STDOUT_LOG="$stdout_log" \
STDERR_LOG="$stderr_log" \
INVALID_STDOUT_LOG="$invalid_stdout_log" \
INVALID_STDERR_LOG="$invalid_stderr_log" \
xvfb-run -a --server-args='-screen 0 1280x800x24' bash -eu <<'INNER'
app_pid=""

stop_app() {
  [[ -n "$app_pid" ]] || return 0
  kill "$app_pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$app_pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=""
}
trap stop_app EXIT

start_app() {
  local root="$1" stdout="$2" stderr="$3"
  env \
    -u OPENCODE_API_KEY \
    -u REPOPROMPT_ORACLE_ENDPOINT \
    -u REPOPROMPT_ORACLE_PRIMARY_MODEL \
    -u REPOPROMPT_ORACLE_SECONDARY_MODEL \
    -u REPOPROMPT_ORACLE_API_KEY \
    -u REPOPROMPT_ORACLE_TIMEOUT_SECONDS \
    -u REPOPROMPT_ORACLE_REASONING_EFFORT \
    SCUI_DEFAULT_BACKEND=GtkBackend \
    GDK_BACKEND=x11 \
    "$BINARY" --root "$root" >"$stdout" 2>"$stderr" &
  app_pid=$!
}

assert_no_criticals() {
  local log="$1"
  if [[ -s "$log" ]] && grep -Eiq '(Gtk|GLib|Gdk|GObject|Pango)[A-Za-z0-9-]*-(CRITICAL|ERROR)|cannot open display|failed to open display' "$log"; then
    echo "desktop emitted a GTK/GLib/display critical" >&2
    cat "$log" >&2
    exit 1
  fi
}

start_app "$WORKSPACE" "$STDOUT_LOG" "$STDERR_LOG"
ready=0
for _ in $(seq 1 200); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "desktop exited before bootstrap readiness" >&2
    cat "$STDERR_LOG" >&2
    exit 1
  fi
  assert_no_criticals "$STDERR_LOG"
  if grep -Fq 'RepoPrompt Portable ready: 1 files' "$STDOUT_LOG" \
    && xwininfo -root -tree 2>/dev/null | grep -Fq 'RepoPrompt Portable'; then
    ready=1
    break
  fi
  sleep 0.1
done
[[ "$ready" -eq 1 ]] || {
  echo "desktop did not reach post-bootstrap sentinel readiness" >&2
  cat "$STDOUT_LOG" >&2
  cat "$STDERR_LOG" >&2
  exit 1
}
sleep 0.2
assert_no_criticals "$STDERR_LOG"
stop_app
assert_no_criticals "$STDERR_LOG"

start_app "$MISSING_WORKSPACE" "$INVALID_STDOUT_LOG" "$INVALID_STDERR_LOG"
invalid_observed=0
for _ in $(seq 1 100); do
  assert_no_criticals "$INVALID_STDERR_LOG"
  if grep -Fq 'RepoPrompt Portable startup failed:' "$INVALID_STDERR_LOG" \
    && grep -Fq "$MISSING_WORKSPACE" "$INVALID_STDERR_LOG"; then
    invalid_observed=1
    break
  fi
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 0.1
done
[[ "$invalid_observed" -eq 1 ]] || {
  echo "invalid root did not surface the expected startup error" >&2
  cat "$INVALID_STDOUT_LOG" >&2
  cat "$INVALID_STDERR_LOG" >&2
  exit 1
}
sleep 0.2
failure_count="$(grep -cF 'RepoPrompt Portable startup failed:' "$INVALID_STDERR_LOG" || true)"
[[ "$failure_count" -eq 1 ]] || {
  echo "invalid root bootstrap ran $failure_count times, expected once" >&2
  cat "$INVALID_STDERR_LOG" >&2
  exit 1
}
! grep -Fq 'RepoPrompt Portable ready:' "$INVALID_STDOUT_LOG" || {
  echo "invalid root incorrectly reported readiness" >&2
  exit 1
}
stop_app
assert_no_criticals "$INVALID_STDERR_LOG"
INNER

echo "Linux desktop Xvfb smoke passed: sentinel ready, runtime clean, invalid root rejected."
