# MCP transport reference

## Server contract

Run `repoprompt-headless` as a stdio MCP server:

```bash
repoprompt-headless --no-persist --root /absolute/workspace
```

The server intentionally rejects interactive TTY use. Register it as a stdio command in the host agent or MCP client.

Portable software `0.2.0` exposes tool-schema version `1.0.0` on exactly seven tools:

- `bind_context`
- `get_file_tree`
- `read_file`
- `manage_selection`
- `file_search`
- `context_builder`
- `oracle_send`

Inspect the host-provided tool schemas before invocation. Reject an unexpected schema major version.

## Connection lifecycle

1. Start one server process for the workspace roots.
2. Initialize MCP and list tools.
3. Use `bind_context` with `{"op":"status"}` to inspect the current context or `{"op":"bind","context_id":"<uuid>"}` when the host exposes multiple contexts.
4. Discover, read, and select source.
5. Keep the same connection for calls that depend on selection state.

Selection and session state are process-local and ephemeral under `--no-persist`.

## Provider configuration

Provider-free discovery, reads, selection, and `context_builder(..., "clarify")` need no API key.

Provider-backed calls require either `OPENCODE_API_KEY` defaults or the complete explicit tuple:

```text
REPOPROMPT_ORACLE_ENDPOINT
REPOPROMPT_ORACLE_PRIMARY_MODEL
REPOPROMPT_ORACLE_SECONDARY_MODEL
```

Optional variables:

```text
REPOPROMPT_ORACLE_API_KEY
REPOPROMPT_ORACLE_REASONING_EFFORT
REPOPROMPT_ORACLE_TIMEOUT_SECONDS
```

The endpoint and both model variables must be all present or all absent. Configure the MCP client timeout above the provider timeout. Each provider-backed call starts two concurrent requests.

## Container baseline

Mount the workspace read-only, run by immutable digest, drop capabilities, enable `no-new-privileges`, use a read-only root filesystem, and provide `/tmp` as tmpfs. Pass credentials only by environment-variable name. Never bake credentials into configuration or images.

For deployment, provider networking, and release verification details, read the repository's `docs/architecture/portable-oracle-mcp.md`.

