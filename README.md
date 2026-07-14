# dumb-coder-ops

Infrastructure and launch scripts for [dumb-coder](../dumb-coder) — the model
backends and the verify sandbox image. These are **environment/rig concerns**,
kept out of the application repo so swapping models or tuning the rig never
churns the source tree.

Nothing here compiles dumb-coder's source. The pieces that *do* (the MCP server
image) stay in the main repo under `docker/mcp/`.

## Contents

### `scripts/` — llama.cpp backend launchers (PowerShell, Windows)

Stock `ghcr.io/ggml-org/llama.cpp:server-cuda` containers serving GGUF models on
this box's two GPUs. dumb-coder reaches them over HTTP (OpenAI-compatible API);
it has no knowledge of these scripts.

| Script | Backend | Endpoint |
|--------|---------|----------|
| `coder-30b.ps1` | `qwen3-coder-30b-a3b` MoE, split across both GPUs (`--tensor-split 12,8`) — the daily driver | `:11435` |
| `pool-8b.ps1` | Two Qwen3-8B pools (one per GPU, `-np` slots) — the parallel MCP swarm fallback | `:11439`, `:11440` |

Each takes `-Down` to tear down. The 30B and the 8B swarm compete for the same
VRAM — run one or the other.

```powershell
pwsh scripts/coder-30b.ps1          # bring the 30B up
pwsh scripts/coder-30b.ps1 -Down    # tear it down
```

### `docker/pyenv/` — the verify sandbox image

A pinned Python toolkit (pytest + deps) that dumb-coder runs generated code in,
so a build can't depend on or pollute the host. dumb-coder references it **by
image name** (`dumb-coder-pyenv`), so it just needs to exist in the local Docker
daemon — build it once:

```powershell
docker build -t dumb-coder-pyenv docker/pyenv
```

## Relationship to dumb-coder

- **Backends** (`scripts/`): decoupled — HTTP only. The endpoint/model dumb-coder
  talks to lives in `%APPDATA%\dumb-coder\config.json` (or `DC_BASE_URL`/`DC_MODEL`),
  not in either repo.
- **Verify image** (`docker/pyenv/`): decoupled — referenced by name.
- **MCP server image**: NOT here. It lives in `dumb-coder/docker/mcp/` because it
  `COPY . .` + `cargo build`s the workspace — it must be built with dumb-coder as
  the Docker context, so it belongs with the code.
