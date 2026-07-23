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
