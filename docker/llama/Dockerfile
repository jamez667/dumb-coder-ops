# Thin wrapper over the stock llama.cpp CUDA server image, adding ONE thing: curl.
#
# Why: compose runs a container's healthcheck INSIDE that container, so it needs a
# tool there to hit the server. The stock ghcr.io/ggml-org/llama.cpp:server-cuda
# image ships neither curl nor wget. We add curl so the healthcheck in compose.yaml
# can poll /v1/models until the model finishes loading — that response IS the READY
# signal (`docker compose up --wait` blocks on it), replacing the old host-side poll
# loops in the retired PowerShell launchers.
#
# Build is implicit: `docker compose build` (or `up --build`) builds this from the
# `build:` stanza in compose.yaml. The ENTRYPOINT/CMD are inherited unchanged, so
# every llama-server flag still comes from each service's `command:` in compose.
FROM ghcr.io/ggml-org/llama.cpp:server-cuda

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
