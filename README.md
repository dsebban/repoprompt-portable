# RepoPrompt Portable

Portable, UI-free RepoPrompt context building and dual-Oracle MCP for Linux and containers.

The image packages:

- A read-only stdio MCP server and direct `repoprompt-portable-cli` executable.
- Deterministic selected-file and slice context building.
- Local builder clarification plus provider-backed builder plan/review generation.
- Mandatory independent Primary and Secondary Oracle requests.
- OpenCode 1.18.4 with `opencode-go/deepseek-v4-flash` defaults.
- No AppKit, SwiftUI, Xcode, or other Apple UI dependency.

## Run

```bash
docker run --rm -i \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  --env OPENCODE_API_KEY \
  ghcr.io/dsebban/repoprompt-portable:latest \
  --no-persist --root /workspace
```

Run the direct CLI from the same image by overriding the default MCP entry point. Repeat `-e` to share one in-memory selection across commands:

```bash
docker run --rm \
  --entrypoint repoprompt-portable-cli \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  ghcr.io/dsebban/repoprompt-portable:latest \
  --root /workspace \
  -e 'manage_selection {"op":"set","mode":"full","paths":["README.md"]}' \
  -e 'context_builder {"instructions":"Assemble the selected file.","response_type":"clarify"}'
```

The CLI accepts only exact portable tool names and JSON-object arguments. Separate processes do not share selection; save output with normal shell redirection.

Run OpenCode from the same image:

```bash
docker run --rm -it \
  --entrypoint opencode \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  --env OPENCODE_API_KEY \
  ghcr.io/dsebban/repoprompt-portable:latest
```

See [the architecture and configuration guide](docs/architecture/portable-oracle-mcp.md) for the tool contract, provider variables, security model, and smoke-test instructions.

## Develop and test

```bash
swift build --product repoprompt-headless
swift build --product repoprompt-portable-cli
swift test
bash Scripts/smoke_portable_oracle_docker.sh
```

The deterministic Docker smoke uses a local authenticated fixture provider and does not require a paid API key.

## Images

GitHub Actions publishes multi-architecture `linux/amd64` and `linux/arm64` images to:

```text
ghcr.io/dsebban/repoprompt-portable
```

`main` publishes `latest` and a commit SHA tag. Git tags matching `v*` also publish semantic-version tags.

## License

MIT
