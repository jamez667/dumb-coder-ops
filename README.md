# smart-coder-ops

Infrastructure and launch scripts for [smart-coder](../smart-coder) — the model
backends and the verify sandbox image. These are **environment/rig concerns**,
kept out of the application repo so swapping models or tuning the rig never
churns the source tree.

Nothing here compiles smart-coder's source. The pieces that *do* (the MCP server
image) stay in the main repo under `docker/mcp/`.

## Contents

### `compose.yaml` — llama.cpp backend launchers

Stock `ghcr.io/ggml-org/llama.cpp:server-cuda` (wrapped to add `curl` — see
`docker/llama/`) serving GGUF models on this box's two GPUs. smart-coder reaches
them over HTTP (OpenAI-compatible API); it has no knowledge of this file.

| Service (profile) | Backend | Endpoint |
|--------|---------|----------|
| `sc-coder30b` (`coder30b`) | `qwen3-coder-30b-a3b` MoE, split across both GPUs (`--tensor-split 12,8`) — the daily driver | `:11435` |
| `sc-qwen8b-pool` / `-pool2` (`pool8b`) | Two Qwen3-8B pools (one per GPU, `-np` slots) — the parallel MCP swarm fallback | `:11439`, `:11440` |

Nothing starts without a **profile**. The 30B and the 8B swarm compete for the
same VRAM — run one profile or the other, never both.

```powershell
# 30B daily driver — --wait blocks until the model is loaded and serving
docker compose --profile coder30b up --build --wait
docker compose --profile coder30b down

# Both 8B pools (5 concurrent agents total)
docker compose --profile pool8b up --build --wait
docker compose --profile pool8b down
```

`--wait` returns when the in-container healthcheck passes (curl hits `/v1/models`),
i.e. the moment the model finishes loading — no host-side polling. `--build` is a
~5s no-op once the wrapper image is cached.

**VRAM glance** (host-side — a container can't see the whole rig):

```powershell
nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader
```

**8B pools** round-robin behind the MCP — point it at both with:

```
SC_BASE_URLS=http://host.docker.internal:11439/v1,http://host.docker.internal:11440/v1
```

> **First-run note:** compose requests GPUs via `deploy.resources` (the documented
> equivalent of `--gpus all`); the pools additionally pin one card via
> `CUDA_VISIBLE_DEVICES`. Verify GPU passthrough on your Docker Desktop / WSL2 setup
> the first time — `nvidia-smi` inside the container, or just watch the load succeed.

### `docker/llama/` — the healthcheck-capable llama.cpp image

Three lines: `FROM` the stock llama.cpp server image + `apt-get install curl`, so
compose's healthcheck can poll the model from inside the container. Built
automatically by `docker compose --build`.

### `docker/pyenv/` — the verify sandbox image

A pinned Python toolkit (pytest + deps) that smart-coder runs generated code in,
so a build can't depend on or pollute the host. smart-coder references it **by
image name** (`smart-coder-pyenv`), so it just needs to exist in the local Docker
daemon — build it once:

```powershell
docker build -t smart-coder-pyenv docker/pyenv
```

## Relationship to smart-coder

- **Backends** (`compose.yaml`): decoupled — HTTP only. The endpoint/model smart-coder
  talks to lives in `%APPDATA%\smart-coder\config.json` (or `SC_BASE_URL`/`SC_MODEL`),
  not in either repo.
- **Verify image** (`docker/pyenv/`): decoupled — referenced by name.
- **MCP server image**: NOT here. It lives in `smart-coder/docker/mcp/` because it
  `COPY . .` + `cargo build`s the workspace — it must be built with smart-coder as
  the Docker context, so it belongs with the code.
