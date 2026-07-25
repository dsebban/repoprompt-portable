# Direct CLI reference

## Invocation

```text
repoprompt-portable-cli [global options] <exact-tool-name> ['<JSON object>']
repoprompt-portable-cli [global options] -e '<exact-tool-name> [JSON object]' [-e ...]
```

Global options:

- `--root <path>`: repeatable workspace root; defaults to current directory.
- `--workspace-name <name>`: optional display name.
- `--session-id <uuid>`: optional in-process context UUID.
- `--export-jsonl <new-path>`: atomically create a private mode-0600 result file.
- `-e|--exec <command>`: repeat commands in one process and selection.

Success writes one compact JSON object per command to stdout. Diagnostics and tool errors use stderr. Stop at the first failed command.

## Common commands

Discover:

```bash
repoprompt-portable-cli --root "$PWD" \
  -e 'get_file_tree {"mode":"folders","max_depth":3}' \
  -e 'file_search {"pattern":"RetryPolicy","mode":"both","max_results":50}' \
  -e 'read_file {"path":"Sources/Client.swift","start_line":1,"limit":220}'
```

Select full files and render locally:

```bash
repoprompt-portable-cli --root "$PWD" \
  -e 'manage_selection {"op":"set","mode":"full","paths":["Sources/Client.swift","Tests/ClientTests.swift"]}' \
  -e 'context_builder {"instructions":"Describe the selected implementation and identify missing context.","response_type":"clarify"}'
```

Select slices:

```bash
repoprompt-portable-cli --root "$PWD" \
  -e 'manage_selection {"op":"set","mode":"slices","slices":[{"path":"Sources/Large.swift","ranges":[{"start_line":80,"end_line":210}]}]}' \
  -e 'manage_selection {"op":"add","mode":"full","paths":["Sources/Types.swift"]}' \
  -e 'context_builder {"instructions":"Plan the requested change using only this explicit selection.","response_type":"plan"}'
```

Review a caller-generated diff:

```bash
repoprompt-portable-cli --root "$PWD" \
  -e 'manage_selection {"op":"set","mode":"full","paths":["Sources/Client.swift","Tests/ClientTests.swift"]}' \
  -e 'oracle_send {"message":"Review for correctness, regressions, and missing tests.","mode":"review","review_diff":"<caller-supplied diff>"}'
```

Shell-quote the whole JSON object. Generate large or untrusted arguments programmatically rather than interpolating them into shell source.

## Private exports

`--export-jsonl <path>` preserves stdout and creates the destination only after all commands succeed. The parent directory must exist. Existing files, symlinks, directories, and filesystems without atomic no-replace support are refused.

Exports can contain source and provider responses. Store them outside the read-only workspace in a private, separately mounted output directory.

