# Portable Builder and CLI Parity Plan

Date: 2026-07-23

## Goal

Extend `repoprompt-portable` in two narrowly scoped ways:

1. `context_builder` accepts `response_type: "plan"` and `response_type: "review"`, uses the existing configured OpenAI-compatible Primary/Secondary Oracle workflow, and preserves the current provider-free omitted/`clarify` behavior.
2. A direct shell executable named `repoprompt-portable-cli` invokes exactly the seven tools already advertised by portable: `bind_context`, `get_file_tree`, `read_file`, `manage_selection`, `file_search`, `context_builder`, and `oracle_send`.

The implementation should reuse the current in-process `HeadlessToolCatalog`, selection/session objects, `HeadlessWorkspaceContextBuilder`, `HeadlessOracleWorkflow`, and `OpenAICompatibleOracleProvider`. Do not port RepoPrompt CE’s app/window transport, chat persistence, export service, interactive REPL, editing tools, agent tools, or broad alias/parser framework.

## Current state and decisions

- `RepoPromptHeadless/HeadlessToolCatalog.swift` advertises exactly seven tools. Its `buildContext(_:)` accepts only omitted/`clarify` and hard-rejects provider-generating response types.
- `oracleSend(_:)` already validates `chat|question|plan|review`, snapshots selection once, builds one immutable context, executes mandatory concurrent Primary/Secondary requests, and serializes a stable pair envelope with Primary-only top-level projection.
- `HeadlessOracleWorkflow` and `OpenAICompatibleOracleProvider` already implement the required provider behavior. They should not gain a second builder-specific execution path.
- Portable has no durable Oracle chat store or managed response-export service. Provider-backed builder results will therefore remain stateless. They will not claim CE-compatible `chat_id`, follow-up, or `oracle_export_path` behavior. Shell redirection or a JSON processor is the CLI export mechanism.
- The CLI must keep one catalog/session alive for a sequence of commands because selection is in-memory. Repeatable `-e` commands provide that boundary; separate CLI processes do not share selection.
- The chosen product and binary name is `repoprompt-portable-cli`. No compatibility symlink or second short name is included.
- The CLI accepts exact portable tool names and JSON-object arguments. It does not copy CE’s `builder`, `read`, `tree`, key/value, JSON-repair, window/tab, or interactive syntax.
- No new package dependency is required.

## Work item 1 — Add provider-backed builder modes through the existing Oracle path

**Goal:** Make `context_builder` generate plans and reviews without duplicating context assembly, provider calls, lane policy, or serialization.

**Dependencies:** None.

**Size:** Small, focused catalog change.

**Key files:**

- `RepoPromptHeadless/HeadlessToolCatalog.swift`
- `RepoPromptHeadless/HeadlessMCPService.swift`
- `RepoPromptHeadlessTests/RepoPromptHeadlessCatalogOracleTests.swift`

**Implementation:**

1. Add a private closed parser for builder response types in `HeadlessToolCatalog.swift`:
   - omitted or `clarify` → existing provider-free context-only branch;
   - `plan` → `HeadlessOracleMode.plan`;
   - `review` → `HeadlessOracleMode.review`;
   - every other value, including `question` and `chat`, → `invalid_params`.
2. Update the advertised `context_builder` JSON Schema so `response_type` has the enum `clarify|plan|review`. Keep `instructions` required, `additionalProperties: false`, and the existing context-byte bounds.
3. Change the tool-level annotations to describe the most side-effectful accepted mode: read-only and non-destructive, but non-idempotent and open-world because plan/review make provider requests.
4. Extract one private catalog helper used by both `buildContext(_:)` and `oracleSend(_:)` that:
   - requires `oracleWorkflow` before reading selected files;
   - snapshots `selectionStore` once;
   - builds one `HeadlessWorkspaceContext`;
   - calls `HeadlessOracleWorkflow.execute(mode:request:context:)`;
   - maps `HeadlessOracleWorkflowError` to the existing `HeadlessToolError` contract;
   - returns the context and pair so the existing `pairJSON` serializer remains authoritative.
5. Preserve validation precedence: unknown arguments → required/size checks → response type/mode → context-byte bounds → Oracle configuration → context read → provider work. A valid plan/review without configuration returns `oracle_not_configured`; clarify never requires configuration.
6. Preserve the clarify response exactly:

   ```json
   {
     "ok": true,
     "status": "context_built",
     "response_type": "clarify",
     "prompt": "...",
     "workspace_context": {}
   }
   ```

7. For plan/review, start with the existing `pairJSON` object and add only builder metadata:
   - `response_type: "plan"|"review"`;
   - `prompt: <trimmed instructions>`;
   - `status: "response_generated"` when Primary completed, otherwise `"response_failed"`.

   Keep `ok`, `response`, `error`, `pair_status`, `oracle_pair_id`, `oracle_decision_policy`, `model_raw_id`, `workspace_context`, and both `oracle_results` exactly aligned with `oracle_send`. Secondary is never promoted. A terminal provider/lane failure remains an MCP-success result with `ok: false`; argument/configuration/cancellation/catalog errors remain MCP tool errors.
8. Do not add `export_response`, `chat_id`, `new_chat`, follow-up hints, durable pair state, a winner, or synthesized output. `oracle_pair_id` remains correlation metadata, not a continuation handle.
9. Update `HeadlessMCPService` instructions to state that clarify is local and plan/review disclose the rendered selected context to the configured provider.

**Done when:**

- Omitted/clarify calls are byte-for-byte schema-compatible and do not invoke a provider.
- Plan and review each dispatch exactly two fixed-lane requests using one immutable selected-context snapshot.
- Both builder and `oracle_send` use the same Oracle execution helper and pair serializer.
- Primary failure is never replaced by a successful Secondary result.
- Schema, annotation, validation-precedence, unconfigured-provider, immutable-snapshot, partial-failure, and absence-of-chat/export-field tests pass.

## Work item 2 — Add the thin direct CLI over the shared headless catalog

**Goal:** Provide a shell-native executable with persistent state within one process and no surface beyond portable’s seven advertised tools.

**Dependencies:** Work item 1, so builder plan/review behavior is available through the same catalog.

**Size:** Large, multi-file packaging and executable-boundary change.

**Key files/modules:**

- `Package.swift`
- `RepoPromptHeadless/RepoPromptHeadlessMain.swift` (move only)
- `RepoPromptHeadless/HeadlessExitCode.swift`
- new `RepoPromptHeadlessServer/RepoPromptHeadlessServerMain.swift`
- new `RepoPromptPortableCLI/PortableCLIArguments.swift`
- new `RepoPromptPortableCLI/PortableCLIApplication.swift`
- new `RepoPromptPortableCLI/RepoPromptPortableCLIMain.swift`
- new `RepoPromptPortableCLITests/PortableCLIArgumentsTests.swift`
- new `RepoPromptPortableCLITests/PortableCLIApplicationTests.swift`

**Implementation:**

1. Split the current executable target so the runtime is safely reusable by two binaries:
   - convert target `RepoPromptHeadless` from `.executableTarget` to `.target` without adding a public library product;
   - add executable target `RepoPromptHeadlessServer` depending on `RepoPromptHeadless`;
   - keep product `repoprompt-headless`, now pointing to `RepoPromptHeadlessServer`;
   - move the existing `@main` code unchanged in behavior to `RepoPromptHeadlessServer/RepoPromptHeadlessServerMain.swift`;
   - add executable target/product `RepoPromptPortableCLI` / `repoprompt-portable-cli`, depending on `RepoPromptHeadless` and the already-declared MCP product;
   - keep `RepoPromptHeadlessTests` importing `RepoPromptHeadless` and add `RepoPromptPortableCLITests`.
2. Do not duplicate the catalog allowlist in production. After bootstrap, derive the accepted tool-name set from `await catalog.tools().map(\.name)` and reject any requested name outside that set before calling it. Help text may list the seven names explicitly, with a parity test against `catalog.tools()`.
3. Support only these invocation forms:

   ```text
   repoprompt-portable-cli [global options] <exact-tool-name> ['<JSON object>']
   repoprompt-portable-cli [global options] -e '<exact-tool-name> [JSON object]' [-e ...]
   ```

   Supported global options are repeatable `--root`, optional `--workspace-name`, optional `--session-id`, repeatable `-e|--exec`, and `-h|--help`. Default root is the current directory. The CLI always uses `persist: false` and `allowWrites: false`.
4. Parse and JSON-decode the full command sequence before bootstrap or execution. Each command is one exact tool name plus an optional JSON object decoded directly to `[String: MCP.Value]`. Reject malformed JSON, scalar/array JSON, aliases, unadvertised tools, mixed implicit/`-e` execution, and extra unquoted arguments as usage errors.
5. Resolve `HeadlessOracleConfiguration` once using the existing environment contract, bootstrap one `HeadlessWorkspaceBootstrap`, and construct one `HeadlessToolCatalog`. Execute commands sequentially so selection changes from command N are visible to command N+1. Do not add cross-process persistence or parallel command execution.
6. Normalize each successful catalog result to one compact, sorted-key JSON object on stdout. Multiple commands produce JSON Lines in command order with no headings, progress text, colors, or blank separators.
7. Stream and exit conventions:
   - help: stdout, exit `0`;
   - successful `CallTool.Result` (`isError != true`): stdout JSONL, exit `0` after all commands;
   - tool error (`isError == true`): compact error JSON on stderr, stop, exit `1`;
   - CLI syntax/tool-name/JSON error: diagnostic plus brief usage on stderr, exit `64`;
   - invalid root or Oracle environment: stderr, exit `78`;
   - unexpected bootstrap or result-contract failure: stderr, exit `70`.
8. Add `HeadlessExitCode.toolFailure = 1` and use it for `CallTool.Result.isError == true`. Do not reinterpret provider lane failure: the existing MCP-success envelope with `ok: false` is printed to stdout and exits `0`; scripts inspect `ok` and `pair_status`.
9. Require exactly one textual JSON object in each catalog result. Treat future non-text or non-JSON results as exit `70` rather than inventing a lossy renderer.
10. Keep the server’s current SIGPIPE, TTY rejection, stdio MCP behavior, product name, and default Docker entry point unchanged.

**Done when:**

- Both `repoprompt-headless` and `repoprompt-portable-cli` build from the same package without copied workspace/provider logic.
- Help and parsing expose only the seven catalog-advertised names.
- A two-command process can select a file and then consume it with `context_builder`; two separate processes do not claim shared state.
- Stdout, stderr, stop-on-first-tool-error, and exit-code tests cover success, usage, configuration, tool, and runtime failures.
- The existing MCP server tests still import the reusable `RepoPromptHeadless` module and pass.

## Work item 3 — Package, document, and exercise both real entry points

**Goal:** Ship the CLI with the existing image and verify real MCP and direct-CLI flows, including provider-backed builder generation.

**Dependencies:** Work items 1 and 2.

**Size:** Small, focused packaging/smoke/documentation update.

**Key files:**

- `Dockerfile.headless`
- `Scripts/portable_oracle_mcp_smoke.py`
- `Scripts/smoke_portable_oracle_docker.sh`
- `README.md`
- `docs/architecture/portable-oracle-mcp.md`

**Implementation:**

1. Update `Dockerfile.headless` to copy the new server/CLI target directories, build both release products, and install both binaries. Keep `ENTRYPOINT ["/usr/local/bin/repoprompt-headless"]`; direct CLI container use overrides the entry point.
2. Expand the stdio MCP smoke to call:
   - `context_builder` clarify and assert no Oracle fields;
   - `context_builder` plan and assert `response_type`, builder `status`, Primary projection, both completed lanes, selected sentinel in both requests, and no chat/export/winner/synthesis fields;
   - existing `oracle_send` review and assert its envelope remains unchanged.
3. Update fixture request counters for two provider-backed pair calls: four total requests, two Primary, two Secondary, two completed pairs, no failures, and no active pairs.
4. Add a Docker smoke using the installed direct CLI with no provider configuration: run `manage_selection` then `context_builder` clarify in one process, parse exactly two JSONL records, assert the sentinel is present, assert stderr is empty, and assert exit `0`.
5. Document the privacy and lifecycle boundary: plan/review send selected context externally; clarify stays local; builder results are stateless; review sees selected context rather than a synthesized git diff; exports use shell redirection; repeated `-e` commands share selection only within one process; exact tool names and JSON objects are required.

**Done when:**

- The image contains both binaries while its default MCP entry point is unchanged.
- The real stdio MCP smoke proves builder plan generation and unchanged `oracle_send` behavior against the fixture provider.
- The real installed CLI smoke proves parsing, sequential shared selection, JSONL output, and clarify without provider work.
- Documentation matches the implemented schema, provider disclosure, CLI grammar, and unsupported features.

## Verification commands

Run from `/Users/danielsivan/dev/repoprompt-portable`.

### Package and focused tests

```bash
swift package dump-package >/tmp/repoprompt-portable-package.json
swift build --product repoprompt-headless
swift build --product repoprompt-portable-cli
swift test --filter RepoPromptHeadlessCatalogOracleTests
swift test --filter PortableCLIArgumentsTests
swift test --filter PortableCLIApplicationTests
swift test
```

### Direct CLI, provider-free end-to-end slice

```bash
portable_fixture="$(mktemp -d)"
printf '%s\n' 'PORTABLE_CLI_FIXTURE_SENTINEL' > "$portable_fixture/fixture.txt"

swift run repoprompt-portable-cli \
  --root "$portable_fixture" \
  -e 'manage_selection {"op":"set","mode":"full","paths":["fixture.txt"]}' \
  -e 'context_builder {"instructions":"Assemble the selected fixture.","response_type":"clarify"}' \
  | python3 -c '
import json, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
assert len(rows) == 2, rows
assert rows[0]["selection"]["selected_paths"] == ["fixture.txt"], rows[0]
assert rows[1]["status"] == "context_built", rows[1]
assert rows[1]["response_type"] == "clarify", rows[1]
assert "PORTABLE_CLI_FIXTURE_SENTINEL" in rows[1]["workspace_context"]["content"], rows[1]
'

trash "$portable_fixture"
```

### Actual MCP/provider and packaged CLI verification

```bash
bash Scripts/smoke_portable_oracle_docker.sh
```

The updated script must start the fixture provider, run the built image through real stdio MCP, verify `context_builder(plan)`, verify unchanged `oracle_send(review)`, run the image’s installed `repoprompt-portable-cli` clarify flow, and assert final request counters.

### Final scope audit

```bash
git status --short
git diff --name-only
git diff --check
```

## Assumptions and explicit exclusions

- `plan` and `review` are the requested builder additions. `question` remains available through `oracle_send` but is not added to `context_builder` in this scope.
- RepoPrompt CE is a behavioral reference only. No CE source file or package dependency is imported into portable.
- Managed exports and chat continuation require subsystems portable does not have. They are intentionally excluded instead of represented by placeholders or fallbacks.
- The direct CLI is non-interactive and ephemeral. A REPL, window/tab binding, cross-process selection persistence, command aliases, key/value parsing, JSON repair, editing, git, agent delegation, and settings are out of scope.
- Existing Oracle configuration, provider timeouts, mandatory two-lane execution, failure mapping, context limits, path security, and no-retry policy remain unchanged.
- The server version and provider user-agent strings are release-owned and are not changed by this work.

## Current-worktree conflicts

At planning time:

- `repoprompt-portable` is on `main` with two unrelated untracked benchmark files: `benchmarks/p-limit-portable.json` and `benchmarks/run_portable_benchmark.py`.
- `repoprompt-ce` is on clean `main`.
- The benchmark files do not overlap this plan and must remain untouched. No CE file should be modified.
- This plan file is the only intended repository change from the planning task.
