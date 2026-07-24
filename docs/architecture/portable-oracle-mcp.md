# Portable context and Oracle MCP

`repoprompt-headless` is a Linux-safe stdio MCP server built from the `RepoPromptHeadlessServer`, `RepoPromptHeadless`, and `RepoPromptCore` SwiftPM targets. `repoprompt-portable-cli` is a direct shell entry point over the same headless catalog. The Docker image installs both binaries, keeps `repoprompt-headless` as its default entry point, and does not build or copy the macOS app, AppKit/SwiftUI sources, or the Classic MCP proxy.

## Oracle configuration

Oracle access is configured only through process environment variables:

- `OPENCODE_API_KEY`: enables the default OpenCode Go configuration. Both Oracle lanes use `deepseek-v4-flash` through `https://opencode.ai/zen/go/v1/chat/completions`.
- `REPOPROMPT_ORACLE_ENDPOINT`: exact OpenAI-compatible chat-completions URL. It must be an absolute `http` or `https` URL without embedded credentials or a fragment.
- `REPOPROMPT_ORACLE_PRIMARY_MODEL`: required Primary model ID.
- `REPOPROMPT_ORACLE_SECONDARY_MODEL`: required Secondary model ID. It may equal Primary, but both requests still run.
- `REPOPROMPT_ORACLE_API_KEY`: optional bearer token sent as `Authorization: Bearer ...`.
- `REPOPROMPT_ORACLE_TIMEOUT_SECONDS`: optional integer from 1 through 600; default 120.

`OPENCODE_API_KEY` is sufficient for the default configuration. Explicit endpoint and both model variables must either all be set or all be absent; when present they override the OpenCode Go defaults. The endpoint must accept non-streaming `POST` requests with OpenAI chat-completions `model` and `messages` fields and return string content at `choices[0].message.content`.

## Source transmission

`oracle_send` and provider-backed `context_builder` plan/review calls snapshot the current in-memory selection, read the selected UTF-8 files or slices once, and send the same rendered user prompt to Primary and Secondary. Selected source therefore leaves the container and is disclosed to the configured endpoint. `context_builder` with an omitted response type or `clarify` stays local and does not require provider configuration. Mount source workspaces read-only and select only material that the provider may receive.

The context builder rejects selected symlinks that resolve outside a workspace root, does not expand codemap-only selections, caps aggregate source reads, and reports entries omitted by limits or the context budget to both Oracle lanes. Builder plan/review results are stateless: there is no chat continuation or managed export. Review uses the selected context as supplied; it does not synthesize a git diff. Use shell redirection to save MCP client or direct-CLI output.

## Portable tool contract

The portable surface is exactly seven tools: `bind_context`, `get_file_tree`, `read_file`, `manage_selection`, `file_search`, `context_builder`, and `oracle_send`.

- `context_builder(instructions, response_type?, max_context_bytes?)` accepts `clarify`, `plan`, or `review`. Omitted/`clarify` assembles local selected-file context; plan/review start mandatory concurrent Primary and Secondary HTTP requests using one immutable shared prompt.
- `oracle_send(message, mode?, max_context_bytes?)` accepts `chat`, `question`, `plan`, or `review` and uses the same provider workflow.

`oracle_send` returns `oracle_results.primary` and `oracle_results.secondary` independently. Top-level `response`, `model_raw_id`, `ok`, and `error` project Primary only; Secondary never replaces Primary. `pair_status` reports `completed`, `partial_failure`, or `failed`. There is no automatic synthesis, winner, or recommendation.

Selection is managed with the existing in-memory `manage_selection` tool. Close stdin to stop the stdio server.

## Direct CLI contract

The non-interactive `repoprompt-portable-cli` accepts either one exact tool name with an optional JSON-object argument or repeatable `-e|--exec` commands. It has no aliases, key/value repair, or interactive syntax. Successful commands emit one compact JSON object per line on stdout; diagnostics and tool errors use stderr.

```text
repoprompt-portable-cli [global options] <exact-tool-name> ['<JSON object>']
repoprompt-portable-cli [global options] -e '<exact-tool-name> [JSON object]' [-e ...]
```

A CLI process owns one ephemeral catalog and selection. Repeated `-e` commands execute sequentially and share that selection only within the process; separate invocations do not. The CLI always disables persistence and writes. Provider-backed calls use the same environment configuration described above. Redirect stdout to export results.

## Build and run with Docker

Build the actual SwiftPM product and the pinned OpenCode CLI:

```bash
docker build -f Dockerfile.headless -t repoprompt-headless:portable .
```

The image includes OpenCode with `opencode-go/deepseek-v4-flash` as its default and small model. The Swift base image is digest-pinned, and the architecture-specific OpenCode 1.18.4 release archive is verified against its published SHA-256 before being copied into the final image. The final image contains no download tooling and runs as non-root UID/GID `10001`.

The allowlisted Docker context contains `Package.swift`, `Package.resolved`, the OpenCode config, and every path declared by the active Linux manifest: `RepoPromptCore`, `RepoPromptHeadless`, `RepoPromptHeadlessServer`, `RepoPromptPortableCLI`, `RepoPromptHeadlessTests`, and `RepoPromptPortableCLITests`. The build stage dumps the Linux manifest and dependency graph before compiling both `--product repoprompt-headless` and `--product repoprompt-portable-cli`.

The OpenCode model is a configuration default, not a binary restriction. Override `/etc/opencode/opencode.json`, set `OPENCODE_CONFIG` to another mounted config, or provide `OPENCODE_CONFIG_CONTENT` to select any provider/model available to OpenCode, including Codex-backed providers. Pass only the credential environment variables required by that provider. Portable `context_builder` clarify remains provider-free; builder plan/review and `oracle_send` use the independently configurable `REPOPROMPT_ORACLE_*` endpoint and model values when they are set.

Run it over stdio with a read-only workspace mount. The configured endpoint must be reachable from inside the container:

```bash
docker run --rm -i \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  --env OPENCODE_API_KEY \
  repoprompt-headless:portable \
  --no-persist --root /workspace
```

Bind-mounted directories and selected files must be traversable/readable by UID/GID `10001`; alternatively, override the container user with Docker's `--user` option when host permissions require it.

Run OpenCode from the same image. `--env OPENCODE_API_KEY` forwards the local value without storing it in an image layer:

```bash
docker run --rm -it \
  --entrypoint opencode \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  --env OPENCODE_API_KEY \
  repoprompt-headless:portable \
  run "Use repoprompt-portable context_builder to summarize the selected context."
```

Run the deterministic end-to-end smoke on macOS Docker Desktop or Linux Docker:

```bash
bash Scripts/smoke_portable_oracle_docker.sh
```

Useful smoke overrides are `RP_PORTABLE_IMAGE`, `RP_PORTABLE_SKIP_BUILD=1`, `RP_PORTABLE_PYTHON_IMAGE`, and `RP_PORTABLE_SMOKE_TIMEOUT_SECONDS`. The smoke uses a private Docker network, a threaded authenticated fake provider, and a temporary read-only fixture workspace. It verifies local builder clarify, provider-backed builder plan, unchanged `oracle_send` review, and the installed direct CLI's two-command JSONL clarify flow. It requires four provider requests: two Primary, two Secondary, two completed synchronized pairs, two shared-prompt hashes, and zero auth, validation, duplicate-lane, mismatch, barrier, or active-pair failures.

## Intentionally unsupported

Portable mode does not provide `workspace_context`, `ask_oracle`, chat continuation or logs, model overrides in tool arguments, managed exports, synthesized git diffs, images or screenshots, autonomous discovery, writes or edits, UI/model settings, Agent Mode orchestration, or workspace/Oracle persistence. The direct CLI also does not provide aliases, JSON repair, key/value parsing, a REPL, or cross-process selection state.
