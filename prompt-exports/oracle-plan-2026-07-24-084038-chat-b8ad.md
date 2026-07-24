## Final Prompt
<taskname="Portable benchmark hardening"/>

<task>
Plan one minimal benchmark-hardening iteration for the portable plan/review workflow. The current pinned p-limit benchmark calls `context_builder(clarify)` and then `oracle_send(plan)`, never directly exercises `context_builder(plan|review)`, never applies code, and never runs the p-limit suite. Design a bounded harness that directly runs builder plan, deterministically chooses one completed lane, applies that plan only inside an isolated writable copy of p-limit commit `df476048d023ff868cd45b35ee47f5fb0ca2b25a`, runs `npm test`, directly runs builder review over the changed implementation plus real diff/test provenance, validates both Primary and Secondary envelopes for both builder calls, appends a concise run record to `prompt-exports/optimize-portable-plan-review-runs.md`, propagates and records `REPOPROMPT_ORACLE_TIMEOUT_SECONDS`, records image/model/timeout provenance without secrets, and stops when both review lanes agree or after five iterations.

Return an implementation-ready plan only; do not edit files. Keep this as the smallest correct benchmark/test/script change and avoid production changes unless the selected contracts demonstrate a product defect. Preserve the existing dirty worktree: no reset, clean, restore, overwrite of user files, or mutation of the source p-limit checkout. State exact files, interfaces, artifacts, assertions, failure behavior, and verification commands.
</task>

<architecture>
- `benchmarks/run_portable_benchmark.py` is the live-image stdio MCP benchmark and primary future edit candidate. It imports the Python MCP client/helpers, mounts the supplied workspace read-only, selects six pinned p-limit files, and currently emits one JSON artifact after `clarify` + `oracle_send(plan)`.
- `Scripts/portable_oracle_mcp_smoke.py` owns `StdioMCPClient`, JSON-RPC decoding, `tool_json`, nested-key checks, and existing structural assertions for direct builder plan. Its client timeout is a Python/stdout deadline, distinct from the provider HTTP timeout.
- `HeadlessToolCatalog.context_builder(plan|review)` snapshots the current selection, builds one immutable context, invokes the shared two-lane Oracle workflow, and returns builder metadata plus the existing pair envelope. Portable remains read-only and has no apply, git, diff synthesis, managed export, or chat continuation capability.
- `HeadlessOracleWorkflow` always dispatches fixed Primary and Secondary lanes concurrently. `pair_status` is derived from terminal lane statuses; top-level `ok`, `response`, `error`, and `model_raw_id` project Primary only. Secondary is never promoted at the API layer.
- `HeadlessOracleConfiguration` accepts `REPOPROMPT_ORACLE_TIMEOUT_SECONDS` as an integer 1...600 (default 120). Explicit `REPOPROMPT_ORACLE_ENDPOINT` + both model variables override the OpenCode Go fallback; `OPENCODE_API_KEY` alone selects `deepseek-v4-flash` for both lanes.
- `docs/architecture/portable-oracle-mcp.md` is the authoritative privacy/tool contract. `docs/plans/portable-builder-cli-parity-2026-07-23.md` documents the dirty builder/CLI implementation already present and its verification surface.
- `benchmarks/p-limit-portable.json` is the immutable legacy baseline. It embeds the six pinned p-limit source files and both old plan responses, demonstrating why pair completion alone does not prove implementation quality.
</architecture>

<selected_context>
repoprompt-portable/benchmarks/run_portable_benchmark.py: Complete current harness; exact CLI, Docker command, selection, call order, output schema, pinned task and file set.
repoprompt-portable/benchmarks/p-limit-portable.json: Full legacy artifact with pinned p-limit implementation/types/tests/docs/package and both plan lane outputs; retain unchanged as baseline evidence.
repoprompt-portable/Scripts/portable_oracle_mcp_smoke.py: Reusable stdio client and exact builder/pair envelope assertions already proven against a fixture.
repoprompt-portable/Scripts/smoke_portable_oracle_docker.sh: Safe Docker environment-forwarding pattern, explicit Oracle timeout example, fixture setup, image build/run behavior.
repoprompt-portable/docs/architecture/portable-oracle-mcp.md: Current portable tool, provider, timeout, privacy, stateless-review, and unsupported-write contracts.
repoprompt-portable/docs/plans/portable-builder-cli-parity-2026-07-23.md: Existing dirty-worktree design contract and verification commands for direct builder plan/review support.
repoprompt-portable/RepoPromptHeadless/HeadlessToolCatalog.swift: Full tool schema and implementations for selection, direct builder modes, Oracle execution, pair/lane JSON serialization, and errors.
repoprompt-portable/RepoPromptHeadless/HeadlessOracleWorkflow.swift: Full mandatory two-lane execution, statuses, shared prompt, model attribution, and mode-specific system prompts.
repoprompt-portable/RepoPromptHeadless/HeadlessOracleConfiguration.swift: Full environment resolution and timeout/model validation.
repoprompt-portable/RepoPromptHeadlessTests/RepoPromptHeadlessCatalogOracleTests.swift: Exact expected direct plan/review envelope, Primary-projection behavior, partial failure semantics, immutable shared context, and forbidden fields.
repoprompt-portable/RepoPromptHeadlessTests/RepoPromptHeadlessOracleConfigurationTests.swift: Exact timeout and provider-route configuration expectations.
repoprompt-portable/README.md, Dockerfile.headless, opencode.docker.json: Current packaged image usage and model/image defaults relevant to provenance and any manual benchmark documentation.
repoprompt-portable/.gitignore: Current minimal ignores; useful when deciding where isolated copies/artifacts may live without disturbing the repo.
repoprompt-portable/prompt-exports/oracle-plan-2026-07-24-081740-chat-387f.md (lines 1-75 only): Earlier discovery summary and unresolved boundary questions; prior Oracle implementation proposals intentionally excluded.
</selected_context>

<relationships>
- benchmark Python → `StdioMCPClient` → Docker `repoprompt-headless` → MCP `manage_selection(set)` → `HeadlessToolCatalog.context_builder(plan|review)` → `executeOracle` → `HeadlessOracleWorkflow` → concurrent Primary/Secondary provider requests.
- Selection is process-local. Plan and review can use separate container/MCP sessions, but each must select its own intended files before the builder call.
- Plan output exposes both raw lane responses under `oracle_results`; the harness must define a deterministic apply-lane policy and retain both outputs. Do not treat top-level Primary projection as lane agreement.
- Applying natural-language output is outside all seven portable tools. The plan must define a bounded, explicit external apply interface that receives only the chosen plan and isolated p-limit path, and fails closed when unavailable or unsuccessful.
- Objective validation is external to portable: derive a real changed-file list/diff from the isolated copy, run the repository's own `npm test` script (`xo && ava && tsd` per the embedded package), and capture bounded test evidence.
- Review quality depends on selection: select changed post-apply source plus concrete diff/test/apply/provenance evidence, because builder review does not generate a diff itself.
- Python stdio timeout and provider HTTP timeout are separate. The container must receive `REPOPROMPT_ORACLE_TIMEOUT_SECONDS`; artifacts/scoreboard must record both effective values along with image identity and actual returned lane model IDs.
- `pair_status == completed` means both calls completed, not that reviewers agree. Agreement needs an explicit machine-parseable review rubric/verdict from both independent lane responses plus passing objective gates.
</relationships>

<worktree_state>
- RepoPrompt reports `repoprompt-portable` on `main` with 13 modified and 7 untracked entries at status level; the expanded uncommitted diff spans 41 paths. These are user-owned, including the benchmark files, builder/CLI implementation, docs, and prior prompt export.
- `repoprompt-ce` also has unrelated untracked files and is out of scope.
- The scoreboard path does not currently exist. The plan must preserve previous rows byte-for-byte and specify safe append/locking or exclusive campaign behavior; never rewrite historical entries.
</worktree_state>

<ambiguities>
- No live p-limit checkout is loaded in this workspace; only the six-file pinned baseline is embedded in JSON. Specify deterministic acquisition/commit verification and isolation, including dependency installation behavior, without assuming an existing clean local clone.
- “Apply the chosen plan” has no built-in mechanism and no lane preference was supplied. Define the minimal external adapter/command contract and deterministic Primary-then-Secondary (or other clearly justified) selection policy; retain attribution and never synthesize lane plans silently.
- “Both lanes agree” has no product field. Define a strict parseable review response format and agreement rule that also requires apply success and `npm test` success; distinguish terminal pair completion from semantic agreement.
- Decide whether to evolve the existing script or add one small companion harness/test module. Favor the fewest files that still permit local deterministic unit tests of envelope validation, verdict parsing, append-only scoreboarding, and command failure behavior without live credentials/Docker.
- The pinned baseline artifact does not reveal whether the actual commit has a lockfile. The implementation plan should require inspecting the acquired tree and using its native lockfile-faithful install command rather than guessing.
</ambiguities>

## Selection
- Files: 16 total (15 full, 1 slice)
- Total tokens: 56191 (Auto view)
- Token breakdown: full 53211, slice 2980

### Files
### Selected Files
/Users/danielsivan/dev/repoprompt-portable/
├── RepoPromptHeadless/
│   ├── HeadlessOracleConfiguration.swift — 1,101 tokens (full)
│   ├── HeadlessOracleWorkflow.swift — 1,438 tokens (full)
│   └── HeadlessToolCatalog.swift — 10,705 tokens (full)
├── RepoPromptHeadlessTests/
│   ├── RepoPromptHeadlessCatalogOracleTests.swift — 4,824 tokens (full)
│   └── RepoPromptHeadlessOracleConfigurationTests.swift — 920 tokens (full)
├── Scripts/
│   ├── portable_oracle_mcp_smoke.py — 2,805 tokens (full)
│   └── smoke_portable_oracle_docker.sh — 1,510 tokens (full)
├── benchmarks/
│   ├── p-limit-portable.json — 21,046 tokens (full)
│   └── run_portable_benchmark.py — 802 tokens (full)
├── docs/
│   ├── architecture/
│   │   └── portable-oracle-mcp.md — 2,173 tokens (full)
│   └── plans/
│       └── portable-builder-cli-parity-2026-07-23.md — 4,414 tokens (full)
├── prompt-exports/
│   └── oracle-plan-2026-07-24-081740-chat-387f.md — 2,980 tokens (lines 1-75 (Prior discovery handoff only: benchmark gaps, architecture call chain, relevant file roles, relationships, and unresolved apply/agreement/scoreboard ambiguities; excludes prior Oracle solution responses.))
├── .gitignore — 16 tokens (full)
├── Dockerfile.headless — 681 tokens (full)
├── README.md — 628 tokens (full)
└── opencode.docker.json — 148 tokens (full)



---

## Generated Plan


## Oracle Pair
- **Status**: completed
- **Execution scope**: Primary + Secondary consultation
- **Decision policy**: `caller_decides` — Consult both responses. Primary is the trusted/default baseline; Secondary is an independent critique with lower default priority. The caller compares both and makes the final decision — incorporate useful Secondary suggestions, or substitute the Secondary approach where it is better supported. Before finalizing, acknowledge consideration of both exact outcomes with oracle_utils op=acknowledge. RepoPrompt performs no automatic synthesis, ranking, or winner selection.
- **Pair ID**: `5B5280B7-5257-4D8D-9D0A-F1E233E480C6`
- **Primary chat**: `portable-benchmark-harde-ADAA5E`
- **Secondary chat**: `portable-benchmark-harde-8181D4`
- **History diverged**: false
- **Turn counts**: Primary 1, Secondary 1
- **Outcome digests**: Primary `h:825b107c41209b21`, Secondary `h:90100ed938b0fcff`
- **Consideration acknowledgement required**: call `oracle_utils` with `op=acknowledge`, this pair ID, both outcome digests, and `considered_lanes=["primary","secondary"]` before finalizing.
- **Input context diverged**: false

### Primary Oracle — trusted/default baseline
- **Status**: completed
- **Model**: Custom/gpt-5.6-sol-pro
- **Model ID**: `custom_provider_gpt-5.6-sol-pro`
- **Chat**: `portable-benchmark-harde-ADAA5E`
- **Full chat ID**: `ADAA5E3D-AB32-4F0F-9430-16842496D771`
- **Context ID**: `57262535-8254-44F2-8409-0EF33EF16E4D`

#### Requested route
- Provider: Custom (`customProvider`)
- Backend: `CustomOpenAIProvider`
- Model: Custom/gpt-5.6-sol-pro
- Raw model ID: `custom_provider_gpt-5.6-sol-pro`
- Runtime model ID: `gpt-5.6-sol-pro`
- Execution mode: `standard`

#### Response
:::writing{variant="document" id="48217"}
# 1. Summary

Implement this as a **targeted benchmark-only refactor**, not a production workflow change. Expand `benchmarks/run_portable_benchmark.py` into a bounded, sequential quality-loop harness that calls `context_builder(plan)` and `context_builder(review)` directly, validates both Oracle lanes and the Primary projection contract, selects Primary when completed or Secondary otherwise, passes only that selected plan to an external apply adapter operating on a fresh isolated clone of pinned p-limit commit `df476048d023ff868cd45b35ee47f5fb0ca2b25a`, runs the lockfile-faithful dependency install and exact `npm test`, and reviews the cumulative implementation together with an actual Git diff and command provenance. Add one standard-library Python test module for the pure validation, verdict, command, and append-only persistence logic, and add the append-only scoreboard scaffold. Do not modify Swift production code unless the new harness captures a reproducible violation of the documented `context_builder` envelope; such a violation terminates the campaign as a product-contract defect rather than being repaired implicitly by the benchmark.

# 2. Current-state analysis

## Existing responsibilities and control flow

`benchmarks/run_portable_benchmark.py` currently owns the live benchmark orchestration:

1. It accepts a p-limit workspace path, image reference, output path, and Python-side stdio timeout.
2. It starts one Docker container running `repoprompt-headless` with the supplied workspace mounted read-only at `/workspace`.
3. It initializes MCP through `StdioMCPClient`.
4. It calls `manage_selection(set)` for six files.
5. It calls provider-free `context_builder(clarify)`.
6. It separately calls `oracle_send(plan)`.
7. It closes the MCP process and overwrites the requested JSON output.

That flow proves selected source reaches the portable server, but it does not exercise the builder’s provider-backed modes, does not choose or apply a lane, does not execute the target repository’s tests, and never gives either review lane the resulting implementation or diff.

`Scripts/portable_oracle_mcp_smoke.py` already provides the reusable protocol layer:

- `StdioMCPClient` owns the Docker subprocess, JSON-RPC request IDs, stdout parsing, per-response deadlines, and process shutdown.
- `rpc_result` validates JSON-RPC success envelopes.
- `tool_json` validates MCP tool success and decodes its textual JSON object.
- `nested_keys` supports recursive forbidden-field assertions.

The benchmark should continue importing these helpers. It should not introduce a second MCP client or JSON-RPC decoder.

`RepoPromptHeadless/HeadlessToolCatalog.swift` is the actual portable tool boundary:

- `manage_selection` mutates the process-local `WorkspaceSelectionStateStore`.
- `context_builder(clarify)` snapshots selection and builds context locally.
- `context_builder(plan|review)` calls the shared `executeOracle` path, then adds builder-only `response_type`, `prompt`, and `status` fields to the ordinary pair envelope.
- `oracle_send` uses the same `executeOracle` and `pairJSON` functions but lacks builder metadata.

The resulting pair contract is asymmetric by design:

- `oracle_results.primary` and `oracle_results.secondary` always represent their fixed lanes.
- `pair_status` describes the two terminal lane statuses.
- Top-level `ok`, `response`, `error`, and `model_raw_id` project Primary only.
- Secondary is never promoted to the top level, even when Primary fails and Secondary completes.
- `oracle_decision_policy` is `caller_decides`.

`RepoPromptHeadless/HeadlessOracleWorkflow.swift` takes one immutable `HeadlessWorkspaceContext`, constructs one shared user prompt, and dispatches Primary and Secondary concurrently with `async let`. The benchmark must not infer lane order from completion order; it must address the lanes by their named envelope keys.

`RepoPromptHeadless/HeadlessOracleConfiguration.swift` separates provider timeout from the Python stdio timeout:

- `REPOPROMPT_ORACLE_TIMEOUT_SECONDS` controls each provider HTTP request and must be an integer from 1 through 600.
- `StdioMCPClient.timeout` controls how long the Python process waits for a JSON-RPC response.
- Explicit endpoint plus both model variables override the `OPENCODE_API_KEY` fallback.
- The image’s `opencode.docker.json` is not used by `HeadlessOracleConfiguration` and must not be treated as provider provenance.

## Current data and mutation boundaries

The source p-limit workspace is presently mounted directly and read-only. Portable itself has no write, apply, Git, diff, test, or export tool, so all implementation mutation must remain outside MCP.

The requested quality loop therefore has four distinct ownership domains:

1. **User/source p-limit repository:** read-only input and commit-object source. It may be dirty and must remain byte-for-byte untouched.
2. **Harness-owned iteration clone:** the only writable p-limit tree. The apply adapter and test commands run here.
3. **Portable Docker process:** sees the iteration clone and generated evidence directory only through read-only mounts.
4. **Benchmark artifacts and scoreboard:** written by the harness outside the p-limit tree.

The existing JSON artifact `benchmarks/p-limit-portable.json` is legacy evidence. It must remain unchanged and must not be reused as the new output path.

## Reusable extension points

The implementation should reuse:

- `StdioMCPClient`, `rpc_result`, `tool_json`, and `nested_keys`.
- Existing `manage_selection` and direct `context_builder(plan|review)` calls.
- The documented two-lane envelope rather than inventing a synthesized result.
- Git’s index to distinguish the prior cumulative implementation from the current iteration’s newly applied delta.
- The target repository’s own `package.json` test script, invoked through exact `npm test`.

## Blocking gaps

The current script lacks:

- A direct builder-call wrapper that starts a fresh MCP process, selects the intended files, and validates builder metadata and both lane envelopes.
- A deterministic lane-selection policy independent of the Primary projection.
- A bounded external apply interface.
- An isolated and recoverable iteration state model.
- Lockfile detection and test execution.
- Actual diff and test evidence supplied to `context_builder(review)`.
- A machine-parseable review verdict.
- Append-only per-iteration persistence.
- Effective provider timeout propagation and immutable image identification.
- Tests for the benchmark logic itself.

## Targeted change versus broader refactor

Use a targeted refactor of the benchmark script plus one Python test file. The portable server already exposes the required plan/review behavior, immutable selection snapshot, concurrent fixed lanes, and stable envelope. Adding production services, write tools, Git support, durable campaign state, or a generalized workflow framework would duplicate existing host capabilities and violate portable’s read-only contract.

# 3. Design

## 3.1 Campaign entry point and internal state

### Command-line interface

Preserve the existing invocation shape and add only the controls needed for the quality loop.

Before:

```text
run_portable_benchmark.py
  --workspace PATH
  [--image IMAGE]
  --output FILE
  [--timeout-seconds FLOAT]
```

After:

```text
run_portable_benchmark.py
  --workspace PATH
  [--image IMAGE]
  --output FILE
  --apply-command JSON_ARGV
  [--scoreboard FILE]
  [--max-iterations 1...5]
  [--timeout-seconds FLOAT]
  [--oracle-timeout-seconds 1...600]
  [--command-timeout-seconds FLOAT]
```

Resolved semantics:

| Argument | Required behavior |
|---|---|
| `--workspace` | Existing local Git repository containing the pinned commit object. It may be dirty or checked out at another revision. The harness never mounts or modifies this path. |
| `--image` | Requested image reference. Resolve it once with `docker image inspect`, then run every container by the returned immutable image ID. |
| `--output` | Final campaign JSON. Refuse to start if this path or its derived sidecar directory already exists. Explicitly reject `benchmarks/p-limit-portable.json`. |
| `--apply-command` | JSON array of one or more non-empty argv strings. No shell parsing. The harness appends `--workspace <iteration-path>` and supplies the exact selected plan on stdin. |
| `--scoreboard` | Default: `prompt-exports/optimize-portable-plan-review-runs.md` relative to the RepoPrompt Portable repository root. |
| `--max-iterations` | Default `5`; reject values outside `1...5`. |
| `--timeout-seconds` | Python/MCP response deadline. Preserve default `300`. Require it to be at least the effective Oracle timeout plus 30 seconds. |
| `--oracle-timeout-seconds` | CLI value wins; otherwise use the existing environment value; otherwise use `120`. Always pass the resolved value into Docker. |
| `--command-timeout-seconds` | Shared upper bound for Git acquisition, apply, dependency installation, and `npm test`. Default `900`; reject non-positive values. |

The process exit contract is:

- `0`: a complete iteration satisfies every objective gate and both review lanes approve.
- `1`: the campaign reaches its iteration limit without agreement or only encounters ordinary plan/apply/test/review failures.
- `2`: invalid invocation or preflight failure before an iteration starts.
- `70`: a documented portable envelope contract is violated, artifact persistence fails, or the supposedly read-only source repository changes.
- `130`: user interruption after terminating the current child process/container and persisting the partial iteration where possible.

### Internal types

Keep these as private dataclasses or immutable records inside `benchmarks/run_portable_benchmark.py`; do not create a framework package.

Illustrative shapes:

```py
LaneEnvelope:
    lane: "primary" | "secondary"
    status: "completed" | "failed"
    model_raw_id: str
    response: str | None
    error: dict | None

BuilderEnvelope:
    response_type: "plan" | "review"
    pair_id: str
    pair_status: "completed" | "partial_failure" | "failed"
    primary: LaneEnvelope
    secondary: LaneEnvelope
    workspace_context: dict
    raw: dict

CommandResult:
    status: "completed" | "failed" | "timed_out"
    argv_fingerprint: str
    exit_code: int | None
    duration_ms: int
    stdout: bytes
    stderr: bytes

ReviewVerdict:
    verdict: "approve" | "changes_required"
    workflow_correct: bool
    implementation_correct: bool
    test_evidence_sufficient: bool
    findings: list[ReviewFinding]
```

Required pure interfaces:

```py
validate_builder_envelope(
    payload,
    *,
    expected_response_type,
    expected_prompt,
    expected_selected_paths,
) -> BuilderEnvelope

choose_plan_lane(builder: BuilderEnvelope) -> LaneEnvelope

parse_review_verdict(response: str) -> ReviewVerdict

is_iteration_agreed(iteration_record) -> bool

append_scoreboard_record(path, record) -> None
```

All validation helpers raise a benchmark-specific exception carrying a list of concrete defects rather than a generic assertion message.

### Campaign algorithm

The loop is deliberately sequential:

```text
preflight source, image, provider configuration, output paths, adapter
previous cumulative patch := none
previous feedback := none

for iteration 1...max:
    create fresh isolated clone at pinned commit
    apply previous cumulative patch to Git index and worktree
    generate/select plan-feedback.md
    call context_builder(plan)
    validate both lanes and select one completed plan
    invoke apply adapter with only selected plan + isolated path
    validate and stage iteration delta
    install dependencies using detected lockfile
    run npm test
    generate review-evidence.md
    call context_builder(review)
    validate both lanes and parse both verdicts
    persist iteration artifacts and append one scoreboard row
    if all objective gates and both verdicts approve:
        stop successfully
    otherwise:
        carry the staged cumulative patch and parsed findings forward

stop after five attempts
```

A downstream stage is marked `not_run` only when an upstream prerequisite failed. Such an attempt still receives an iteration record and scoreboard row.

## 3.2 Provider and image provenance

### Provider route resolution

Mirror `HeadlessOracleConfiguration.resolve` closely enough to detect configuration mistakes before starting Docker:

1. Read `REPOPROMPT_ORACLE_ENDPOINT`, `REPOPROMPT_ORACLE_PRIMARY_MODEL`, and `REPOPROMPT_ORACLE_SECONDARY_MODEL`.
2. If any is present, require all three to be non-empty and classify the route as `explicit`.
3. Otherwise require non-empty `OPENCODE_API_KEY` and classify the route as `opencode_go_default`.
4. Resolve and validate the effective Oracle timeout.
5. Do not inspect or copy `opencode.docker.json`.
6. Forward credentials with Docker’s `--env NAME` form, never `--env NAME=value`.
7. Pass the non-secret timeout explicitly as `--env REPOPROMPT_ORACLE_TIMEOUT_SECONDS=<effective>`.

For the explicit route, forward only:

- `REPOPROMPT_ORACLE_ENDPOINT`
- `REPOPROMPT_ORACLE_PRIMARY_MODEL`
- `REPOPROMPT_ORACLE_SECONDARY_MODEL`
- `REPOPROMPT_ORACLE_API_KEY` when present

For the fallback route, forward only:

- `OPENCODE_API_KEY`

Do not forward fallback credentials alongside an explicit configuration; that removes ambiguity about the route actually used.

### Image identity

Before the first iteration:

1. Require `docker image inspect <requested-ref>` to succeed.
2. Record:
   - requested reference;
   - immutable image ID;
   - sorted repository digests;
   - OS and architecture.
3. Run every plan/review container with the immutable image ID, not the mutable tag.

The harness does not automatically pull or rebuild the image. Image acquisition remains an explicit caller action.

### Model provenance

The authoritative model provenance comes from each validated lane’s `model_raw_id`, not from the input environment.

Record:

- configured model names when the explicit route exposes them;
- actual plan Primary and Secondary model IDs;
- actual review Primary and Secondary model IDs;
- whether each lane’s model ID remained stable between plan and review.

A mismatch between plan and review model IDs for the same fixed lane is a provenance defect and prevents agreement.

### Secret handling

Artifacts and scoreboard rows must never contain credential values.

- Record credential presence as booleans only.
- Record the explicit endpoint as a SHA-256 fingerprint plus URL scheme, not the full URL.
- Record the apply argv as executable basename plus a SHA-256 fingerprint of the serialized argv, not the full argument list.
- Before writing command stdout/stderr, replace exact occurrences of known Oracle credential values with `[REDACTED]`.
- Do not include inherited environment dumps in any artifact.
- Remove all RepoPrompt/OpenCode provider variables from the apply adapter environment because the adapter does not need the Oracle credentials.

## 3.3 Source acquisition and writable iteration isolation

### Source preflight

`--workspace` remains a local repository path. It does not need to be clean.

Before creating any campaign files:

1. Resolve the path without following it into the output or temporary campaign directory.
2. Require it to be readable by Git.
3. Require `git cat-file -e df476048d023ff868cd45b35ee47f5fb0ca2b25a^{commit}` to succeed.
4. Capture:
   - current `HEAD`, if any;
   - exact `git status --porcelain=v1 -z --untracked-files=all` bytes;
   - SHA-256 of that status;
   - count of status entries.
5. Never invoke checkout, reset, clean, restore, stash, add, or commit in this repository.

At campaign end, recalculate the same source status and `HEAD`. Any difference is a fatal isolation failure. The harness reports it but does not attempt repair.

### Base clone

Create a harness-owned temporary campaign directory outside both the RepoPrompt Portable repository and source p-limit repository.

Clone from the source repository using an independent object store, then check out the pinned commit detached:

```text
source repository
    → independent base clone
    → verified detached HEAD at pinned commit
```

The clone operation must disable local hardlink reuse. Verify:

- `HEAD` equals the full pinned commit;
- the base clone is clean;
- the five implementation target files and `package.json` exist;
- its root and evidence directories are traversable by the Docker image’s non-root UID.

Do not use Git worktrees because `git worktree add` mutates metadata in the source repository.

### Fresh clone per iteration

Each iteration starts from a fresh independent clone of the verified base clone. This quarantines partial adapter changes and removes the need for destructive cleanup commands.

For iteration 1, the Git index and worktree equal the pinned commit.

For iteration N greater than 1:

1. Apply the previous iteration’s cumulative binary patch with `git apply --index`.
2. Verify the resulting staged patch SHA-256 and changed-file set match the prior iteration record.
3. Leave the prior cumulative implementation staged.
4. Any new adapter edits therefore appear as an unstaged delta relative to the prior implementation.

This index discipline gives three unambiguous views:

- `git diff`: changes introduced only by the current selected plan.
- `git diff --cached HEAD`: cumulative implementation relative to the pinned commit.
- `git status --porcelain`: out-of-scope or untracked mutations.

No reset, clean, restore, or checkout is needed after a failed iteration; its directory is simply excluded from the next iteration.

### Allowed and required paths

The plan and review context includes all six benchmark files:

```text
index.js
index.d.ts
index.test-d.ts
test.js
readme.md
package.json
```

The apply adapter may modify only:

```text
index.js
index.d.ts
index.test-d.ts
test.js
readme.md
```

`package.json` is context-only for this task and must remain unchanged.

Per iteration:

- the newly applied unstaged delta must be non-empty;
- every changed or untracked path must be within the five-file allowlist;
- any out-of-scope path invalidates the apply attempt and prevents patch advancement.

For final agreement, the cumulative changed-file set must include all five required files. An intermediate iteration may legitimately touch only a subset while repairing a prior implementation.

## 3.4 Direct `context_builder(plan)` execution

### MCP process lifecycle

Use a new MCP process for every builder call. This prevents stale process-local selection and guarantees the review call sees files after the host-side apply and test stages.

Each process receives two read-only mounts and two roots:

```text
iteration worktree → /workspace, readonly, root[0]
evidence directory → /evidence, readonly, root[1]
```

Docker arguments include:

```text
--no-persist
--root /workspace
--root /evidence
```

Assign each container a unique campaign/iteration/call name. Close stdin and wait through `StdioMCPClient.close_and_wait()` in a `finally` block. On timeout or abnormal exit, issue a best-effort `docker rm -f <name>` so no container remains.

The host harness is single-threaded. The only concurrency remains the existing `HeadlessOracleWorkflow` Primary/Secondary `async let` pair inside the Swift process.

### Plan feedback selection

Before the plan call, write `plan-feedback.md` in the evidence directory.

Iteration 1 contains:

- pinned task text;
- pinned repository and commit;
- statement that no previous implementation attempt exists;
- required output scope and five-file mutation allowlist.

Later iterations contain only bounded, structured prior evidence:

- prior selected plan lane, model ID, and response hash;
- apply status and changed files;
- install and `npm test` status;
- both parsed review verdicts and all findings;
- review-format or provider-lane failures;
- any objective-gate failure.

Do not include secret values or raw unbounded logs. The current implementation itself is already selected from the worktree.

Select exactly:

```text
root[0]:index.js
root[0]:index.d.ts
root[0]:index.test-d.ts
root[0]:test.js
root[0]:readme.md
root[0]:package.json
root[1]:plan-feedback.md
```

Call:

```text
context_builder {
  "instructions": <iteration-specific task and correction request>,
  "response_type": "plan",
  "max_context_bytes": 1048576
}
```

Do not call `context_builder(clarify)` or `oracle_send` anywhere in the new campaign path.

### Builder envelope validation

`validate_builder_envelope` must validate all of the following before lane selection:

1. Builder metadata:
   - `response_type` equals the requested `plan` or `review`;
   - `prompt` equals the exact trimmed instructions;
   - `status` is `response_generated` exactly when Primary completed, otherwise `response_failed`.

2. Pair metadata:
   - `oracle_pair_id` parses as a UUID;
   - `oracle_decision_policy == "caller_decides"`;
   - `pair_status` is one of the three documented values;
   - `oracle_results` contains both `primary` and `secondary`.

3. Lane identity:
   - each lane object’s `oracle_lane` matches its containing key;
   - `provider == "openai_compatible"`;
   - `model_raw_id` is a non-empty string;
   - status is `completed` or `failed`.

4. Lane payload consistency:
   - completed lane: non-empty `response`, no `error`;
   - failed lane: structured `error`, no `response`.

5. Pair-status consistency:
   - both completed → `completed`;
   - exactly one completed → `partial_failure`;
   - neither completed → `failed`.

6. Primary projection:
   - top-level `model_raw_id` equals Primary’s model ID;
   - top-level `ok` is true exactly when Primary completed;
   - Primary completed → top-level `response` exactly equals Primary response and top-level `error` is absent;
   - Primary failed → top-level `response` is absent and top-level `error` equals Primary error.

7. Context completeness:
   - `workspace_context.truncated == false`;
   - `workspace_context.omissions` is empty;
   - selected paths and context entry paths equal the requested selection set;
   - all selected evidence files are represented.

8. Forbidden state:
   - no key anywhere in the result is named `chat_id`, `new_chat`, `oracle_export_path`, `winner`, or `synthesis`.

A violation is a product-contract defect. Persist the raw payload, append a defect row, stop the campaign, and exit `70`. Do not compensate by normalizing malformed output.

### Deterministic plan selection

After a valid plan envelope:

1. Select Primary when `primary.status == "completed"`.
2. Otherwise select Secondary when `secondary.status == "completed"`.
3. If neither completed, mark apply/test/review `not_run` and continue to the next iteration.

The selected plan bytes are exactly the selected nested lane response. Never use the top-level `response` as the selection source, never combine the lanes, and never ask another model to synthesize them.

Persist both raw responses and record:

- selected lane;
- selected model ID;
- selection reason (`primary_preferred` or `primary_failed_secondary_completed`);
- SHA-256 of the exact plan bytes passed to the adapter.

A partial plan pair may be used to obtain additional implementation evidence, but it is a provider defect and cannot satisfy the final workflow-correctness gate.

## 3.5 External apply adapter

### Interface contract

The apply adapter is intentionally external because portable has no write tools.

Parse `--apply-command` as a JSON array of argv tokens. Invoke without a shell:

```text
<configured argv...> --workspace <absolute iteration worktree>
```

Execution contract:

- current working directory: iteration worktree;
- stdin: exact selected plan UTF-8 bytes plus one terminating newline;
- stdout/stderr: captured separately;
- timeout: `--command-timeout-seconds`;
- RepoPrompt/OpenCode provider variables removed from its environment;
- source p-limit path, unselected lane response, evidence directory, and RepoPrompt dirty-worktree path are not passed.

Exit code `0` is only the adapter’s claim of success. The harness independently validates the Git delta.

Use a process group for host commands. On timeout:

1. terminate the group;
2. allow a short fixed grace period;
3. kill the group if still running;
4. record `timed_out`;
5. retain the partial diff as evidence;
6. do not advance the cumulative patch.

### Post-apply validation

Immediately after adapter exit:

- Capture the unstaged iteration delta and full `git status`.
- Record the diff even when the adapter failed.
- Require exit code `0`.
- Require a non-empty delta.
- Require every changed or untracked path to be within the allowlist.
- Require the local source repository’s status snapshot to remain unchanged.

If valid, stage only the five allowed paths. Then capture:

- iteration delta patch;
- cumulative binary patch relative to pinned `HEAD`;
- cumulative changed-file list;
- byte counts and SHA-256 hashes.

If invalid, quarantine this iteration and seed the next iteration from the previous cumulative patch, not from the failed working directory.

## 3.6 Dependency installation and `npm test`

### Lockfile-faithful install selection

Inspect the acquired tree after the valid cumulative patch is staged. Do not infer the package manager from the legacy JSON artifact.

Supported resolution:

| Detected metadata | Install command |
|---|---|
| `npm-shrinkwrap.json` or `package-lock.json` | `npm ci --no-audit --no-fund` |
| `pnpm-lock.yaml` plus compatible `packageManager` declaration | `corepack pnpm install --frozen-lockfile` |
| `yarn.lock` plus compatible `packageManager` declaration | Yarn v1 `--frozen-lockfile` or modern Yarn `--immutable`, selected from the declared version |

Fail the iteration before testing when:

- no supported lockfile exists;
- more than one package-manager family is present;
- the lockfile contradicts `package.json.packageManager`;
- the required package-manager executable is unavailable.

Do not fall back to an unlocked `npm install`; that would make dependency resolution dependent on current registry state.

Record the detected lockfile, package-manager declaration, exact non-secret command, command version, exit status, duration, and sanitized log hashes/tails.

After installation, require the staged cumulative patch to be unchanged and require no new tracked or unignored files. Dependency installation is not allowed to modify the benchmark implementation.

### Test execution

Run exactly:

```text
npm test
```

from the iteration worktree, with `CI=1` and `NO_COLOR=1`.

Capture:

- exit code or timeout;
- duration;
- full sanitized stdout/stderr sidecars;
- SHA-256 and byte count for each stream;
- bounded tails for review evidence.

After the command, verify that:

- the staged cumulative patch hash is unchanged;
- no unstaged tracked change or unexpected untracked file appeared.

A test failure does not suppress review. The review lanes need the failure evidence to produce the next iteration’s correction plan. Test-generated source mutations, however, invalidate the iteration state; do not advance that patch or review an ambiguous working tree.

## 3.7 Direct `context_builder(review)` execution

### Review evidence file

Create `review-evidence.md` in the separate evidence root after apply/install/test.

It must contain:

1. Original task and pinned commit.
2. Campaign and iteration IDs.
3. Immutable image ID and repository digest where available.
4. Provider route, effective Oracle timeout, Python stdio timeout, and command timeout.
5. Plan pair status, both lane statuses and model IDs, selected lane, and selected-plan hash.
6. Apply adapter status, duration, executable basename, argv fingerprint, and sanitized log tails.
7. Iteration delta changed files.
8. Cumulative changed files and required-file coverage.
9. Full cumulative Git diff when within the evidence budget.
10. Dependency-install command, lockfile, status, and bounded logs.
11. Exact `npm test` status and bounded logs.
12. SHA-256, byte count, and sidecar path for every full diff/log omitted or truncated.
13. Results of the harness’s structural envelope checks.

Use a fixed maximum evidence size of 256 KiB:

- Reserve up to 160 KiB for the cumulative diff.
- If the diff exceeds that limit, include deterministic head and tail slices, its full hash and byte count, and an explicit truncation marker.
- Use bounded tails for command logs.
- Never silently truncate.

Select the same six p-limit files plus:

```text
root[1]:review-evidence.md
```

Call `context_builder` with `response_type: "review"` and the same 1 MiB context limit. Validate the complete builder envelope using the same helper as the plan call.

### Machine-parseable review contract

The review instructions require each lane to end with exactly one final non-empty line:

```text
PORTABLE_REVIEW_VERDICT: <compact JSON object>
```

The JSON shape is:

```text
verdict: "approve" | "changes_required"
workflow_correct: boolean
implementation_correct: boolean
test_evidence_sufficient: boolean
findings: array of {
    category:
        "workflow" | "provider" | "runtime" | "types" |
        "tests" | "documentation" | "provenance",
    summary: non-empty string,
    evidence: non-empty string
}
```

Parser rules:

- There must be exactly one verdict-prefixed line.
- It must be the final non-empty line.
- The suffix must be a JSON object with exactly the documented top-level keys.
- Every finding must have exactly the documented keys and a valid category.
- `approve` is valid only when all three booleans are true and `findings` is empty.
- `changes_required` must have at least one false boolean or at least one finding.
- Malformed or internally contradictory output is a `review_format` defect and cannot count as agreement.

The raw lane response is always retained, even when its verdict cannot be parsed.

## 3.8 Agreement and iteration advancement

A campaign stops successfully only when one complete iteration satisfies all of these gates:

1. Plan builder envelope valid.
2. Plan pair has both lanes completed.
3. Deterministic selected plan applied successfully.
4. Iteration delta is non-empty and in scope.
5. Cumulative diff includes all five required target files.
6. Dependency installation succeeded without source mutations.
7. Exact `npm test` exited `0` without source mutations.
8. Review builder envelope valid.
9. Review pair has both lanes completed.
10. Primary review verdict is valid `approve`.
11. Secondary review verdict is valid `approve`.
12. Both review verdicts report:
    - `workflow_correct == true`;
    - `implementation_correct == true`;
    - `test_evidence_sufficient == true`;
    - no findings.
13. Plan and review model IDs are stable for each fixed lane.
14. No structural, provider, apply, diff-scope, test, provenance, or persistence defect remains in the iteration.

`pair_status == "completed"` alone never counts as agreement.

When agreement is not reached but a valid cumulative patch exists, carry that patch forward to the next fresh iteration. Generate the next `plan-feedback.md` from:

- both review findings or parse failures;
- failed objective gates;
- test/install errors;
- provider-lane failures;
- current cumulative changed-file coverage.

After iteration 5, stop with `success: false` and `stop_reason: "max_iterations"`.

## 3.9 Artifacts and append-only scoreboard

### Sidecar layout

For output `PATH/run.json`, derive `PATH/run.artifacts/`. Refuse to start if either exists.

Each iteration directory contains:

```text
iteration-01/
  plan.response.json
  plan.primary.md
  plan.secondary.md
  selected-plan.md
  plan-feedback.md
  apply.stdout.log
  apply.stderr.log
  iteration-delta.patch
  cumulative.patch
  install.stdout.log
  install.stderr.log
  test.stdout.log
  test.stderr.log
  review-evidence.md
  review.response.json
  review.primary.md
  review.secondary.md
  iteration-record.json
```

Only create files through exclusive-create operations. Do not overwrite a partially existing campaign.

### Final JSON schema

Use a new top-level `schema_version: 2`; do not mutate the legacy artifact format.

Required top-level fields:

```text
schema_version
campaign_id
started_at
finished_at
success
stop_reason
benchmark:
    repository
    commit
    task
    selected_paths
provenance:
    image
    provider_route
    endpoint_fingerprint
    configured_models
    effective_oracle_timeout_seconds
    stdio_timeout_seconds
    command_timeout_seconds
    credential_presence
    source_status_before_sha256
    source_status_after_sha256
policy:
    max_iterations
    lane_selection
    allowed_change_paths
    required_final_change_paths
    agreement_rule
artifact_directory
iterations
```

Each iteration record includes:

- stage status for plan, apply, install, test, and review;
- complete pair/lane status and model attribution;
- selected lane and plan hash;
- command exit statuses, durations, log hashes, and artifact paths;
- delta and cumulative changed files;
- diff hashes and byte counts;
- parsed verdicts;
- normalized defect objects;
- agreement boolean.

Use UTC RFC 3339 timestamps and monotonic durations.

### Defect representation

Normalize every observed issue as:

```text
stage: "preflight" | "plan" | "apply" | "install" | "test" | "review" | "persistence"
category: "contract" | "provider" | "scope" | "command" | "code_quality" | "provenance"
lane: "primary" | "secondary" | null
code: stable short identifier
summary: concise non-secret text
```

Raw model responses and command output remain sidecars rather than being duplicated into the final JSON.

### Scoreboard scaffold

Add `prompt-exports/optimize-portable-plan-review-runs.md` with only this header if the path is still absent during implementation:

```md
# Portable plan/review optimization runs

Append-only summary. Full evidence is stored in the referenced campaign artifacts.

| UTC timestamp | Campaign | Iteration | Commit | Image ID | Plan pair | Applied lane/model | Apply | npm test | Review pair | Verdicts P/S | Agreement | Defects | Artifact |
|---|---|---:|---|---|---|---|---|---|---|---|---|---:|---|
```

Runtime append behavior:

1. Open with `O_CREAT | O_WRONLY | O_APPEND`.
2. Acquire an exclusive `fcntl.flock`.
3. When the file is empty, write the scaffold once.
4. Append exactly one escaped table row after each finalized iteration record.
5. Flush and `fsync` before releasing the lock.
6. Never read-modify-write, truncate, replace, sort, or deduplicate historical rows.

Each row contains only concise statuses, short image/hash prefixes, model IDs, defect count, and the campaign artifact reference. Full findings remain in the JSON and lane-response sidecars.

A scoreboard append failure is fatal because the requested audit trail would be incomplete.

## 3.10 Failure, cancellation, and degraded behavior

| Failure | Behavior |
|---|---|
| Invalid arguments, missing apply executable, output collision, image absent, pinned commit absent | Stop before provider work; exit `2`; do not append an iteration row. |
| Provider configuration incomplete or timeout invalid | Stop before Docker; exit `2`; record no secrets. |
| Plan MCP/tool failure | Record iteration defect; downstream stages `not_run`; append row; retry from prior cumulative patch if attempts remain. |
| Valid plan pair with one completed lane | Select completed lane by Primary-first policy; record provider defect; continue, but final agreement is impossible for that iteration. |
| Both plan lanes failed | No apply; append row; retry if attempts remain. |
| Builder envelope contradicts documented contract | Persist raw payload, append contract-defect row, stop immediately with exit `70`. |
| Apply non-zero, timeout, empty diff, or out-of-scope diff | Quarantine iteration clone; retain partial logs/diff; do not advance cumulative patch. |
| Dependency install failure | Record failure; run review over the changed implementation and failure evidence when the worktree remains unambiguous; no agreement. |
| `npm test` failure | Run review with test evidence; carry valid cumulative patch forward for repair. |
| Test mutates source files | Mark iteration invalid, skip review of the ambiguous tree, and do not advance the patch. |
| Review lane failure or malformed verdict | Record provider/format defect; no agreement; carry valid cumulative patch forward. |
| Keyboard interrupt | Terminate current process group/container, persist partial evidence, append a partial row when an iteration exists, exit `130`. |
| Source repository status changes | Stop with exit `70`; never repair or revert the source repository. |

# 4. File-by-file impact

## `benchmarks/run_portable_benchmark.py`

### Changes

- Replace the current clarify-plus-`oracle_send(plan)` sequence with the bounded direct plan/apply/test/review campaign.
- Retain imports of `PROTOCOL_VERSION`, `StdioMCPClient`, `rpc_result`, and `tool_json`; add `nested_keys`.
- Add private immutable records for lane, builder, command, verdict, finding, and iteration state.
- Add CLI parsing and validation for the apply adapter, effective Oracle timeout, command timeout, iteration cap, and scoreboard.
- Add image inspection and provider-route preflight.
- Add source snapshot, independent clone, pinned-commit verification, fresh iteration clone, cumulative patch staging, and scope validation.
- Add the direct builder-call helper used identically for plan and review.
- Add strict envelope validation and Primary-first completed-lane selection.
- Add bounded subprocess execution with process-group termination.
- Add lockfile-based dependency install selection and exact `npm test`.
- Add evidence rendering, review-verdict parsing, agreement evaluation, sidecar persistence, and scoreboard append.
- Change output writing from unconditional overwrite to exclusive creation.
- Emit schema version 2 and preserve raw lane responses in sidecars.

### Why

This file already owns the benchmark lifecycle and imports the proven MCP client. Keeping orchestration and pure helper logic here avoids introducing a generalized production workflow or another package.

### Dependencies

- Depends on the unchanged portable builder contract in `HeadlessToolCatalog`.
- Depends on existing `StdioMCPClient` behavior.
- Must land with its unit tests and scoreboard initialization behavior.

## `benchmarks/test_run_portable_benchmark.py` — new

Use `unittest`, `tempfile`, and `unittest.mock`; add no dependency.

Required tests:

1. Valid completed plan pair selects Primary.
2. Primary failed plus Secondary completed selects Secondary while retaining both.
3. Neither lane completed rejects plan selection.
4. Envelope validator rejects:
   - wrong builder `response_type`;
   - inconsistent `pair_status`;
   - wrong lane identity;
   - incorrect Primary projection;
   - missing lane response/error;
   - context truncation or omissions;
   - missing selected entries;
   - forbidden chat/export/winner fields.
5. Review parser accepts the exact verdict schema.
6. Review parser rejects:
   - missing or multiple markers;
   - marker not on final non-empty line;
   - malformed JSON;
   - unknown keys or categories;
   - contradictory `approve` with findings or false booleans.
7. Agreement requires every objective gate, both completed review lanes, and both valid approvals.
8. Plan-pair partial failure, test failure, model mismatch, or any defect prevents agreement.
9. Apply-command JSON parsing rejects scalars, empty arrays, and non-string tokens.
10. Command runner records non-zero exit and kills a timed-out process group.
11. Lockfile selection chooses the correct command and rejects absent, ambiguous, or contradictory lockfiles.
12. Diff-scope validation rejects `package.json` and arbitrary new files.
13. Scoreboard appending:
    - creates the header only once;
    - appends rows without altering prior bytes;
    - escapes table delimiters/newlines;
    - preserves two sequential records.
14. Output preflight rejects an existing JSON file, sidecar directory, or the legacy benchmark path.
15. Secret redaction removes known key values from logs.

### Why

These are deterministic logic boundaries that should not require Docker, provider credentials, Node, or a live p-limit checkout.

### Dependencies

Import the benchmark module directly from the adjacent directory. Tests must not execute `main()`.

## `prompt-exports/optimize-portable-plan-review-runs.md`

### Changes

- Add the header scaffold only when absent.
- Treat all future content after the header as append-only runtime evidence.
- Never rewrite existing rows if the file appears or changes before implementation.

### Why

This is the requested concise cross-run audit trail. Full evidence remains in per-campaign JSON and sidecar artifacts.

### Dependencies

The append helper in `run_portable_benchmark.py` owns locking, escaping, and first-write initialization.

## Explicitly unchanged

- `benchmarks/p-limit-portable.json`: immutable legacy baseline.
- `Scripts/portable_oracle_mcp_smoke.py`: reused as-is.
- `Scripts/smoke_portable_oracle_docker.sh`: existing deterministic product smoke remains authoritative.
- `RepoPromptHeadless/**`: no production change unless a live benchmark captures an actual envelope defect.
- `RepoPromptHeadlessTests/**`: no change in this iteration.
- `README.md`, `docs/architecture/portable-oracle-mcp.md`, and `docs/plans/portable-builder-cli-parity-2026-07-23.md`: current contracts already describe the behavior used by the harness.
- `.gitignore`: iteration trees live in system temporary storage and artifacts use explicit output paths.

# 5. Risks and migration

## Benchmark artifact compatibility

The output becomes a campaign artifact rather than the current single-call snapshot. Mark it with `schema_version: 2` and write it only to a new path. Do not migrate, replace, or reinterpret `benchmarks/p-limit-portable.json`. Consumers must branch on `schema_version`.

## External apply determinism

The Oracle plan and external adapter can remain nondeterministic. The harness controls this by:

- selecting a lane deterministically;
- passing the exact plan bytes only;
- recording response and adapter fingerprints;
- applying in a fresh isolated clone;
- requiring a scoped Git delta and repository test suite;
- retaining all raw lane outputs.

The adapter remains a trusted external executable rather than a security sandbox. The source repository path is never passed, and source status is verified before and after to detect accidental mutation.

## Dependency reproducibility

A supported lockfile is required. If the pinned commit unexpectedly lacks one or uses an unsupported package manager, fail closed and record the preflight issue instead of using an unlocked install. Validate this against the acquired commit before the live campaign.

## Evidence truncation

Large diffs or logs may exceed the builder context budget. Truncation must be deterministic and explicit, with full hashes, byte counts, and sidecar references. An internally truncated evidence file does not permit silently truncated `workspace_context`; the builder context itself must still report `truncated: false` and no omissions.

## Scoreboard concurrency

The scoreboard is append-only and shared across campaigns. POSIX `flock` is acceptable because the supported development environments are macOS and Linux. Concurrent campaigns serialize row writes; they do not merge or rewrite rows.

## Cost and latency bounds

At most five iterations are allowed. Each iteration makes exactly:

- two provider requests for direct builder plan;
- two provider requests for direct builder review, when apply produced a reviewable implementation.

There are no hidden retries. Host command, provider, and MCP deadlines are separately bounded and recorded.

# 6. Implementation order

1. **Add pure models and validation helpers in `benchmarks/run_portable_benchmark.py`.**  
   Implement builder-envelope validation, lane selection, verdict parsing, agreement evaluation, path-scope checks, secret redaction, and scoreboard row rendering. Add the corresponding unit tests first. This step is locally testable without Docker.

2. **Add preflight and provenance handling.**  
   Parse the new CLI fields; validate the provider route and timeout relationship; resolve the immutable Docker image ID; reject existing output paths and the legacy artifact; snapshot the source repository. Add unit tests for argument, output, and provider-resolution failures.

3. **Add source isolation and iteration Git state.**  
   Create the independent base clone, verify the pinned commit, create a fresh clone per iteration, apply the prior cumulative patch to the index, and validate delta/cumulative paths. Test Git behavior against temporary fixture repositories.

4. **Replace the old live call sequence with direct builder plan.**  
   Add the two-root Docker/MCP helper, fresh selection per call, complete envelope validation, Primary-first completed-lane selection, and raw plan artifacts. Remove the live `context_builder(clarify)` and `oracle_send(plan)` calls from this benchmark path.

5. **Add the external apply adapter and bounded command runner.**  
   Parse JSON argv, pass the selected plan on stdin, append only the isolated workspace argument, enforce timeout/process-group cleanup, capture sanitized logs, and quarantine invalid deltas. Unit-test success, non-zero exit, timeout, and out-of-scope mutations.

6. **Add dependency installation and exact `npm test`.**  
   Detect the repository’s lockfile and package-manager declaration, run the frozen install command, assert it leaves source unchanged, execute `npm test`, and capture complete provenance. Do not add an unlocked fallback.

7. **Add review evidence and direct builder review.**  
   Render bounded `review-evidence.md`, select the changed implementation plus evidence, call `context_builder(review)`, validate both lane envelopes, parse both verdicts, and record all findings.

8. **Add iteration feedback, cumulative patch advancement, and stop logic.**  
   Feed prior review/test/apply defects into the next plan call, reuse only validated cumulative patches, stop on the exact agreement rule, and cap the campaign at five attempts.

9. **Add exclusive artifacts and append-only scoreboard persistence.**  
   Create sidecars and per-iteration records with exclusive writes, append the scoreboard row under `flock`, and write the final schema-version-2 JSON on every controlled exit. This step must land atomically with the scoreboard scaffold.

10. **Run deterministic regression verification.**

    ```bash
    python3 -m unittest discover \
      -s benchmarks \
      -p 'test_run_portable_benchmark.py'

    swift test

    bash Scripts/smoke_portable_oracle_docker.sh
    ```

11. **Acquire and verify the pinned p-limit source without touching the RepoPrompt worktree.**

    ```bash
    p_limit_source="$(mktemp -d)"
    git clone https://github.com/sindresorhus/p-limit.git "$p_limit_source"
    git -C "$p_limit_source" cat-file \
      -e 'df476048d023ff868cd45b35ee47f5fb0ca2b25a^{commit}'
    ```

    The harness performs its own detached pinned clone; the source checkout does not need to be clean or checked out at that commit.

12. **Run the live campaign with a separately supplied adapter.**

    ```bash
    export APPLY_ADAPTER=/absolute/path/to/portable-plan-apply-adapter

    OPENCODE_API_KEY='…' \
    python3 benchmarks/run_portable_benchmark.py \
      --workspace "$p_limit_source" \
      --image ghcr.io/dsebban/repoprompt-portable:latest \
      --output "prompt-exports/p-limit-plan-review-campaign.json" \
      --apply-command "$(python3 -c 'import json, os; print(json.dumps([os.environ["APPLY_ADAPTER"]]))')" \
      --oracle-timeout-seconds 120 \
      --timeout-seconds 300 \
      --command-timeout-seconds 900 \
      --max-iterations 5
    ```

13. **Final scope audit.**

    ```bash
    git status --short
    git diff --check
    git diff --name-only
    ```

    Expected implementation paths are limited to:

    ```text
    benchmarks/run_portable_benchmark.py
    benchmarks/test_run_portable_benchmark.py
    prompt-exports/optimize-portable-plan-review-runs.md
    ```

    The live campaign may additionally append one or more scoreboard rows and create the explicitly requested new output artifact and sidecar directory. It must not alter the legacy benchmark JSON, any Swift production source, the supplied p-limit repository, or unrelated dirty-worktree files.
:::

### Secondary Oracle — independent critique
- **Status**: completed
- **Model**: grok-4.5
- **Model ID**: `cursor_custom_grok-4.5[effort=high,fast=true]`
- **Chat**: `portable-benchmark-harde-8181D4`
- **Full chat ID**: `8181D48C-2419-492F-B9B2-E6CC4E7DFFB7`
- **Context ID**: `57262535-8254-44F2-8409-0EF33EF16E4D`

#### Requested route
- Provider: Cursor CLI (`cursor`)
- Backend: `CursorCLIProvider`
- Model: grok-4.5
- Raw model ID: `cursor_custom_grok-4.5[effort=high,fast=true]`
- Runtime model ID: `grok-4.5[effort=high,fast=true]`
- Execution mode: `standard`

#### Response
Technical Plan Generator

# Portable plan/review quality-loop harness — implementation plan

## 1. Summary

Replace the current one-shot MCP benchmark (`context_builder(clarify)` → `oracle_send(plan)` → single JSON dump) with a bounded, iterative harness that (1) calls `context_builder(plan)` directly, (2) picks exactly one completed lane by a fixed Primary-then-Secondary policy, (3) applies that plan only inside an isolated writable checkout of p-limit `@df476048d023ff868cd45b35ee47f5fb0ca2b25a`, (4) runs that tree’s native `npm test`, (5) calls `context_builder(review)` over the post-apply sources plus a real diff and apply/test provenance, (6) validates both builder envelopes structurally, and (7) appends one scoreboard row per iteration to `prompt-exports/optimize-portable-plan-review-runs.md`, stopping on dual-lane review agreement with green objective gates or after five iterations. Approach: keep production Swift untouched; evolve the Python benchmark into a thin orchestrator plus a small pure helper module that unit-tests envelope/verdict/scoreboard logic without Docker or credentials.

## 2. Current-state analysis

### End-to-end flow today

```
run_portable_benchmark.py
  → StdioMCPClient(docker run --rm -i -mount RO /workspace …)
  → initialize + notifications/initialized
  → manage_selection(set, SELECTED_PATHS)
  → context_builder(clarify)          # local only
  → oracle_send(mode=plan)            # provider, but not direct builder
  → write benchmarks/p-limit-portable.json
```

Gaps vs requested loop:

| Required capability | Today |
|---|---|
| Direct `context_builder(plan\|review)` | Not used; plan goes through `oracle_send` |
| Apply plan / `npm test` | Absent |
| Isolated writable p-limit tree | Host path is user-supplied RO mount only |
| Review over real diff | Absent; portable never synthesizes diffs |
| Provider timeout in container | Only Python `StdioMCPClient.timeout`; no `REPOPROMPT_ORACLE_TIMEOUT_SECONDS` |
| Image/model provenance | Absent from artifact |
| Lane agreement rubric | Absent; `pair_status == completed` ≠ agreement |
| Scoreboard append | Path does not exist |
| Iteration / stop | Single shot |

### Reusable pieces (do not duplicate)

- `Scripts/portable_oracle_mcp_smoke.py`: `StdioMCPClient`, `rpc_result`, `tool_json`, `PROTOCOL_VERSION`, nested-key patterns for forbidden fields.
- Catalog contracts already proven in `RepoPromptHeadlessCatalogOracleTests`: builder plan/review envelope shape, Primary-only top-level projection, forbidden `chat_id` / `oracle_export_path` / `winner` / `synthesis`, immutable selection snapshot, `oracle_not_configured` for generated modes without env.
- Docker env-forward pattern from `smoke_portable_oracle_docker.sh` (`--env REPOPROMPT_ORACLE_TIMEOUT_SECONDS`, bind mount, `--no-persist --root /workspace`).
- Legacy `benchmarks/p-limit-portable.json`: **immutable baseline**; never overwrite.

### Hard constraints

- Portable MCP is read-only: no apply, git, or diff tools. Apply + diff + `npm test` must live in the host harness outside the container.
- Selection is process-local: plan session and review session may be separate Docker invocations; each must `manage_selection` before its builder call.
- Dirty worktree is user-owned: no `git reset`/`clean`/`restore`, no overwriting existing tracked/untracked user files except intentional append/create of the scoreboard and new harness outputs under agreed paths.
- Secrets must not appear in artifacts/scoreboard (`OPENCODE_API_KEY`, bearer tokens, anything from `opencode.docker.json`’s embedded key).

### Blocking design questions (resolved below)

Acquisition of p-limit, apply adapter, lane choice, agreement parsing, and script vs module split are all decided in Design so the implementer does not invent them.

---

## 3. Design

**Decision: targeted harness change, not a product refactor.** Direct builder plan/review already exists in `HeadlessToolCatalog`. The defect is the benchmark’s coverage, not the MCP surface. Production Swift changes are out of scope unless a harness run reproduces a catalog/provider contract bug; if that happens, stop the campaign, file the defect separately, and do not silently “fix” quality by changing production mid-loop.

### 3.1 Layout (fewest files)

| Path | Role |
|---|---|
| `benchmarks/portable_quality_loop.py` | **New** pure helpers: envelope validation, lane pick, verdict parse, scoreboard append, provenance redact, stop predicate. Unit-testable with no Docker. |
| `benchmarks/run_portable_quality_loop.py` | **New** orchestrator CLI: clone/isolate, Docker MCP plan, apply, npm test, Docker MCP review, iterate ≤5, append scoreboard. |
| `benchmarks/test_portable_quality_loop.py` | **New** pytest/unittest for helpers only (fixtures from synthetic JSON, no network). |
| `benchmarks/run_portable_benchmark.py` | **Leave behavior intact** as legacy one-shot; add a one-line docstring pointer to the quality loop. Do not change its output schema. |
| `benchmarks/p-limit-portable.json` | **Never modify.** |
| `prompt-exports/optimize-portable-plan-review-runs.md` | **Create once** with header + scaffold; thereafter **append-only**. |
| `Scripts/portable_oracle_mcp_smoke.py` | **Reuse only** (import client helpers). No smoke semantics change required for this iteration. |

Rationale for not stuffing everything into `run_portable_benchmark.py`: the quality loop’s isolation/apply/npm/scoreboard concerns would break the legacy artifact contract and make unit tests depend on Docker. Two entry points; one shared helper module.

Assumed artifact/work dirs (all under repo, gitignored via existing `.build/` or new ignores listed in §4):

```
.build/portable-quality/
  cache/p-limit.git/          # bare or full clone cache (shared across runs)
  runs/<run_id>/
    worktree/                 # writable isolated copy @ pinned commit
    plan.json
    review.json
    apply.log
    npm-test.log
    diff.patch
    changed_files.txt
    provenance.json
    review_selection/         # files mounted RO into review container
```

Add to `.gitignore` only: `.build/portable-quality/` (and keep ignoring `__pycache__`). Do not gitignore `prompt-exports/optimize-portable-plan-review-runs.md` (scoreboard is intentional evidence).

### 3.2 Component: `portable_quality_loop` helpers

**Kind:** Python module (functions + frozen dataclasses). No classes with lifecycle beyond pure data.

**Constants (closed):**

```text
PINNED_REPO = "https://github.com/sindresorhus/p-limit"
PINNED_COMMIT = "df476048d023ff868cd45b35ee47f5fb0ca2b25a"
PLAN_SELECTED_PATHS = [index.js, index.d.ts, index.test-d.ts, test.js, readme.md, package.json]
MAX_ITERATIONS = 5
TASK = <exact AbortSignal task string from current run_portable_benchmark.py>
FORBIDDEN_ORACLE_FIELDS = {chat_id, new_chat, oracle_export_path, winner, synthesis}
```

**Data shapes:**

```text
Provenance:
  image_ref: str                    # argv --image
  image_digest: str | null          # docker image inspect Id / RepoDigests[0] if present
  oracle_route: "opencode_go" | "explicit_reprompt_oracle" | "unconfigured"
  primary_model_expected: str | null
  secondary_model_expected: str | null
  provider_timeout_seconds: int     # value forwarded into container
  stdio_timeout_seconds: float      # StdioMCPClient timeout
  # never store api keys / Authorization

LanePick:
  lane: "primary" | "secondary"
  reason: "primary_completed" | "secondary_fallback_primary_failed"
  plan_text: str
  pair_id: str
  primary_status / secondary_status: "completed" | "failed"

ReviewVerdict:
  lane: "primary" | "secondary"
  terminal: "completed" | "failed"
  parse_ok: bool
  verdict: "pass" | "fail" | "indeterminate"
  defect_codes: list[str]           # machine tokens only
  raw_excerpt: str                  # ≤512 chars for scoreboard

IterationRecord:
  iteration: 1..5
  plan_ok / review_ok: bool
  pair_status_plan / pair_status_review: str
  lane_pick: LanePick summary
  apply_exit / npm_test_exit: int | null
  objective_pass: bool              # apply_exit==0 AND npm_test_exit==0
  review_verdicts: [ReviewVerdict, ReviewVerdict]
  lanes_agree: bool
  stop_reason: "agreement" | "max_iterations" | "hard_fail" | null
```

**Key functions (sync, pure where possible):**

1. `validate_builder_envelope(obj, *, response_type: "plan"|"review") -> list[str]`  
   Failures collected as strings (empty = pass). Required:
   - `ok` bool present  
   - `response_type` equals expected  
   - `status` ∈ {`response_generated`, `response_failed`} and consistent with Primary (`completed` ⇒ `response_generated` + `ok true` + `response` string; Primary `failed` ⇒ `response_failed` + `ok false` + `error` object)  
   - `pair_status` ∈ {`completed`, `partial_failure`, `failed`}  
   - `oracle_pair_id` non-empty UUID string  
   - `oracle_decision_policy == "caller_decides"`  
   - `oracle_results.primary` and `.secondary` each have `oracle_lane`, `status`, `model_raw_id`, `provider == "openai_compatible"`  
   - completed lanes have non-empty `response`; failed lanes have `error.code` + `error.message`  
   - no keys in `FORBIDDEN_ORACLE_FIELDS` anywhere (reuse smoke’s nested-key idea)  
   - `workspace_context` object present with `content` string  

2. `pick_apply_lane(plan_envelope) -> LanePick`  
   **Policy (deterministic, no synthesis):**
   - If `oracle_results.primary.status == "completed"` and `response` non-empty → choose **primary**.  
   - Else if secondary completed with non-empty response → choose **secondary** (`secondary_fallback_primary_failed`).  
   - Else raise `HardFail("no_completed_plan_lane")`.  
   Never merge or rewrite lane text. Always retain both raw responses in `plan.json`.

3. `extract_review_verdict(lane_response: str, lane: str) -> ReviewVerdict`  
   Require a **machine block** at the end of each review response (harness instructs both lanes to emit it). Parser is strict:

   ```text
   ### PORTABLE_REVIEW_VERDICT
   verdict: pass|fail
   defects: none|<comma-separated-CODE>
   ### END_PORTABLE_REVIEW_VERDICT
   ```

   - Missing/malformed block → `verdict=indeterminate`, `parse_ok=false`.  
   - `defects: none` with `verdict: pass` only; if `verdict: fail` and `none`, treat as indeterminate.  
   - Allowed defect code charset: `[A-Z][A-Z0-9_]{1,31}`; unknown codes still count as fail if verdict=fail.

4. `lanes_agree(objective_pass, v_primary, v_secondary) -> bool`  
   True **iff all** hold:
   - `objective_pass`  
   - both lanes `terminal == completed` and `parse_ok`  
   - both `verdict == pass`  
   - both defect lists empty/`none`  
   `pair_status == completed` alone is **never** sufficient.

5. `should_stop(iteration, agree, hard_fail) -> (bool, stop_reason)`  
   Stop if `hard_fail`, or `agree`, or `iteration >= 5`.

6. `append_scoreboard(path, record: IterationRecord, provenance: Provenance) -> None`  
   - Create file with fixed header if missing.  
   - Exclusive lock via `fcntl.flock` (macOS/Linux).  
   - Append exactly one Markdown section; never rewrite prior sections.  
   - If file exists, preserve bytes before EOF unchanged (validate by reading length before lock write).

**Scoreboard scaffold (create-if-missing header only):**

```markdown
# Portable plan/review quality runs

Append-only. One section per iteration. Do not edit historical sections.

| Field | Meaning |
|---|---|
| objective_pass | apply exit 0 AND npm test exit 0 |
| lanes_agree | dual review pass + parse_ok + objective_pass |
```

Then each append:

```markdown
## run_id=<…> iteration=<n> <ISO8601-UTC>

- image: <ref> digest=<…|unknown>
- oracle_route: <…> timeout_provider=<s> timeout_stdio=<s>
- models_expected: primary=<…> secondary=<…>
- models_observed: plan P=<…> S=<…>; review P=<…> S=<…>
- plan: pair_status=<…> ok=<…> picked_lane=<…> (<reason>)
- apply_exit=<…> npm_test_exit=<…> objective_pass=<bool>
- review: pair_status=<…> P=<verdict>/<parse_ok> S=<verdict>/<parse_ok>
- lanes_agree=<bool> stop_reason=<…|ongoing>
- defects_P: …
- defects_S: …
- artifacts: <relative paths to plan.json review.json diff.patch npm-test.log>
```

### 3.3 Component: orchestrator `run_portable_quality_loop.py`

**CLI (resolved defaults):**

```text
--image                          default ghcr.io/dsebban/repoprompt-portable:latest
--run-root                       default <repo>/.build/portable-quality/runs/<generated_run_id>
--cache-dir                      default <repo>/.build/portable-quality/cache
--oracle-timeout-seconds         default max(stdio_budget_hint, 180), clamped 1..600
--stdio-timeout-seconds          default oracle_timeout + 60
--max-iterations                 default 5 (hard cap; do not allow >5 without code change)
--apply-command                  required unless --apply-command-file; see §3.5
--scoreboard                     default <repo>/prompt-exports/optimize-portable-plan-review-runs.md
--keep-worktrees                 default false (delete worktree on success stop; keep on hard_fail)
```

**Env requirements:**

- Same as live benchmark: `OPENCODE_API_KEY` **or** full explicit `REPOPROMPT_ORACLE_*` trio.  
- Orchestrator must **forward into Docker**:
  - `OPENCODE_API_KEY` if set (value not logged)
  - **always** `REPOPROMPT_ORACLE_TIMEOUT_SECONDS=<oracle-timeout-seconds>`
  - if explicit route set on host, forward `REPOPROMPT_ORACLE_ENDPOINT`, `_PRIMARY_MODEL`, `_SECONDARY_MODEL`, optional `_API_KEY`
- Resolve `oracle_route` for provenance: if endpoint+both models present → `explicit_reprompt_oracle`; elif `OPENCODE_API_KEY` → `opencode_go`; else hard-fail before Docker.

**Provenance capture (no secrets):**

- `docker image inspect --format '{{json .RepoDigests}} {{.Id}}'` on `--image` before first MCP call.  
- Record returned `model_raw_id` from each lane in plan/review envelopes.  
- Record both timeout values.  
- Redact any string matching `sk-`, `Bearer `, or length≥40 base64-looking tokens from logs written under `runs/`.

### 3.4 State / data flow per iteration

```text
1. Ensure cache clone + verify commit (once per run)
2. Fresh worktree copy for iteration n (or reset iteration worktree to clean pinned tree)
3. MCP session A (RO mount = worktree OR a snapshot of six files):
     manage_selection(set, PLAN_SELECTED_PATHS)
     context_builder(plan, instructions=TASK, max_context_bytes=1048576)
   → validate_builder_envelope(plan)
   → pick_apply_lane
4. Host apply: subprocess apply-command with env PORTABLE_APPLY_* (§3.5)
5. Host: compute git diff / changed file list vs clean tree; write diff.patch
6. Host: npm install (lockfile-faithful) then npm test; capture exit + truncated log (≤256 KiB)
7. Build review mount dir:
     - copy changed tracked source files that exist under worktree
     - always include index.js, index.d.ts, test.js, index.test-d.ts if changed or always for AbortSignal task (see rule below)
     - write PROVENANCE.md (apply exit, npm exit, picked lane, pair ids, timeouts, image digest — no secrets)
     - write DIFF.patch (bounded: if >512 KiB, head 256 KiB + tail 64 KiB + note)
     - write NPM_TEST.log truncated similarly
8. MCP session B (RO mount = review_selection/):
     manage_selection(set, all files under mount)
     context_builder(review, instructions=REVIEW_INSTRUCTIONS, max_context_bytes=1048576)
   → validate_builder_envelope(review)
   → extract_review_verdict both lanes
9. objective_pass = apply_ok ∧ npm_ok
   lanes_agree = lanes_agree(...)
   append_scoreboard
10. if should_stop → exit; else n+1 with feedback injected into next plan instructions
```

**Review selection rule (precise):**  
Include every path with a non-empty diff against the clean pinned tree that is a regular file under the worktree and whose basename is in `{index.js,index.d.ts,index.test-d.ts,test.js,readme.md,package.json}` **or** any other modified file under the repo root excluding `node_modules` and `.git`. Cap at 32 files; if over, prefer the six canonical paths first, then largest diffs by byte size, record omissions in `PROVENANCE.md`.

**Next-iteration plan instructions:**  
Start from `TASK`, then append a fixed feedback block listing prior apply/npm exits, both review verdicts, defect codes, and “Do not repeat prior failed approach; address listed defects.” Do not paste entire prior plans (cap feedback ≤8 KiB).

**Out-of-order / duplicate / drop:**  
Each iteration uses a new `run_id/iteration_n` directory. MCP sessions are sequential; no concurrent sessions sharing a worktree. If plan MCP times out, treat as hard_fail for that iteration (do not apply). If apply fails, still run review only if `--review-on-apply-fail` is false (default): skip review, record `review_skipped`, continue to next iteration with feedback. Default **does** skip review when apply fails (objective already false; saves provider cost). If npm fails after successful apply, **do** run review (useful defect signal).

### 3.5 External apply adapter (closed contract)

Portable cannot apply plans. The harness invokes a **user-supplied command**:

```text
--apply-command '…'   # shell form executed via subprocess list after shlex.split
```

**Environment injected (only these):**

| Env | Meaning |
|---|---|
| `PORTABLE_APPLY_WORKTREE` | Absolute path to writable isolated tree |
| `PORTABLE_APPLY_PLAN_PATH` | Absolute path to UTF-8 file containing **only** the chosen lane’s plan text |
| `PORTABLE_APPLY_LANE` | `primary` or `secondary` |
| `PORTABLE_APPLY_PAIR_ID` | plan `oracle_pair_id` |
| `PORTABLE_APPLY_ITERATION` | `1`..`5` |
| `PORTABLE_APPLY_TASK` | Original TASK string |

**Contract:**

- Exit `0` ⇒ apply considered successful (files may be unchanged only if plan claimed no-op — still OK).  
- Non-zero ⇒ apply failure; capture stdout/stderr to `apply.log` (truncate 256 KiB).  
- Timeout: `oracle_timeout_seconds * 2` wall clock, then kill process group.  
- Harness never invents edits. If `--apply-command` missing → hard_fail at startup with message naming the flag (fail closed).

**Minimal reference adapter (document in harness `--help`, do not ship as production):** implementers may use a local agent CLI wrapper; the plan does not mandate a specific vendor. For CI-less local runs, a stub that exits 1 is enough to unit-test failure paths.

Assumption (explicit): “apply” quality is owned by the external command; this harness measures portable plan/review **plus** objective gates, not the agent’s editor skill. Campaign “agreement” still requires green npm + dual pass verdicts on the resulting tree.

### 3.6 p-limit acquisition & isolation

**Once per run:**

1. Ensure `cache-dir/p-limit.git` via `git clone --mirror` (or fetch if exists).  
2. `git -C cache cat-file -t PINNED_COMMIT` must be `commit`; else hard_fail.  
3. For each iteration:  
   - `git worktree add --detach <run>/i<n>/worktree PINNED_COMMIT` **or** `git archive PINNED_COMMIT | tar -x -C worktree` then `git init`+`git checkout` only if worktree add unavailable. Prefer `git worktree add` from the mirror.  
4. **Never** mutate the user’s source fixture or any path outside `--run-root` / `--cache-dir`.  
5. Verify `git -C worktree rev-parse HEAD` equals `PINNED_COMMIT`.

**Install (lockfile-faithful):**

After first populate (before apply on iteration 1, and after reset each iteration):

```text
if package-lock.json exists → npm ci
elif yarn.lock exists → yarn install --frozen-lockfile
elif pnpm-lock.yaml exists → pnpm install --frozen-lockfile
else → npm install
```

Inspect the acquired tree; do not assume lockfile presence from the JSON baseline (package.json in baseline has no lockfile listed in `files`, but clone may still have one). Record which install command ran in `PROVENANCE.md`.

**`npm test`:** run `npm test` with cwd=worktree, env `CI=1`, timeout 600s. Exit code is the objective signal. On Node 20, existing p-limit tests skip one AbortError case; do not special-case—use the suite’s own exit code.

### 3.7 MCP Docker invocation (plan & review)

Mirror smoke/benchmark, with additions:

```text
docker run --rm -i
  --mount type=bind,src=<host_dir>,dst=/workspace,readonly
  --env OPENCODE_API_KEY                    # if set
  --env REPOPROMPT_ORACLE_TIMEOUT_SECONDS=<n>   # ALWAYS
  [--env REPOPROMPT_ORACLE_* if explicit]
  <image>
  --no-persist --root /workspace
```

Sequence inside client (reuse smoke helpers):

1. `initialize` / `notifications/initialized`  
2. `manage_selection` `{op:set, mode:full, paths:[…], view:files}` — assert `selected_paths` match request (display paths).  
3. `context_builder` with `response_type` plan|review.  
4. Close stdin; require process exit 0 and not timed_out (same as current benchmark).

**Plan instructions:** exact `TASK` (+ feedback on iterations >1).  
**Review instructions (fixed template):**

```text
Review the selected post-apply p-limit AbortSignal implementation against the task.
Use DIFF.patch, NPM_TEST.log, and PROVENANCE.md as evidence. Do not assume unselected files.
End with exactly:

### PORTABLE_REVIEW_VERDICT
verdict: pass|fail
defects: none|CODE[,CODE...]
### END_PORTABLE_REVIEW_VERDICT

Defect codes must be short machine tokens (e.g. ABORT_REASON_TRUTHY, LISTENER_LEAK,
RUNNING_TASK_CANCELLED, TYPES_MISSING, TEST_GAP, DOCS_MISSING).
```

### 3.8 Concurrency & lifecycle

- Single-threaded orchestrator; one Docker MCP at a time.  
- Apply and npm are sequential host subprocesses.  
- Scoreboard flock prevents concurrent campaign corruption; document “one campaign at a time” and if lock busy wait ≤30s then hard_fail.  
- Cancellation: SIGINT → stop loop, append row with `stop_reason=interrupted` if possible, leave worktrees.  
- No production actors/threads involved.

### 3.9 Error handling

| Failure | Behavior |
|---|---|
| Missing credentials / invalid timeout | Exit 78 before Docker; no scoreboard row |
| Clone/commit mismatch | Exit 70; no scoreboard |
| Envelope validation errors | Iteration hard_fail; append row; continue unless iteration==5 |
| No completed plan lane | hard_fail iteration; no apply |
| Apply non-zero / timeout | `objective_pass=false`; skip review (default); next iteration |
| npm non-zero | run review; continue |
| Review envelope invalid / indeterminate verdicts | `lanes_agree=false`; continue |
| Stdio MCP timeout / non-zero docker exit | hard_fail iteration; append; continue |
| Agreement | append; exit 0 |
| Five iterations without agreement | append final; exit 1 |

Exit codes: `0` agreement; `1` completed campaign without agreement; `64` CLI usage; `70` runtime/tooling; `78` configuration.

### 3.10 Avoided complexity

- No production catalog/workflow changes.  
- No merging Primary/Secondary plans.  
- No second Oracle call path; only `context_builder`.  
- Legacy benchmark left alone so `p-limit-portable.json` remains comparable.  
- No git tool inside portable; host `git`/`diff` only on isolated trees.

### 3.11 Unknowns to validate during implementation

| Unknown | Validation |
|---|---|
| Whether pinned commit has a lockfile | After clone, `ls` lockfiles; branch install command; record in provenance |
| Whether `git worktree add` from mirror works on runner | Prefer it; fallback `git archive` documented above |
| Apply command availability in environment | Fail closed at startup if missing |
| AVA/Node 20 AbortError skip affecting “green” | Accept upstream skip; agreement still requires review pass + suite exit 0 |
| Review context size with large diffs | Enforce DIFF truncation; if builder truncates, record `workspace_context.truncated` and still score |

---

## 4. File-by-file impact

| File | Change | Why | Ordering |
|---|---|---|---|
| `benchmarks/portable_quality_loop.py` | **Add** helpers (§3.2) | Pure logic for tests + orchestrator | First |
| `benchmarks/test_portable_quality_loop.py` | **Add** unit tests: envelope ok/fail, Primary-then-Secondary pick, verdict parse, agreement matrix, scoreboard append preserves prefix, redaction | Proves harness without Docker | After helpers |
| `benchmarks/run_portable_quality_loop.py` | **Add** orchestrator CLI (§3.3–3.7) | End-to-end loop | After helpers; can stub apply |
| `benchmarks/run_portable_benchmark.py` | **Docstring only** pointing to quality loop | Avoid dual semantics in one script | Anytime |
| `benchmarks/p-limit-portable.json` | **No change** | Baseline evidence | — |
| `prompt-exports/optimize-portable-plan-review-runs.md` | **Create** header on first run (or empty scaffold committed once) | Append-only campaign log | Created by orchestrator first successful start |
| `.gitignore` | **Add** `.build/portable-quality/` | Keep clones/worktrees out of git | With orchestrator |
| `README.md` | **Short** “Quality loop” subsection: command, required `--apply-command`, timeouts, scoreboard path | Operator discoverability | Last |
| `docs/architecture/portable-oracle-mcp.md` | **Optional one paragraph** under smoke/benchmark: quality loop is host-side; still no write tools | Contract clarity | Last; skip if README enough |
| Production Swift / Dockerfile / smoke | **No change** this iteration | Builder plan/review already shipped in dirty tree | — |

**Dependencies:** helpers → unit tests → orchestrator → docs. Scoreboard file creation is runtime, not a prerequisite commit, but committing an empty scaffold header is allowed so the path exists without waiting for a live run.

---

## 5. Risks and migration

- **Non-breaking** for MCP API and legacy benchmark artifact.  
- **Scoreboard:** append-only; concurrent runs risk interleaved sections — mitigated by flock + “one campaign” rule.  
- **Secrets:** forward env into Docker but never write values; scrub logs.  
- **Rollback:** delete new scripts and scoreboard; legacy benchmark unchanged.  
- **Dirty worktree:** implementer must not reset user changes; only add/append listed files.  
- **Apply quality variance:** campaign may fail agreement due to apply agent, not portable — that is acceptable; scoreboard still diagnoses portable envelope/provenance issues separately via structural columns.

---

## 6. Implementation order

1. **Add** `benchmarks/portable_quality_loop.py` with constants, `validate_builder_envelope`, `pick_apply_lane`, `extract_review_verdict`, `lanes_agree`, `should_stop`, `append_scoreboard`, provenance redact helpers. *(compilable/testable)*  
2. **Add** `benchmarks/test_portable_quality_loop.py` covering:  
   - valid plan/review fixtures cloned from catalog test expectations  
   - Primary completed → pick primary  
   - Primary failed / Secondary completed → secondary fallback  
   - both failed → raises  
   - verdict pass/fail/indeterminate  
   - agreement true only with objective_pass + dual pass  
   - scoreboard create + second append preserves first section bytes  
3. **Add** `.gitignore` entry for `.build/portable-quality/`.  
4. **Add** `run_portable_quality_loop.py`: CLI parse, provenance inspect, clone/verify, Docker MCP plan, apply, install/test, review pack, Docker MCP review, loop, exits.  
5. **Smoke locally without paid calls (optional):** point `--image` at a fixture build and a fake apply that edits a temp tree — or skip if only unit tests required for merge.  
6. **One live iteration** (manual): real image + `OPENCODE_API_KEY` + real `--apply-command`; confirm scoreboard row and `REPOPROMPT_ORACLE_TIMEOUT_SECONDS` visible in container env via logged provenance.  
7. **Docstring** on legacy benchmark + README blurb.  
8. **Do not** modify `p-limit-portable.json`, production Swift, or reset the dirty worktree.

### Verification commands

```bash
# Unit tests (no Docker/credentials)
python3 -m unittest benchmarks.test_portable_quality_loop -v
# or: pytest benchmarks/test_portable_quality_loop.py -q

# Existing portable product still green (dirty tree as-is)
swift test --filter RepoPromptHeadlessCatalogOracleTests
bash Scripts/smoke_portable_oracle_docker.sh

# Live quality loop (credentials + apply adapter required)
python3 benchmarks/run_portable_quality_loop.py \
  --image ghcr.io/dsebban/repoprompt-portable:latest \
  --oracle-timeout-seconds 180 \
  --stdio-timeout-seconds 240 \
  --apply-command '/path/to/your-apply-adapter'

# Confirm scoreboard grew by append only
wc -l prompt-exports/optimize-portable-plan-review-runs.md
```

### Done-when (this hardening iteration)

- Harness calls **`context_builder(plan)`** and **`context_builder(review)`** (not `oracle_send` for the loop).  
- Both envelopes validated for Primary **and** Secondary.  
- Exactly one completed lane applied; both lane texts retained on disk.  
- Apply + `npm test` only inside isolated pinned worktree; source fixture untouched.  
- `REPOPROMPT_ORACLE_TIMEOUT_SECONDS` forwarded and recorded with image digest and observed model IDs (no secrets).  
- Scoreboard append-only with agreement/objective fields.  
- Stops on dual-lane review agreement **with** objective pass, or after five iterations.  
- Helper unit tests pass without network; production code unchanged.



> 💡 Continue this plan pair with oracle_send(chat_id: "portable-benchmark-harde-ADAA5E" or "portable-benchmark-harde-8181D4", new_chat: false).