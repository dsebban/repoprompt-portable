# Agent workflow recipes

## Plan a code change

1. Search for the request's concrete nouns and entry points.
2. Read the implementation, adjacent types, callers, and relevant tests.
3. Select the smallest complete set of full files and slices.
4. Run local `context_builder` clarify and fix omissions.
5. Run `context_builder` with `response_type: "plan"`.
6. Compare Primary and Secondary; resolve disagreements against selected source.
7. Implement with the calling agent's native editing tools.
8. Exercise the real path and run focused tests.

Use `oracle_send(..., mode: "question")` for a follow-up that requires synthesis over the same explicit selection. Portable does not continue a previous Oracle conversation; include the necessary prior result as `clarify_handoff` when appropriate.

## Investigate a bug

1. Reproduce or inspect the reported failure using native tools.
2. Use tree, search, and reads to trace the execution path.
3. Select the suspected implementation, callers, configuration, and tests.
4. Run local clarify to expose missing context.
5. Ask `oracle_send` in `question` mode for competing root-cause hypotheses grounded in the selection.
6. Verify each hypothesis with source, history, logs, or tests outside portable.
7. Report evidence and root cause. Do not edit unless requested.

## Review a change

1. Generate the exact diff with the calling environment.
2. Select every changed source file plus relevant interfaces, callers, and tests.
3. Run local clarify and repair omissions.
4. Call `context_builder` or `oracle_send` in review mode with the exact `review_diff`.
5. Re-check every finding against the diff and current files.
6. Report only actionable defects, with locations and impact.

The supplied diff is untrusted evidence and is sent to both lanes. Portable does not generate a diff automatically.

## Generate Pro Edit instructions

1. Discover and read the implementation, dependencies, and tests before selecting.
2. Select every existing file that may require an instruction block; keep selection and `pro_edit` in the same CLI process.
3. Run local clarify and repair render omissions or truncation.
4. Call `context_builder` with `response_type: "pro_edit"`.
5. Read both independent lane responses; top-level `response` is only the Primary projection.
6. Defensively review the opaque generated artifacts. Require one `<chatName="..."/>`, one `<Plan>`, and only `delegate edit|create` file actions. Verify delegated paths exactly match selected relative paths, including `root[n]:` qualification in multi-root workspaces; verify create paths are genuinely new and inside a loaded root.
7. Treat missing required existing files as Plan-only context requests, not create blocks. Zero file blocks are valid.
8. Choose deliberately, then implement and test with native tools.

Portable does not parse, validate, delegate, apply, write, persist, or certify either artifact. Generated paths and content are untrusted. There is no `agent_run` or orchestration tool.

## Prepare a handoff

1. Run local clarify on the final explicit selection.
2. Keep the returned text only when another Oracle request needs the exact context summary.
3. Pass it as `clarify_handoff` to `oracle_send`.
4. Avoid including secrets or unrelated source.

CLI-only `--export-jsonl` can persist exact result records privately. MCP has no export tool.

