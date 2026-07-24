# Portable Plan/Review Quality Baseline

`benchmarks/run_portable_benchmark.py` measures the direct portable `context_builder(plan)` → isolated plan application → deterministic verification → direct `context_builder(review)` path. It does not tune prompts and does not modify portable product Swift.

## Boundaries

- Source task: p-limit commit `df476048d023ff868cd45b35ee47f5fb0ca2b25a`.
- The supplied p-limit repository is read-only. The runner makes separate pristine-test and writable iteration clones under a temporary external directory.
- The application model may modify only `index.js`, `index.d.ts`, `index.test-d.ts`, `test.js`, and `readme.md` in the iteration clone.
- The runner reads host `REPOPROMPT_ORACLE_TIMEOUT_SECONDS` when present and otherwise uses 600 seconds, sets the effective endpoint/models/key/timeout in its own process, and forwards only environment-variable names with Docker `--env`. The mode-0600 OpenCode config contains no credential; artifacts record only credential presence/source and sanitized endpoint identity.
- Actual container runs use requested image tags resolved to immutable image IDs/repo digests. Provider, stdio, agent-MCP, application, and test timeouts are distinct and recorded.
- The portable dirty-worktree fingerprint must remain unchanged outside the exact JSON output and append-only scoreboard.

## Deterministic verification

`benchmarks/p_limit_abortsignal_probe.mjs` independently checks:

1. exact queued rejection reasons and synchronous pending drain;
2. immediate future rejection;
3. untouched running work;
4. pre-aborted signals;
5. `null`, `false`, `0`, empty-string, and `NaN` reasons;
6. enabled `rejectOnClear` independence;
7. disabled `rejectOnClear` behavior;
8. listener cleanup after drain, clear, abort, and repeated waves;
9. `limit.map()` propagation;
10. `limitFunction()` propagation.

The runner also executes pristine and post-change `npm test` (`xo && ava && tsd`) and static runtime/type/test/documentation checks. A score below `100/100` is not a pass.

## Setup checks

From the portable repository root:

```bash
python3 -m py_compile benchmarks/run_portable_benchmark.py Scripts/portable_oracle_mcp_smoke.py
node --check benchmarks/p_limit_abortsignal_probe.mjs
python3 -m unittest benchmarks/test_run_portable_benchmark.py

swift test --filter RepoPromptHeadlessCatalogOracleTests
swift test --filter RepoPromptHeadlessOracleConfigurationTests
swift test --filter RepoPromptHeadlessOracleWorkflowTests
swift test --filter PortableCLIArgumentsTests
swift test --filter PortableCLIApplicationTests

bash Scripts/smoke_portable_oracle_docker.sh
```

The Docker smoke rebuilds `repoprompt-headless:portable-smoke` unless `RP_PORTABLE_SKIP_BUILD=1`.

## Live baseline

Prepare a source clone outside this repository:

```bash
P_LIMIT_SOURCE="$(mktemp -d)/p-limit-source"
git clone https://github.com/sindresorhus/p-limit.git "$P_LIMIT_SOURCE"
git -C "$P_LIMIT_SOURCE" checkout --detach df476048d023ff868cd45b35ee47f5fb0ca2b25a
test -z "$(git -C "$P_LIMIT_SOURCE" status --porcelain)"
```

Run the baseline with the rebuilt smoke image and an already-local Node image:

```bash
test -n "${OPENCODE_API_KEY:-}"
mkdir -p prompt-exports/portable-plan-review-artifacts

env \
  -u REPOPROMPT_ORACLE_ENDPOINT \
  -u REPOPROMPT_ORACLE_PRIMARY_MODEL \
  -u REPOPROMPT_ORACLE_SECONDARY_MODEL \
  -u REPOPROMPT_ORACLE_API_KEY \
  REPOPROMPT_ORACLE_TIMEOUT_SECONDS="${REPOPROMPT_ORACLE_TIMEOUT_SECONDS:-600}" \
  python3 benchmarks/run_portable_benchmark.py \
    --workspace "$P_LIMIT_SOURCE" \
    --image repoprompt-headless:portable-smoke \
    --node-image node:22-bookworm-slim \
    --output prompt-exports/portable-plan-review-artifacts/iteration-00.json \
    --scoreboard prompt-exports/optimize-portable-plan-review-runs.md \
    --iteration 0 \
    --label baseline \
    --candidate-id baseline \
    --attributed-change "Measurement harness only; no quality hardening candidate" \
    --stdio-timeout-seconds 630 \
    --apply-timeout-seconds 900 \
    --test-timeout-seconds 600
```

The provider timeout is propagated from `REPOPROMPT_ORACLE_TIMEOUT_SECONDS`; `--provider-timeout-seconds` remains an explicit override. Exit `0` means every gate passed; `1` means a complete non-passing iteration was recorded; `2` means preflight or harness failure prevented a valid iteration.

For iteration 1–5, add `--baseline-artifact <iteration-00.json>`, a non-baseline `--candidate-id`, and one exact `--attributed-change`. Do not alter campaign provenance.

## Artifacts and interpretation

The JSON artifact retains raw attributed plan/review responses, deterministic normalized contracts, selected-plan hash/rationale, sanitized command results, diff and probe evidence, score gates, decision, and immutable provenance. The scoreboard receives one appended run record.

Weak plans, invalid p-limit implementations, probe/test failures, and review disagreement are model or benchmark outcomes. Change portable product code only after the fixture Docker smoke plus a focused Swift regression test reproduces a portable contract defect.
