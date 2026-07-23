# RepoPrompt Portable

Portable, UI-free RepoPrompt context building and dual-Oracle MCP for Linux and containers.

The image packages:

- A read-only stdio MCP server.
- Deterministic selected-file and slice context building.
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
