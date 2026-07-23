#!/usr/bin/env bash
# Idempotent Docker bootstrap for Cursor Cloud VMs (tini init, no systemd).
# Always exits 0 — callers treat Docker as best-effort.
set -u

log() {
	printf 'ensure-docker: %s\n' "$*" >&2
}

if ! command -v dockerd >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
	log "dockerd/docker not installed; skipping"
	exit 0
fi

if docker info >/dev/null 2>&1; then
	exit 0
fi

if [[ ! -S /var/run/docker.sock ]]; then
	log "starting dockerd"
	# Prefer fuse-overlayfs when configured; fall back quietly if already set in daemon.json.
	if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
		sudo -n dockerd >/tmp/dockerd.log 2>&1 &
	else
		dockerd >/tmp/dockerd.log 2>&1 &
	fi
fi

deadline=$((SECONDS + 45))
while (( SECONDS < deadline )); do
	if docker info >/dev/null 2>&1; then
		if [[ -S /var/run/docker.sock ]]; then
			if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
				sudo -n chmod 666 /var/run/docker.sock >/dev/null 2>&1 || true
			else
				chmod 666 /var/run/docker.sock >/dev/null 2>&1 || true
			fi
		fi
		exit 0
	fi
	sleep 1
done

log "dockerd did not become ready; see /tmp/dockerd.log"
exit 0
