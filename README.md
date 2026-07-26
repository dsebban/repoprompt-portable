# RepoPrompt Portable

Portable, UI-free RepoPrompt context building and dual-Oracle MCP for Linux and containers.

The image contains both `repoprompt-headless`, a read-only stdio MCP server, and `repoprompt-portable-cli`, a direct JSONL command runner. It renders only the caller's explicit file/slice selection and sends mandatory concurrent Primary and Secondary requests for provider-backed work. It has no Apple UI dependency.

Third-party coding agents can install or load the repository skill at
`.agents/skills/repoprompt-portable-workflows/SKILL.md`. It includes transport
routing, CLI and MCP references, plan/investigation/review/Pro Edit recipes,
and the portable-vs-CE capability boundary. See
[Third-party agent integration](docs/third-party-agent-integration.md) for
installation and capability negotiation.

Portable software `0.3.0` advertises tool-schema version `1.1.0` on every tool input schema.

## Tool contract

`manage_selection` is the only selection mutation interface.

- `context_builder` accepts `clarify|plan|review|pro_edit`. Clarify is local; the other modes use the configured Oracle provider.
- `oracle_send` accepts `chat|question|plan|review` and always snapshots and attaches the current explicit selection; there is no context-free mode.
- Provider-backed calls fail with `incomplete_workspace_context` before HTTP if any selected source is omitted or truncated. Use local clarify to inspect omissions.
- Review mode may include a caller-supplied `review_diff` of at most 262144 UTF-8 bytes.
- `oracle_send` may include prior clarify output as `clarify_handoff`, up to 1048576 UTF-8 bytes.
- Workspace source, review diffs, and clarify handoffs are labeled untrusted evidence and disclosed unchanged to both lanes. Only the user-request section is instruction-bearing.
- Pro Edit returns two independent opaque Pro Edit v1 instruction artifacts under `oracle_results.primary.response` and `.secondary.response`; top-level `response` projects Primary only. Portable does not parse, validate, delegate, apply, write, persist, or certify either artifact.

See [the architecture and configuration guide](docs/architecture/portable-oracle-mcp.md) for the complete schema, provider metadata/error fields, and security boundary.

## Run an immutable image

Prefer the signed index digest from a release's `container-digests.json`; do not deploy mutable `latest` as a pin.

```bash
IMAGE='ghcr.io/dsebban/repoprompt-portable@sha256:<verified-index-digest>'
docker run --rm -i \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  "$IMAGE" --no-persist --root /workspace
```

The image defaults to non-root UID/GID `10001`. If host permissions require the host identity, add `--user "$(id -u):$(id -g)" --env HOME=/tmp`. Pass only the provider environment variables the chosen Oracle needs; provider-free clarify does not need `OPENCODE_API_KEY`.

### Direct CLI

Override the entry point and repeat `-e` to share one in-memory selection:

```bash
docker run --rm \
  --entrypoint repoprompt-portable-cli \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  "$IMAGE" \
  --root /workspace \
  -e 'manage_selection {"op":"set","mode":"full","paths":["README.md"]}' \
  -e 'context_builder {"instructions":"Assemble the selected file.","response_type":"clarify"}'
```

Generate Pro Edit instructions from the same explicit selection in one process:

```bash
repoprompt-portable-cli --root "$PWD" \
  -e 'manage_selection {"op":"set","mode":"full","paths":["README.md"]}' \
  -e 'context_builder {"instructions":"Update the selected documentation for the new contract.","response_type":"pro_edit"}'
```

The Pro Edit v1 generation contract requests exactly one `<chatName="..."/>`, one `<Plan>...</Plan>`, and zero or more `<file>` blocks whose only actions are `delegate edit` for selected existing files or `create` for genuinely new files inside a loaded root. In multi-root workspaces, delegated paths must preserve the exact selected `root[n]:relative/path`; single-root delegated paths preserve the exact selected relative path. Missing required existing files belong in `<Plan>` only, with no fabricated file block.

Treat generated paths and content as untrusted. Defensively review both lanes against the selection, choose deliberately, then implement and test with the calling agent's native tools. Portable performs no edit execution or application and has no `agent_run`, write, or orchestration tool.

The CLI accepts exact portable tool names and JSON-object arguments. Separate processes do not share selection. `--export-jsonl <new-path>` preserves stdout and, only after all commands succeed, atomically creates a private mode-0600 JSONL artifact. Existing files and symlinks are refused; exports are never overwritten. Because exports can contain selected source and both generated artifacts, write them to a private, separately mounted output directory outside the read-only workspace.

### OpenCode

OpenCode is a separate entry point in the same image. Its default OpenCode Go provider requires `OPENCODE_API_KEY`:

```bash
docker run --rm -it \
  --entrypoint opencode \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  --env OPENCODE_API_KEY \
  "$IMAGE"
```

Do not pass `OPENCODE_API_KEY` when the headless server is configured only with an explicit `REPOPROMPT_ORACLE_*` provider such as Surf.

## Oracle = Surf on Cursor Cloud

A concise, version-checked pattern is:

1. Run Surf's authenticated OpenAI-compatible server on the Cursor Cloud Linux host.
2. Run the digest-pinned portable image with hardened flags and Linux `--network host`, so Surf can remain bound to loopback.
3. Set both model IDs to Surf's compound `gpt-5.6-sol-xhigh` ID and send matching top-level `reasoning_effort: xhigh` through `REPOPROMPT_ORACLE_REASONING_EFFORT`.
4. Keep the bearer token in the Cursor Cloud secret environment. Portable receives only the environment-variable name; Surf 2.13.3's documented server interface still expands the token into its local `--api-key` process argument, so run Surf under an isolated user and keep process listings and logs private.

The full copy/paste recipe, bridge alternatives for Linux and Docker Desktop, and the capability probe are in [Oracle = Surf on Cursor Cloud](docs/architecture/portable-oracle-mcp.md#oracle--surf-on-cursor-cloud). Surf CLI `2.13.3` help, OpenAPI, and model discovery were checked directly; portable's completion contract is exercised by the authenticated fixture smoke, not by a live browser-model completion.

## Develop and test

```bash
swift build --product repoprompt-headless
swift build --product repoprompt-portable-cli
swift test
python3 Scripts/test_verify_portable_release.py
python3 Scripts/verify_portable_release.py source --expected-version 0.3.0
bash -n Scripts/smoke_portable_oracle_docker.sh Scripts/smoke_portable_host_gateway.sh
bash Scripts/smoke_portable_oracle_docker.sh
# Linux only; reuse the image built above:
RP_PORTABLE_IMAGE=repoprompt-headless:portable-smoke \
  RP_PORTABLE_SKIP_BUILD=1 \
  bash Scripts/smoke_portable_host_gateway.sh
```

The authenticated fake provider is local and requires no paid API key. The main smoke exercises the installed CLI, private export, fail/metadata paths, and hardened bridge networking. The Linux smoke exercises `host.docker.internal:host-gateway`.

## Releases and verification

GitHub Actions builds `linux/amd64` and `linux/arm64` candidates by digest, smokes each candidate before creating the multi-architecture index, signs and attests the verified index, and—on releases—verifies every release asset before promoting tags. A release promotes immutable `v0.3.0`, `0.3.0`, and `sha-<full-commit>` tags. Digests and release assets are also immutable; `latest` is the only movable tag.

A tagged release includes:

- `container-digests.json` with the index and platform digests;
- Docker-loadable per-platform archives;
- per-platform SPDX JSON SBOMs;
- hardened run/Compose examples and the release policy;
- `SHA256SUMS` plus a keyless Sigstore bundle;
- GitHub build-provenance attestations for checksummed assets.

After `gh release download v0.3.0`, verify before use:

```bash
sha256sum --check SHA256SUMS
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity 'https://github.com/dsebban/repoprompt-portable/.github/workflows/publish-container.yml@refs/tags/v0.3.0' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS

gh attestation verify repoprompt-portable-v0.3.0-linux-amd64.docker.tar.gz \
  --repo dsebban/repoprompt-portable

IMAGE="$(python3 -c 'import json; d=json.load(open("container-digests.json")); print(d["image"]+"@"+d["index_digest"])')"
cosign verify \
  --certificate-identity 'https://github.com/dsebban/repoprompt-portable/.github/workflows/publish-container.yml@refs/tags/v0.3.0' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "$IMAGE"
gh attestation verify "oci://$IMAGE" \
  --repo dsebban/repoprompt-portable \
  --signer-workflow dsebban/repoprompt-portable/.github/workflows/publish-container.yml
```

The SPDX files are covered by the signed checksum file and asset attestations. A signature, attestation, checksum, SBOM, archive, or smoke failure blocks publication; there is no unsigned fallback. Rollback moves only `latest` to a previously verified and signed digest. Immutable version tags and release assets are never replaced. A digest associated with a credential exposure is ineligible for release or rollback until the credential is revoked or rotated and the replacement is confirmed outside this repository.

## License

MIT
