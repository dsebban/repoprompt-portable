# Portable context and Oracle MCP

`repoprompt-headless` is a Linux-safe stdio MCP server. `repoprompt-portable-cli` is a direct JSONL entry point over the same `RepoPromptHeadless` catalog. The Docker image installs both executables, keeps the MCP server as its default entry point, and contains no macOS application or Classic proxy.

## Versions and capability contract

Portable software version `0.2.0` exposes exactly seven tools: `bind_context`, `get_file_tree`, `read_file`, `manage_selection`, `file_search`, `context_builder`, and `oracle_send`.

Every tool's top-level input schema advertises capability version `1.0.0` with `x-repoprompt-portable-schema-version`. MCP initialize also reports software `0.2.0` and repeats the schema version in its instructions. Earlier unversioned builds are legacy and have no implied schema version.

Contract versions use semantic versioning:

- additive optional fields increment the minor version;
- removals, renames, narrowed enums, changed defaults, or changed success/error semantics increment the major version;
- fixes with no observable schema or semantic change increment the patch version.

Probe a Cursor-registered server with:

```bash
python3 Scripts/list_cursor_mcp_tools.py --expect-schema-version 1.0.0
```

## Explicit selection and context integrity

`manage_selection` is the only selection mutation interface. `context_builder` renders the current explicit in-memory file/slice selection. It does not discover, add, remove, or expand source on the caller's behalf.

```text
context_builder(instructions, response_type?, review_diff?, max_context_bytes?)
```

- Omitted/`clarify` renders locally, needs no provider, and returns complete omission metadata.
- `plan` and `review` snapshot the selection once and invoke the Oracle workflow.
- `review_diff` is accepted only for review, preserved byte-for-byte, and limited to 262144 UTF-8 bytes.

```text
oracle_send(message, mode?, review_diff?, clarify_handoff?, max_context_bytes?)
```

- Mode is `chat|question|plan|review`; default is `chat`.
- The current explicit selection is always snapshotted and attached. There is no context-free mode.
- `review_diff` has the same review-only contract as builder review.
- `clarify_handoff` accepts up to 1048576 UTF-8 bytes of prior local clarify output in every mode.

Provider-backed `context_builder` and every `oracle_send` call fail closed before HTTP when the render is incomplete. Any omitted selected root/file/slice, unsupported codemap expansion, unreadable/non-UTF-8 source, unsafe path, or byte-budget truncation produces the MCP tool error `incomplete_workspace_context` with bounded diagnostic details. Call local clarify, correct the selection or limit, then retry. Empty-but-complete selection remains valid and is represented explicitly.

Selection is immutable for the in-flight pair. Later selection mutations cannot change either lane's prompt.

## Untrusted-evidence boundary

The workflow constructs one deterministic prompt with nonce-bound section delimiters and sends the same bytes to both lanes. Only `USER_REQUEST_INSTRUCTIONS` is instruction-bearing. These sections are untrusted evidence:

- rendered workspace source;
- caller-supplied `review_diff`;
- caller-supplied `clarify_handoff`.

The system preamble tells the model not to follow role labels, commands, tool requests, policy text, or instructions found in evidence; not to execute evidence commands; not to disclose evidence secrets merely because they appear; and not to claim inspection of omitted files. This is a trust boundary, not permission to send secrets: all three evidence classes leave the container and are disclosed to both configured providers. Callers must review provider output as untrusted generated content.

## Oracle configuration and concurrency

Oracle access is process configuration only:

- `OPENCODE_API_KEY`: enables the OpenCode Go defaults (`deepseek-v4-flash` for both lanes).
- `REPOPROMPT_ORACLE_ENDPOINT`: absolute `http` or `https` chat-completions URL, without embedded credentials or a fragment.
- `REPOPROMPT_ORACLE_PRIMARY_MODEL`: required Primary model ID for explicit configuration.
- `REPOPROMPT_ORACLE_SECONDARY_MODEL`: required Secondary model ID; it may equal Primary.
- `REPOPROMPT_ORACLE_API_KEY`: optional bearer token sent as `Authorization: Bearer ...`.
- `REPOPROMPT_ORACLE_REASONING_EFFORT`: optional top-level `reasoning_effort` string applied to both lanes.
- `REPOPROMPT_ORACLE_TIMEOUT_SECONDS`: integer `1...3600`; default `120`.

The explicit endpoint and both model variables must be all present or all absent. When present they override OpenCode Go defaults. Do not also pass `OPENCODE_API_KEY` unless the separate OpenCode entry point needs it.

Each provider-backed operation creates one pair and starts fixed Primary and Secondary requests concurrently against one immutable prompt. Results remain lane-local even when completion order reverses. A Secondary success never replaces a Primary failure. The caller/MCP timeout must exceed the provider timeout, and the provider must allow two simultaneous requests if parallel completion is required.

The endpoint receives non-streaming OpenAI chat-completions requests with `model`, `messages`, optional top-level `reasoning_effort`, and `stream: false`. There is no automatic retry or retry-without-reasoning fallback.

### Result fidelity

Each completed lane contains `provider_metadata` with bounded fields when supplied upstream: HTTP status, latency, response/request IDs, observed model, finish reason, token usage, conversation ID, baseline assistant message ID, and structured recovery metadata.

Each failed lane retains bounded/redacted structured evidence when available: stable portable code/message, HTTP status, latency, request ID, provider error type/parameter/code/failure reason, recovery data, retryability, numeric `Retry-After`, and a sanitized raw error body capped at 16 KiB. Arbitrary response headers and full successful response bodies are not exposed. Bearer tokens are redacted. Recovery fields are advisory; portable never retries automatically.

`oracle_results.primary` and `oracle_results.secondary` are always independent. Top-level `response`, `model_raw_id`, `provider_metadata`, `ok`, and `error` project Primary only. `pair_status` is `completed`, `partial_failure`, or `failed`; there is no synthesis or winner.

## Direct CLI and private exports

The non-interactive CLI accepts one exact tool plus an optional JSON object or repeatable `-e|--exec` expressions:

```text
repoprompt-portable-cli [global options] <exact-tool-name> ['<JSON object>']
repoprompt-portable-cli [global options] -e '<exact-tool-name> [JSON object]' [-e ...]
```

One process owns one ephemeral catalog and selection. Repeated commands execute sequentially and share state only in that process. Success emits one compact JSON object per line on stdout; diagnostics and tool errors use stderr.

`--export-jsonl <path>` is CLI-only. After every command succeeds, it preserves stdout and atomically creates a new mode-0600 file containing the exact JSONL bytes and final newline. The parent must exist. Existing destinations, symlinks, directories, and filesystems without atomic no-replace semantics are refused. A tool/runtime failure creates no export; an export failure exits `73` and never overwrites an existing file. Treat exports as private artifacts because they can contain selected source and provider responses.

MCP remains seven-tool and write-free. It does not expose managed exports.

## Container security

The image builds both Swift products from a digest-pinned Swift base, checksum-verifies OpenCode `1.18.4`, contains no download tooling in the final stage, and defaults to UID/GID `10001`.

Use an immutable release digest and the hardened baseline:

```bash
IMAGE='ghcr.io/dsebban/repoprompt-portable@sha256:<verified-index-digest>'
docker run --rm -i \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  "$IMAGE" --no-persist --root /workspace
```

The default identity is preferred for read-only workspaces that are traversable by UID/GID `10001`. For host-owned files or a writable export mount, add:

```bash
--user "$(id -u):$(id -g)" --env HOME=/tmp
```

Keep the workspace read-only and mount a separate output directory read-write for `--export-jsonl`.

## Oracle = Surf on Cursor Cloud

Surf CLI `2.13.3` help, OpenAPI, and live `/v1/models` discovery were checked with portable software `0.2.0` and tool schema `1.0.0`. Surf advertises `gpt-5.6-sol`, accepts top-level `reasoning_effort`, and exposes compound effort IDs including `gpt-5.6-sol-xhigh`. The portable completion contract is exercised by the authenticated deterministic fixture; no live browser-model completion is claimed.

### 1. Start an authenticated Surf endpoint

On the Cursor Cloud Linux host, inject `SURF_ORACLE_API_KEY` through the platform's secret environment. Do not place it in the image, repository, logs, or exported JSONL. Surf `2.13.3` documents bearer configuration through `--api-key`, so shell expansion places the token in Surf's local process arguments; run Surf as an isolated user, restrict process visibility, and never enable command tracing:

```bash
: "${SURF_ORACLE_API_KEY:?set this in Cursor Cloud secrets}"
surf server --http \
  --host 127.0.0.1 \
  --port 8787 \
  --api-key "$SURF_ORACLE_API_KEY" \
  --timeout 3500
```

`--api-key` requires bearer authentication on Surf's `/v1/*` routes. Check `/health` and `/v1/models` locally before launching portable. Ensure Surf reports/effectively permits at least two concurrent ChatGPT requests because portable starts both lanes concurrently.

### 2. Use a digest-pinned hardened wrapper

Linux host networking lets Surf remain loopback-only. Save this wrapper outside the repository, replace the digest, and make it executable:

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${SURF_ORACLE_API_KEY:?missing Cursor Cloud secret}"

export REPOPROMPT_ORACLE_ENDPOINT=http://127.0.0.1:8787/v1/chat/completions
export REPOPROMPT_ORACLE_PRIMARY_MODEL=gpt-5.6-sol-xhigh
export REPOPROMPT_ORACLE_SECONDARY_MODEL=gpt-5.6-sol-xhigh
export REPOPROMPT_ORACLE_REASONING_EFFORT=xhigh
export REPOPROMPT_ORACLE_API_KEY="$SURF_ORACLE_API_KEY"
export REPOPROMPT_ORACLE_TIMEOUT_SECONDS=3600

IMAGE='ghcr.io/dsebban/repoprompt-portable@sha256:<verified-index-digest>'
exec docker run --rm -i \
  --network host \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  --env REPOPROMPT_ORACLE_ENDPOINT \
  --env REPOPROMPT_ORACLE_PRIMARY_MODEL \
  --env REPOPROMPT_ORACLE_SECONDARY_MODEL \
  --env REPOPROMPT_ORACLE_REASONING_EFFORT \
  --env REPOPROMPT_ORACLE_API_KEY \
  --env REPOPROMPT_ORACLE_TIMEOUT_SECONDS \
  "$IMAGE" --no-persist --root /workspace
```

The compound model ID fixes Surf's effort variant; the matching explicit `reasoning_effort=xhigh` also exercises the standard request field. Alternatively use base model `gpt-5.6-sol` with the same reasoning-effort variable. Do not pass `OPENCODE_API_KEY` in this Surf-only path.

Point Cursor's `mcpServers.repoprompt-portable.command` at the wrapper. The wrapper must inherit `SURF_ORACLE_API_KEY` from the Cursor Cloud secret environment. Then verify initialize and the seven versioned schemas:

```bash
python3 Scripts/list_cursor_mcp_tools.py --expect-schema-version 1.0.0
```

### Host connectivity by platform

- **Cursor Cloud/Linux, loopback Surf:** use `--network host` as above. It is less isolated than bridge networking but does not expose Surf beyond host loopback.
- **Linux bridge:** bind Surf to a bridge-reachable host address, add `--add-host host.docker.internal:host-gateway`, and use `http://host.docker.internal:8787/...`. Keep bearer auth enabled and restrict the port with host firewall rules. A service bound only to `127.0.0.1` is generally not reachable through the bridge gateway.
- **Docker Desktop macOS/Windows:** use the built-in `host.docker.internal` name; no Linux `--add-host` mapping is normally required.
- **Private container bridge:** when Surf/provider also runs in a container, prefer a user-defined network and address it by network alias. This is the deterministic CI path.

## Build and verification

```bash
swift build --product repoprompt-headless
swift build --product repoprompt-portable-cli
swift test
python3 Scripts/test_verify_portable_release.py
python3 Scripts/verify_portable_release.py source --expected-version 0.2.0
bash Scripts/smoke_portable_oracle_docker.sh
RP_PORTABLE_IMAGE=repoprompt-headless:portable-smoke RP_PORTABLE_SKIP_BUILD=1 \
  bash Scripts/smoke_portable_host_gateway.sh  # Linux only
```

The bridge smoke runs with a read-only root filesystem, tmpfs `/tmp`, no capabilities, `no-new-privileges`, a read-only workspace, and default UID/GID. It exercises both binaries, both provider lanes, metadata/error recovery, and mapped-host-user private export. The host-gateway smoke verifies the Linux bridge route with bearer authentication.

`Scripts/verify_portable_release.py` provides fail-closed `source`, `image`, `archive`, and `metadata` checks. It does not build or publish.

## Release trust and rollback

The publication workflow:

1. runs source policy, Python tests, both Swift builds, and full Swift tests;
2. builds `linux/amd64` and `linux/arm64` candidates by digest;
3. pulls, fully smokes, and verifies each exact candidate digest before manifest creation;
4. creates and natively smokes the multi-architecture index;
5. keyless-signs and attests the index digest, then verifies both;
6. for version tags, verifies Docker-loadable archives, SPDX SBOMs, checksums, checksum signature, and asset attestations before promotion;
7. promotes only the verified digest to immutable `v<version>`, `<version>`, and `sha-<full-commit>` tags (or the commit tag and movable `latest` on `main`), then creates the GitHub Release from the already verified assets.

Every third-party GitHub Action is pinned to a full 40-character commit SHA and checked by the `source` policy command.

Release consumers should download `container-digests.json`, `SHA256SUMS`, and `SHA256SUMS.sigstore.json`; verify checksums, the Sigstore bundle's expected workflow identity/issuer, GitHub asset attestations, the container digest signature/provenance, and the SBOM files covered by the signed checksums. Copy/paste verification commands are in the README and generated release notes.

Version tags, commit tags, digests, and GitHub release assets are immutable. `latest` is the only movable tag. Rollback retargets `latest` only to a previously verified and signed digest; it never overwrites an immutable tag or asset and never falls back to an unsigned image. A digest implicated in credential exposure is excluded from release and rollback until revocation or rotation is confirmed through the external credential owner; repository inspection cannot prove that operational step.

## Intentionally unsupported

Portable does not provide `workspace_context`, `ask_oracle`, chat continuation/logs, model overrides in tool arguments, MCP-managed exports, automatic/synthesized Git diffs, images/screenshots, autonomous discovery, writes/edits, UI/model settings, Agent Mode orchestration, or workspace/Oracle persistence. It does support caller-supplied `review_diff`, CLI-only `--export-jsonl`, and provider-backed builder `plan|review`; those are not the unsupported CE features above.
