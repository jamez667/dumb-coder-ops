# Launch the qwen3-coder-30b-a3b MoE split across BOTH GPUs — the daily-driver
# backend for smart-coder (strictly beats the 8B; clears the whole difficulty ladder).
#
# ONE model, weights tensor-split across the pair. It's MoE (30B total / ~3B active
# per token) so very little crosses the slow PCIe-4x link — the asymmetric 16x/4x
# rig doesn't bottleneck, and it's actually FASTER than the single-card 8B.
#
#   Container sc-coder30b -> :11435, alias `qwen3-coder-30b`
#   --tensor-split 12,8   pack the FAST card (3080Ti/16x); speed scales with weight
#                         on it (12,8 => ~112 tok/s; 8,6 => only 76). Counterintuitive
#                         but measured on this box.
#   -c 32768              KV cache is PRE-ALLOCATED at load, won't grow/OOM as the
#                         session fills. 32k is the model's NATIVE trained context (Qwen3-
#                         Coder) — full context with NO YaRN rope-scaling penalty. The KV
#                         (MoE + GQA → small) costs ~3.3GB; the freed 3080 headroom (voice
#                         pipeline uses a separate 4B/8B, not co-resident) absorbs it.
#                         Was 24k when the 3080 reserved ~3.4GB for the voice engine.
#
# Expect ~11.6GB on the 3080Ti + ~7GB on the 3080, ~140 tok/s warm, full Q3.
#
# Usage:  pwsh scripts/coder-30b.ps1          # bring it up
#         pwsh scripts/coder-30b.ps1 -Down    # tear it down
param([switch]$Down)

$name  = "sc-coder30b"
$model = "/models/qwen3-coder-30b-a3b-instruct-q3_k_m.gguf"
$image = "ghcr.io/ggml-org/llama.cpp:server-cuda"
$mount = "C:\Users\mail\.ai\llm:/models"
$port  = 11435

if ($Down) {
    docker rm -f $name 2>$null | Out-Null
    "torn down"
    return
}

docker rm -f $name 2>$null | Out-Null
# `--gpus all` exposes both cards; -ts splits the weights across them.
docker run -d --name $name --gpus all `
    -p "$($port):8080" `
    -v $mount `
    $image `
    -m $model -ngl 99 --tensor-split 12,8 -c 32768 --cont-batching --jinja `
    --host 0.0.0.0 --port 8080 --alias qwen3-coder-30b | Out-Null
"launched $name on :$port (tensor-split 12,8, -c 32768)"

"`nwaiting for the server to serve (weights are 14GB — give it a minute)..."
$ok = $false
foreach ($n in 1..180) {
    try { Invoke-RestMethod "http://localhost:$port/v1/models" -TimeoutSec 2 | Out-Null; $ok = $true; break }
    catch {
        if ((docker inspect $name --format "{{.State.Status}}" 2>$null) -eq "exited") { break }
        Start-Sleep -Seconds 1
    }
}
"${name}: " + $(if ($ok) { "READY on :$port" } else { "FAILED"; docker logs $name --tail 20 })

"`n=== VRAM ==="
nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader
