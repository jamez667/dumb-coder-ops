# Launch Qwen3.6-27B (DENSE, Q4_K_M) split across BOTH GPUs — trial backend for
# smart-coder, to A/B against the shipped qwen3-coder-30b.
#
# NOTE vs coder-30b.ps1: this model is DENSE (27B params, all active per token), NOT
# an MoE. Splitting a dense model DOES push activations across the slow PCIe-4x link
# every layer, so it may be slower per-token than the 30B MoE — that's expected. (The
# "never split across 4x" rule is about MoE experts; a dense split just pays the link
# cost for real work.) Bias weight onto the FAST 3080Ti (16x) with -ts 13,7.
#
# ARCH WARNING: Qwen3.6 uses Gated DeltaNet (linear-attention) + a Vision encoder.
# llama.cpp support for these lands LATE — if the server loads but replies with
# garbage/repeats, the build is too old: `docker pull ghcr.io/ggml-org/llama.cpp:server-cuda`
# and relaunch. ALWAYS eyeball the smoke-test reply below before trusting it.
#
#   Container sc-qwen36 -> :11436, alias `qwen3.6-27b`  (30B stays on :11435)
#   Q4_K_M weights ~15.7GB. TUNED CONFIG (measured on this rig):
#     --tensor-split 10,10   BALANCED split. Dense-model tok/s is ~37 regardless of split
#                            (it's serially link-bound either way), so optimize the split for
#                            VRAM BALANCE to maximize context, NOT for speed. 10,10 gives the
#                            most even headroom; 11,9/12,8 over-fill the Ti and cap context.
#     -c 32768               FULL native context (Qwen3-Coder trained max, NO YaRN). Loads with
#                            GPU0 ~1.2GB free / GPU1 ~0.4GB free. GPU1 is the limiter.
#   Result: GPU0 ~10.9GB, GPU1 ~9.7GB, ~20.5GB total, 32k ctx, ~37 tok/s.
#   NOTE: 15.7GB loads to RAM first then transfers to GPU near the end — ready takes ~80-90s.
#   DON'T kill it early thinking it's stuck in RAM; VRAM fills only in the last few seconds.
#
# Usage:  pwsh scripts/coder-qwen36.ps1          # bring it up
#         pwsh scripts/coder-qwen36.ps1 -Down    # tear it down
param([switch]$Down)

$name  = "sc-qwen36"
$model = "/models/Qwen3.6-27B-MTP-Q4_K_M.gguf"
$image = "ghcr.io/ggml-org/llama.cpp:server-cuda"
$mount = "C:\Users\mail\.ai\llm:/models"
$port  = 11436

if ($Down) {
    docker rm -f $name 2>$null | Out-Null
    "torn down"
    return
}

docker rm -f $name 2>$null | Out-Null
# Dense model: BALANCED split (10,10) maximizes context headroom; -c 32768 = full native ctx.
# See header for why balance > bias here (tok/s is split-independent for a dense split).
docker run -d --name $name --gpus all `
    -p "$($port):8080" `
    -v $mount `
    $image `
    -m $model -ngl 99 --tensor-split 10,10 -c 32768 --cont-batching --jinja `
    --host 0.0.0.0 --port 8080 --alias qwen3.6-27b | Out-Null
"launched $name on :$port (tensor-split 10,10, -c 32768)"

"`nwaiting for the server to serve (weights are ~16GB — give it a minute)..."
$ok = $false
foreach ($n in 1..240) {
    try { Invoke-RestMethod "http://localhost:$port/v1/models" -TimeoutSec 2 | Out-Null; $ok = $true; break }
    catch {
        if ((docker inspect $name --format "{{.State.Status}}" 2>$null) -eq "exited") { break }
        Start-Sleep -Seconds 1
    }
}
if (-not $ok) {
    "${name}: FAILED to start"
    docker logs $name --tail 30
    return
}
"${name}: READY on :$port"

# SMOKE TEST — coherence check. A too-old llama.cpp loads DeltaNet weights but emits
# garbage; this catches it before you wire the model into the harness.
"`n=== SMOKE TEST (must be coherent) ==="
$body = @{
    model    = "qwen3.6-27b"
    messages = @(@{ role = "user"; content = "Reply with exactly: BACKEND OK" })
    max_tokens = 16
} | ConvertTo-Json -Depth 5
try {
    $r = Invoke-RestMethod "http://localhost:$port/v1/chat/completions" -Method Post `
        -ContentType "application/json" -Body $body -TimeoutSec 60
    "reply: " + $r.choices[0].message.content
} catch { "smoke test FAILED: $_" }

"`n=== VRAM ==="
nvidia-smi --query-gpu=index,memory.used,memory.free,memory.total --format=csv,noheader
