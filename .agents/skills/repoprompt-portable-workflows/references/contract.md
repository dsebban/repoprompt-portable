# Portable capability contract

## Tool argument summary

- `bind_context`: `op` (`list|status|bind`), optional `context_id`, optional `working_dirs`.
- `get_file_tree`: optional `path`, `mode` (`auto|full|folders|selected`), `max_depth`.
- `read_file`: required `path`, optional 1-based or negative-tail `start_line`, optional `limit`.
- `manage_selection`: `op` (`get|set|add|remove|clear`), `paths`, `slices`, `view` (`summary|files|content`), `mode` (`full|slices|codemap_only`).
- `file_search`: required `pattern`, optional `regex`, `mode` (`auto|path|content|both`), `max_results`, `context_lines`, `count_only`.
- `context_builder`: required `instructions`, `response_type` (`clarify|plan|review`), review-only `review_diff`, optional `max_context_bytes`.
- `oracle_send`: required `message`, `mode` (`chat|question|plan|review`), review-only `review_diff`, optional `clarify_handoff`, optional `max_context_bytes`.

Use the live schema as authoritative for bounds and required fields.

## Result semantics

Provider-backed calls send one immutable prompt to mandatory concurrent Primary and Secondary lanes. The top-level `response`, `ok`, `error`, `model_raw_id`, and `provider_metadata` project Primary only. `oracle_results.primary` and `.secondary` remain independent. `pair_status` is `completed`, `partial_failure`, or `failed`. There is no synthesis, ranking, or winner.

Provider-backed work fails closed before HTTP if any selected source is omitted, truncated, unsafe, unreadable, non-UTF-8, or unsupported.

## Intentionally unsupported

Do not claim or emulate these RepoPrompt CE capabilities:

- writes, edits, file creation, or deletion;
- autonomous file discovery by `context_builder`;
- `workspace_context` or automatic context export;
- `ask_oracle`, chat continuation, chat logs, or persisted Oracle conversations;
- automatic or synthesized Git diffs;
- MCP-managed exports;
- images or screenshots;
- model overrides in tool arguments;
- Agent Mode, delegated subagents, or orchestration;
- workspace or Oracle persistence.

Use the calling agent's native tools for editing, Git, tests, UI work, and delegation.

