# Portable context_builder Plan/Review Quality Runs

## Measurement contract

- Target: end-to-end correctness for the p-limit AbortSignal task at commit `df476048d023ff868cd45b35ee47f5fb0ca2b25a`.
- Iteration 0 is the instrumented baseline; hardening iterations are 1 through 5, with one attributed harness change each.
- Every run starts from new disposable local clones. The source p-limit repository and dirty `repoprompt-portable` worktree are read-only inputs.
- Direct `context_builder(plan)` and `context_builder(review)` must each complete both attributed lanes. Lane responses are never synthesized.
- Acceptance requires a deterministic selected plan, allowlisted application diff, all ten external semantic probe groups, full `npm test`, static type/docs checks, and independent passes from both review lanes.
- Matching `changes_requested` verdicts are agreement, not success. Stop on dual-lane acceptance or after iteration 5.
- Portable/Node image IDs, endpoint identity, models, provider/stdio/application/test timeouts, selected paths, p-limit commit, and probe hash stay fixed within a campaign.
- Raw attributed responses live in per-run JSON artifacts. Keys, bearer tokens, authorization headers, and secret-derived hashes are never recorded.
- This file is append-only. Corrections are new run records; earlier records and artifacts are not edited.
- Portable product Swift may change only after a deterministic fixture-backed defect is reproduced.

## Correctness score

| Area | Points |
|---|---:|
| Provenance and isolation | 10 |
| Direct plan transport | 10 |
| Structured plan selection | 5 |
| Application and scope | 10 |
| Ten semantic probe groups | 30 |
| Full package test | 15 |
| Types and documentation | 5 |
| Direct review transport/parsing | 5 |
| Review verdict agreement | 5 |
| Dual-lane review acceptance | 5 |
| **Total** | **100** |

A run passes only at `100/100` with every mandatory gate true.

## Campaign provenance

Run records contain requested refs plus immutable image IDs/repo digests, sanitized endpoint identity, effective model IDs, separate timeout layers, exact p-limit commit/tree, probe hash, and portable dirty-worktree fingerprints.

## Candidate queue

| Rank | Candidate | Entry condition | Expected effect | Risk | Status |
|---:|---|---|---|---|---|
| 1 | Adversarial semantic plan instructions | Exact/falsey reason or listener lifecycle probe failure | Prevent invalid plans before application | Low | Waiting for baseline |
| 2 | Evidence-rich review packet | Review misses deterministic failures or lanes diverge | Better-grounded findings and agreement | Low–medium | Waiting for baseline |
| 3 | Category-only prior-review feedback | Same blocking categories recur twice | Focus the next plan without synthesis | Medium | Waiting for repeated evidence |

## Reverted attempts

| Date | Iteration | Candidate | Attempt | Reason reverted | Probe delta | npm test | Review effect | Artifact |
|---|---:|---|---|---|---|---|---|---|

## Handoff checklist

- Exactly one hardening change is attributed after baseline.
- Image IDs, endpoint/models, timeout layers, selected paths, commit, and probe hash match baseline.
- p-limit starts pristine at the pinned commit and only the five allowlisted product files change.
- The portable before/after fingerprint is unchanged outside the declared artifact and this scoreboard.
- Both plan scores, selection rationale, diff, probe matrix, npm exit, raw review lanes, normalized findings, score, and decision are recorded.

## Run records

New records are appended below by `benchmarks/run_portable_benchmark.py`.


### Iteration 0 — `91d106cd-4f12-4347-984b-2469d309c0bd`

- run_id: `91d106cd-4f12-4347-984b-2469d309c0bd`
- Label/candidate: baseline / baseline — Measurement harness only; no quality hardening candidate
- Images: portable `sha256:c78196d4081619bd89009e777b565b9bc8a78b69a7edaf0f7768a4a15ff97159`, Node `sha256:9be410e06dadc1794f44aa4c0fd107a7ecb2edb5cb6bcc6a71c7888caf3cfa12`
- Models/timeouts: `deepseek-v4-flash` + `deepseek-v4-flash`; provider 120s, stdio 300.0s
- p-limit: `df476048d023ff868cd45b35ee47f5fb0ca2b25a` / tree `21d1b1115ab955f499ca0de32b8819b936775dd9`
- Plan pair/selected: skipped / None
- Application/scope: exit None / False
- Probe/npm: 0/10 / exit None
- Review verdicts/agreement: None / None / False
- Score/decision: **0/100** / `invalid_environment`
- Artifact: `/Users/danielsivan/dev/repoprompt-portable/prompt-exports/portable-plan-review-artifacts/iteration-00.json`


### Iteration 0 — `a5c9a85c-41be-4726-9b8c-12183502f629`

- run_id: `a5c9a85c-41be-4726-9b8c-12183502f629`
- Label/candidate: baseline-retry-lockfile-fixture / baseline — Measurement harness only; choose npm install --no-package-lock because the pinned fixture has no lockfile
- Images: portable `sha256:c78196d4081619bd89009e777b565b9bc8a78b69a7edaf0f7768a4a15ff97159`, Node `sha256:9be410e06dadc1794f44aa4c0fd107a7ecb2edb5cb6bcc6a71c7888caf3cfa12`
- Models/timeouts: `deepseek-v4-flash` + `deepseek-v4-flash`; provider 120s, stdio 300.0s
- p-limit: `df476048d023ff868cd45b35ee47f5fb0ca2b25a` / tree `21d1b1115ab955f499ca0de32b8819b936775dd9`
- Plan pair/selected: failed / None
- Application/scope: exit None / False
- Probe/npm: 0/10 / exit None
- Review verdicts/agreement: None / None / False
- Score/decision: **10/100** / `continue`
- Artifact: `/Users/danielsivan/dev/repoprompt-portable/prompt-exports/portable-plan-review-artifacts/iteration-00-retry-01.json`

## Setup and historical baseline — 2026-07-24

| Record | Plan path | Application / tests / review | Configuration and observed result | Score |
|---|---|---|---|---:|
| Pre-loop baseline | Indirect `context_builder(clarify)` + `oracle_send(mode=plan)` only; no direct builder plan/review run | No code application, no p-limit `npm test`, and no changed-code review | No Oracle env produced `oracle_not_configured`; the primary default was 120s; a host-key attempt returned HTTP 429; an explicit 600s retry completed both plan lanes | **0/100** |

The successful 600-second pair demonstrates provider viability only. It earns no rubric points because it used the legacy indirect path and produced no isolated implementation, deterministic verification, direct review, or complete provenance.

### Infrastructure incidents

| Attempt | Operation | Result | Classification | Score impact |
|---:|---|---|---|---|
| 1 | Required setup `context_builder(response_type=plan)` | Timed out | Orchestrator/infrastructure failure before benchmark execution | None; not a model-quality result |
| 2 | Required setup `context_builder(response_type=plan)` retry | Timed out | Repeated orchestrator/infrastructure failure before benchmark execution | None; not a model-quality result |

### Done when

The loop is complete only when one appended run reaches **100/100** and all of these are true:

1. Direct `context_builder(response_type=plan)` returns completed Primary and Secondary lanes with valid lane/model/provider attribution, Primary projection, exact selected paths, and complete untruncated context.
2. One explicit OpenCode agent step applies the selected eligible plan only in a disposable writable clone at `df476048d023ff868cd45b35ee47f5fb0ca2b25a`; the external source fixture and portable worktree fingerprint remain unchanged.
3. The changed files stay within `index.js`, `index.d.ts`, `index.test-d.ts`, `test.js`, and `readme.md`; all ten semantic probe groups, the static contract, and p-limit `npm test` pass.
4. Direct `context_builder(response_type=review)` reviews the changed files plus deterministic evidence; both lanes parse, agree on `pass`, report no blocking finding, and mark every coverage key `pass`.
5. The JSON artifact records requested image tags, immutable image IDs/repo digests, sanitized endpoint identity, effective models, and provider/stdio/agent-MCP/application/test timeouts without any API key or authorization value.
6. The JSON artifact and scoreboard entry are appended without deleting or rewriting earlier run history.


### Iteration 1 — `8ab4e2b7-8bad-4550-96c0-c6ee58bf03d6`

- run_id: `8ab4e2b7-8bad-4550-96c0-c6ee58bf03d6`
- Label/candidate: configured-key-secure-retry / secure-incomplete-baseline-retry — Secure retry after incomplete baseline transport: forward configured credentials by environment name without a secret file and skip provenance comparison only for an incomplete plan baseline
- Images: portable `repoprompt-headless:portable-smoke` → `sha256:c78196d4081619bd89009e777b565b9bc8a78b69a7edaf0f7768a4a15ff97159` / `None`; Node `node:24-bookworm-slim` → `sha256:9be410e06dadc1794f44aa4c0fd107a7ecb2edb5cb6bcc6a71c7888caf3cfa12` / `node@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d`
- Endpoint/models: `https://opencode.ai:443/zen/go/v1/chat/completions`; `deepseek-v4-flash` + `deepseek-v4-flash`; agent `opencode-go/deepseek-v4-flash`
- Timeouts: provider 600s, stdio 720.0s, agent MCP 630s, application 900.0s, test 600.0s
- p-limit: `df476048d023ff868cd45b35ee47f5fb0ca2b25a` / tree `21d1b1115ab955f499ca0de32b8819b936775dd9`
- Plan pair/selected: completed / secondary
- Application/scope: exit 0 / True
- Probe/npm: 9/10 / exit 1
- Review verdicts/agreement: None / changes_requested / False
- Score/decision: **67/100** / `continue`
- Artifact: `/Users/danielsivan/dev/repoprompt-portable/prompt-exports/portable-plan-review-artifacts/iteration-01.json`

### Correction — iteration 1 score recalculation

- Original run/artifact remain unchanged: `8ab4e2b7-8bad-4550-96c0-c6ee58bf03d6` / `iteration-01.json`.
- Attributed harness correction: recompute points after the final portable-worktree preservation gate changes from true to false.
- Original stored score: **67/100**.
- Corrected authoritative score: **57/100**.
- Model outputs, phase exits, findings, and decision are unchanged.
- Verification: Python compile, Node syntax, and 14 harness tests exited 0.
- Correction artifact: `prompt-exports/portable-plan-review-artifacts/iteration-01-score-correction.json`.


### Iteration 2 — `3411556a-2bdf-4add-9bee-4ebde5097f64`

- run_id: `3411556a-2bdf-4add-9bee-4ebde5097f64`
- Label/candidate: adversarial-semantic-plan-contract-v2 / adversarial-semantic-plan-contract-v2 — Require plan-result schema v2 to encode queue-scoped abort-listener state transitions and pre-trigger observation of every intentional abort/clear rejection; reject nonconforming plan lanes before selection.
- Images: portable `repoprompt-headless:portable-smoke` → `sha256:c78196d4081619bd89009e777b565b9bc8a78b69a7edaf0f7768a4a15ff97159` / `None`; Node `node:24-bookworm-slim` → `sha256:9be410e06dadc1794f44aa4c0fd107a7ecb2edb5cb6bcc6a71c7888caf3cfa12` / `node@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d`
- Endpoint/models: `https://opencode.ai:443/zen/go/v1/chat/completions`; `deepseek-v4-flash` + `deepseek-v4-flash`; agent `opencode-go/deepseek-v4-flash`
- Timeouts: provider 600s, stdio 720.0s, agent MCP 630s, application 900.0s, test 600.0s
- p-limit: `df476048d023ff868cd45b35ee47f5fb0ca2b25a` / tree `21d1b1115ab955f499ca0de32b8819b936775dd9`
- Plan pair/selected: completed / None
- Application/scope: exit None / False
- Probe/npm: 0/10 / exit None
- Review verdicts/agreement: None / None / False
- Score/decision: **20/100** / `continue`
- Artifact: `/Users/danielsivan/dev/repoprompt-portable/prompt-exports/portable-plan-review-artifacts/iteration-02.json`


### Iteration 3 — `9ad9a014-e803-445a-86a9-659636a725bb`

- run_id: `9ad9a014-e803-445a-86a9-659636a725bb`
- Label/candidate: required-plan-file-manifest-v3 / required-plan-file-manifest-v3 — Require plan-result schema v3 files_to_modify to be the exact canonical five-file manifest without duplicates while accepting reordering; derive the application allowlist from that manifest.
- Images: portable `repoprompt-headless:portable-smoke` → `sha256:c78196d4081619bd89009e777b565b9bc8a78b69a7edaf0f7768a4a15ff97159` / `None`; Node `node:24-bookworm-slim` → `sha256:9be410e06dadc1794f44aa4c0fd107a7ecb2edb5cb6bcc6a71c7888caf3cfa12` / `node@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d`
- Endpoint/models: `https://opencode.ai:443/zen/go/v1/chat/completions`; `deepseek-v4-flash` + `deepseek-v4-flash`; agent `opencode-go/deepseek-v4-flash`
- Timeouts: provider 600s, stdio 720.0s, agent MCP 630s, application 900.0s, test 600.0s
- p-limit: `df476048d023ff868cd45b35ee47f5fb0ca2b25a` / tree `21d1b1115ab955f499ca0de32b8819b936775dd9`
- Plan pair/selected: completed / secondary
- Application/scope: exit 0 / True
- Probe/npm: 10/10 / exit 1
- Review verdicts/agreement: changes_requested / changes_requested / False
- Score/decision: **75/100** / `continue`
- Artifact: `/Users/danielsivan/dev/repoprompt-portable/prompt-exports/portable-plan-review-artifacts/iteration-03.json`


### Iteration 4 — `6d0848aa-4967-4e8c-9ff2-0df96a74d437`

- run_id: `6d0848aa-4967-4e8c-9ff2-0df96a74d437`
- Label/candidate: category-only-prior-review-feedback-v4 / category-only-prior-review-feedback-v4 — Normalize the prior artifact to dual-lane recurring blocking category IDs and deterministic failed-gate facts, then append only fixed plan feedback for existing ESLint suppressions and README signal placement/terms.
- Images: portable `repoprompt-headless:portable-smoke` → `sha256:c78196d4081619bd89009e777b565b9bc8a78b69a7edaf0f7768a4a15ff97159` / `None`; Node `node:24-bookworm-slim` → `sha256:9be410e06dadc1794f44aa4c0fd107a7ecb2edb5cb6bcc6a71c7888caf3cfa12` / `node@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d`
- Endpoint/models: `https://opencode.ai:443/zen/go/v1/chat/completions`; `deepseek-v4-flash` + `deepseek-v4-flash`; agent `opencode-go/deepseek-v4-flash`
- Timeouts: provider 600s, stdio 720.0s, agent MCP 630s, application 900s, test 600s
- p-limit: `df476048d023ff868cd45b35ee47f5fb0ca2b25a` / tree `21d1b1115ab955f499ca0de32b8819b936775dd9`
- Plan pair/selected: failed / None
- Application/scope: exit None / False
- Probe/npm: 0/10 / exit None
- Review verdicts/agreement: None / None / False
- Score/decision: **10/100** / `continue`
- Artifact: `/Users/danielsivan/dev/repoprompt-portable/prompt-exports/portable-plan-review-artifacts/iteration-04.json`


### Iteration 4 — `abfb61f6-c392-47c1-9342-a2d324a0af96`

- run_id: `abfb61f6-c392-47c1-9342-a2d324a0af96`
- Label/candidate: category-only-prior-review-feedback-v4 / category-only-prior-review-feedback-v4 — Normalize the prior artifact to dual-lane recurring blocking category IDs and deterministic failed-gate facts, then append only fixed plan feedback for existing ESLint suppressions and README signal placement/terms.
- Images: portable `repoprompt-headless:portable-smoke` → `sha256:c78196d4081619bd89009e777b565b9bc8a78b69a7edaf0f7768a4a15ff97159` / `None`; Node `node:24-bookworm-slim` → `sha256:9be410e06dadc1794f44aa4c0fd107a7ecb2edb5cb6bcc6a71c7888caf3cfa12` / `node@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d`
- Endpoint/models: `https://opencode.ai:443/zen/go/v1/chat/completions`; `deepseek-v4-flash` + `deepseek-v4-flash`; agent `opencode-go/deepseek-v4-flash`
- Timeouts: provider 600s, stdio 720.0s, agent MCP 630s, application 900s, test 600s
- p-limit: `df476048d023ff868cd45b35ee47f5fb0ca2b25a` / tree `21d1b1115ab955f499ca0de32b8819b936775dd9`
- Plan pair/selected: completed / secondary
- Application/scope: exit 0 / True
- Probe/npm: 10/10 / exit 0
- Review verdicts/agreement: pass / pass / True
- Score/decision: **100/100** / `stop_success`
- Artifact: `/Users/danielsivan/dev/repoprompt-portable/prompt-exports/portable-plan-review-artifacts/iteration-04-retry-01.json`
