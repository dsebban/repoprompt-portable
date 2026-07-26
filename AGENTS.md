# AGENTS.md

## Cursor Cloud specific instructions

RepoPrompt Portable is a Swift package with two executable products: `repoprompt-headless`, a read-only stdio MCP server, and `repoprompt-portable-cli`, a direct JSONL runner over the same `RepoPromptHeadless` library/catalog. There is no web UI or long-running product HTTP server. See `README.md` and `docs/architecture/portable-oracle-mcp.md` for the current contract.

Portable software `0.3.0` advertises tool-schema version `1.1.0` on all seven tools. `context_builder` supports local `clarify` plus provider-backed `plan|review|pro_edit`; `oracle_send` remains `chat|question|plan|review` and always attaches the explicit selection. Pro Edit returns two independent opaque instruction artifacts and projects Primary at the top level; portable never parses, validates, delegates, applies, writes, persists, or certifies them. Provider-backed calls fail closed on any omission/truncation. Caller-supplied `review_diff` and `clarify_handoff` are untrusted evidence sent to both concurrent Oracle lanes.

### Toolchain

- Swift 6.1 is preinstalled at `/opt/swift`, with `swift`/`swiftc` on the default PATH.
- `Package.swift` declares only `platforms: [.macOS(.v13)]`, but builds/tests pass on Linux, matching CI's pinned Swift 6.1 Jammy image.
- `swift package resolve` on Linux may rewrite `Package.resolved` with Linux-only transitive dependencies. Do not commit that churn.

### Build, test, and run

- Build both products:
  - `swift build --product repoprompt-headless`
  - `swift build --product repoprompt-portable-cli`
- Run the full offline XCTest suite with `swift test`.
- Run Python verification with:
  - `python3 Scripts/test_verify_portable_release.py`
  - `python3 -m py_compile Scripts/*.py benchmarks/*.py`
- Run release source policy with `python3 Scripts/verify_portable_release.py source --expected-version 0.3.0`. This rejects embedded OpenCode credentials, unpinned Docker bases, missing binaries, and any third-party GitHub Action not pinned to a full commit SHA.
- The server exits with a usage error on a TTY. Drive stdio from an MCP client or `Scripts/portable_oracle_mcp_smoke.py`. Native run:
  `swift run repoprompt-headless --no-persist --root /path/to/workspace`.
- Provider-free tools and `context_builder(..., response_type:"clarify")` need no API key. Provider-backed builder modes and `oracle_send` require either `OPENCODE_API_KEY` defaults or the complete explicit endpoint/Primary/Secondary tuple. Do not pass `OPENCODE_API_KEY` for an explicit Surf-only Oracle.
- Explicit provider options include `REPOPROMPT_ORACLE_API_KEY` bearer auth, `REPOPROMPT_ORACLE_REASONING_EFFORT`, and `REPOPROMPT_ORACLE_TIMEOUT_SECONDS=1...3600`.

### Docker verification

- `bash Scripts/smoke_portable_oracle_docker.sh` builds the image and runs the hardened authenticated bridge E2E. It exercises both executables, concurrent lanes, Surf-style metadata/error recovery, private mode-0600 export, default UID/GID `10001`, and mapped host UID/GID.
- On Linux, reuse that image for the host-gateway path:
  `RP_PORTABLE_IMAGE=repoprompt-headless:portable-smoke RP_PORTABLE_SKIP_BUILD=1 bash Scripts/smoke_portable_host_gateway.sh`.
- Both scripts require Docker and Python 3.10+. The main smoke asserts `PYTHONOPTIMIZE` is unset.
- Useful overrides: `RP_PORTABLE_SKIP_BUILD=1`, `RP_PORTABLE_IMAGE`, `RP_PORTABLE_PLATFORM`, `RP_PORTABLE_PYTHON_IMAGE`, and `RP_PORTABLE_SMOKE_TIMEOUT_SECONDS`.
- For an existing image/archive, use `Scripts/verify_portable_release.py image|archive|metadata`; these commands verify only and never publish.

### Keeping Docker running (no systemd)

- This VM's init is `tini`; `systemctl`/`service` do not work. The idempotent `ensure-docker` helper starts `dockerd`, waits for readiness, and relaxes `/var/run/docker.sock` permissions when needed.
- `dockerd` must use the configured `fuse-overlayfs` storage driver.

### Cursor Cloud: Oracle = Surf

- Use the digest-pinned, hardened Linux host-network wrapper in `docs/architecture/portable-oracle-mcp.md#oracle--surf-on-cursor-cloud`.
- Surf must run with `surf server --http --api-key ...`; inject the bearer token through Cursor Cloud secrets and forward only the environment-variable name into Docker. Surf 2.13.3 expands that secret into its local process arguments, so isolate the Surf process and keep process listings/logs private.
- Surf `2.13.3` advertises `gpt-5.6-sol-xhigh`. The recipe uses that compound ID for both lanes plus matching `REPOPROMPT_ORACLE_REASONING_EFFORT=xhigh`. Portable starts both lanes concurrently; Surf must permit two requests.
- Keep the default image UID/GID `10001` for readable, read-only workspaces. Use `--user "$(id -u):$(id -g)" --env HOME=/tmp` only when host permissions or a writable export mount require host ownership.
- Register the wrapper as the `mcpServers.repoprompt-portable.command`. Verify initialize and all schemas with:
  `python3 Scripts/list_cursor_mcp_tools.py --expect-schema-version 1.1.0`.

### Release policy

- `.github/workflows/publish-container.yml` must smoke both exact platform candidate digests before index creation, verify the index signature/provenance, and—on releases—verify archives, SBOMs, checksums, checksum signature, and asset attestations before tag promotion.
- Every third-party Action must remain full-SHA pinned.
- Tagged releases contain digest metadata, Docker archives, SPDX SBOMs, signed checksums, attestations, hardened examples, and release notes. Verify every asset before GitHub Release creation.
- Release tags `v<version>`, `<version>`, and `sha-<full-commit>`, plus digests and release assets, are immutable. `latest` is the only movable tag and may roll back only to a previously verified, signed digest. There is no unsigned fallback.
- A digest implicated in credential exposure is not releasable or rollback-eligible until the external credential owner confirms revocation or rotation; repository checks cannot establish that fact.
- Do not commit or bake credentials. `opencode.docker.json`, image layers/history, logs, commands, and release artifacts must remain credential-free.
