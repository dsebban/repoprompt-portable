# AGENTS.md

## Cursor Cloud specific instructions

RepoPrompt Portable is a single Swift Package Manager product: `repoprompt-headless`, a
read-only stdio MCP server (plus the `RepoPromptCore` library). There is no web UI or
long-running HTTP server; the app speaks MCP over stdin/stdout. See `README.md` and
`docs/architecture/portable-oracle-mcp.md` for the tool contract and configuration.

### Toolchain
- Swift 6.1 is preinstalled at `/opt/swift`, with `swift`/`swiftc` symlinked into
  `/usr/local/bin`, so `swift build`/`swift test`/`swift package ...` work on the default PATH.
- `Package.swift` declares only `platforms: [.macOS(.v13)]`, but the package builds and tests
  fine on Linux (matches CI, which uses the `swift:6.1-jammy` container).
- `swift package resolve` on Linux rewrites `Package.resolved` with Linux-only transitive deps
  (async-http-client, swift-nio-ssl, swift-crypto, etc.) that the committed macOS-generated
  lockfile omits. This churn is expected — do not commit it (the startup update script reverts
  `Package.resolved` after resolving).

### Build / test / run (standard commands, from `README.md`)
- Build: `swift build --product repoprompt-headless`
- Test: `swift test` (XCTest, ~29 tests, all offline; no DB or network needed)
- The server reads/writes MCP JSON-RPC frames over stdio. It will exit with a usage error if
  attached to a TTY, so drive it from an MCP client that pipes stdin/stdout (e.g. a script like
  `Scripts/portable_oracle_mcp_smoke.py`). Run natively with:
  `swift run repoprompt-headless --no-persist --root /path/to/workspace`.
- Non-Oracle tools (`get_file_tree`, `manage_selection`, `read_file`, `context_builder`,
  `file_search`) work with no external services. `oracle_send` requires either `OPENCODE_API_KEY`
  or the full `REPOPROMPT_ORACLE_*` env set (endpoint + primary/secondary models).

### Docker smoke (full Oracle dual-lane E2E, part of CI)
- `bash Scripts/smoke_portable_oracle_docker.sh` builds the image and runs a self-contained fake
  Oracle provider (no paid API key). It requires a working Docker daemon and `python3` 3.10+.
- Docker is NOT started automatically. Start it first (it must run with the fuse-overlayfs
  storage driver in this VM). If `docker` needs sudo, either run the daemon and `chmod 666
  /var/run/docker.sock`, or prefix docker commands with sudo.
- Useful overrides: `RP_PORTABLE_SKIP_BUILD=1` (reuse an existing image),
  `RP_PORTABLE_IMAGE`, `RP_PORTABLE_PYTHON_IMAGE`, `RP_PORTABLE_SMOKE_TIMEOUT_SECONDS`.
- The smoke script asserts `PYTHONOPTIMIZE` is unset, so do not export `PYTHONOPTIMIZE`.

### Keeping Docker running (no systemd)
- This VM's init is `tini`, so `systemctl`/`service` do not work. Start Docker with the
  idempotent helper `Scripts/ensure-docker.sh` (install to `/usr/local/bin/ensure-docker`):
  it starts `dockerd` detached if needed, waits for readiness, and relaxes
  `/var/run/docker.sock` perms. It is best-effort and always exits 0.
- Install once per VM: `sudo cp Scripts/ensure-docker.sh /usr/local/bin/ensure-docker && sudo chmod +x /usr/local/bin/ensure-docker`,
  then call `ensure-docker` from the update script and/or `~/.bashrc`.
- `dockerd` here must use the `fuse-overlayfs` storage driver (already set in
  `/etc/docker/daemon.json`).

### repoprompt-portable as a Cursor MCP server
- Register in `~/.cursor/mcp.json` as a stdio server whose `command` is
  `/usr/local/bin/repoprompt-portable-mcp` (from `Scripts/repoprompt-portable-mcp.sh`).
  Install: `sudo cp Scripts/repoprompt-portable-mcp.sh /usr/local/bin/repoprompt-portable-mcp && sudo chmod +x /usr/local/bin/repoprompt-portable-mcp`.
- The wrapper prefers a native `repoprompt-headless` binary (`/usr/local/bin` or `.build/...`),
  otherwise calls `ensure-docker`, builds `repoprompt-headless:portable` from
  `Dockerfile.headless` if missing, then `exec`s `docker run --rm -i ... --no-persist --root /workspace`.
  Set `RP_PORTABLE_FORCE_DOCKER=1` to skip the native preference.
- Example `~/.cursor/mcp.json`:
  ```json
  {
    "mcpServers": {
      "repoprompt-portable": {
        "command": "/usr/local/bin/repoprompt-portable-mcp",
        "args": [],
        "env": {
          "OPENCODE_API_KEY": "${env:OPENCODE_API_KEY}",
          "RP_PORTABLE_ROOT": "/workspace"
        }
      }
    }
  }
  ```
- Oracle config for `oracle_send`: set `OPENCODE_API_KEY` (OpenCode Go defaults: both lanes
  `deepseek-v4-flash`), or set all three of `REPOPROMPT_ORACLE_ENDPOINT` +
  `REPOPROMPT_ORACLE_PRIMARY_MODEL` + `REPOPROMPT_ORACLE_SECONDARY_MODEL`. Optional:
  `REPOPROMPT_ORACLE_API_KEY` / `REPOPROMPT_ORACLE_TIMEOUT_SECONDS`. With none set,
  local/selection tools still work and `oracle_send` returns `oracle_not_configured`.
- Verify the Cursor-registered server end to end (initialize + list tools) with:
  `python3 Scripts/list_cursor_mcp_tools.py` (defaults to `~/.cursor/mcp.json`, server
  `repoprompt-portable`). Retry a live dual-lane call with
  `python3 Scripts/retry_portable_oracle.py`.
