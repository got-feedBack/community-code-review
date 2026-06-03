#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────
#  Volunteer — entrypoint.sh
#  Self-configures at startup. For any organization using self-hosted AI code reviews.
# ──────────────────────────────────────────────────────────────────────────
set -e

# ══════════════════════════════════════════════════════════════════════════
# ENVIRONMENT VARIABLES REFERENCE
# ══════════════════════════════════════════════════════════════════════════
#
#  COORDINATOR_URL     (required)  e.g. http://coordinator.example.com:8080
#  VOLUNTEER_ID        (optional)  e.g. "alice-rtx4090" — defaults to hostname
#  VOLUNTEER_SECRET    (optional)  shared secret for coordinator auth
#
#  MODEL_REPO          (optional)  HuggingFace repo, e.g. "Qwen/Qwen3-30B-A3B-GGUF"
#  MODEL_FILE          (optional)  GGUF filename, default: qwen3-30b-a3b-q4_k_m.gguf
#  MODEL_URL           (optional)  Direct download URL (overrides MODEL_REPO)
#
#  GPU_DEVICES         (optional)  GPU selection:
#                                  "" | unset → auto-detect first available GPU
#                                  "0"        → use first GPU (same as default)
#                                  "all"      → use all visible GPUs
#                                  "0,1"      → use specific GPU indices
#                                  "none"     → CPU only (no GPU acceleration)
#  LLAMA_PORT          (optional)  llama-server port (default: 8080)
#  LLAMA_N_GPU_LAYERS  (optional)  GPU layers (default: 99 = max offload)
#  LLAMA_CTX_SIZE      (optional)  Context size (default: 32768)
#  LLAMA_N_PARALLEL    (optional)  Parallel slots (default: 1)
# ══════════════════════════════════════════════════════════════════════════

# ── Required ──────────────────────────────────────────────────────────────
COORDINATOR_URL="${COORDINATOR_URL:?COORDINATOR_URL is required — set it to your coordinator's address}"

# ── Defaults ──────────────────────────────────────────────────────────────
VOLUNTEER_ID="${VOLUNTEER_ID:-$(hostname)-$$}"
MODEL_REPO="${MODEL_REPO:-Qwen/Qwen3-30B-A3B-GGUF}"
MODEL_FILE="${MODEL_FILE:-qwen3-30b-a3b-q4_k_m.gguf}"
MODEL_URL="${MODEL_URL:-}"

LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-32768}"
LLAMA_N_PARALLEL="${LLAMA_N_PARALLEL:-1}"
LLAMA_TEMP="${LLAMA_TEMP:-0.7}"

MODEL_PATH="/models/${MODEL_FILE}"

# ══════════════════════════════════════════════════════════════════════════
# STEP 1 — Banner
# ══════════════════════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Community Code Review Volunteer                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Volunteer ID:     ${VOLUNTEER_ID}"
echo "  Coordinator:      ${COORDINATOR_URL}"
echo "  Model:            ${MODEL_FILE}"
echo "  Context Size:     ${LLAMA_CTX_SIZE}"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# STEP 2 — GPU detection & configuration
# ══════════════════════════════════════════════════════════════════════════

GPU_INFO="CPU (no GPU detected)"
LLAMA_N_GPU_LAYERS="${LLAMA_N_GPU_LAYERS:-99}"  # default to max offload

detect_gpu() {
    if command -v nvidia-smi &>/dev/null; then
        local smi_out
        smi_out="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -5)"
        if [ -n "${smi_out}" ]; then
            GPU_INFO="$(echo "${smi_out}" | head -1)"
            echo "  GPU(s) detected:"
            echo "${smi_out}" | while IFS= read -r line; do
                echo "    ◦ ${line}"
            done
            return 0
        fi
    fi
    return 1  # no GPU found
}

# Determine GPU_DEVICES
case "${GPU_DEVICES:-}" in
    "")
        # Auto-detect — use first available GPU
        if detect_gpu; then
            export CUDA_VISIBLE_DEVICES="0"
            echo "  → Auto-selected GPU 0 (default). Set GPU_DEVICES to override."
        else
            echo "  → No GPU detected. Running on CPU (will be slow)."
            LLAMA_N_GPU_LAYERS=0
        fi
        ;;
    "none")
        echo "  → GPU disabled via GPU_DEVICES=none. Running on CPU."
        LLAMA_N_GPU_LAYERS=0
        ;;
    "all")
        if detect_gpu; then
            unset CUDA_VISIBLE_DEVICES
            echo "  → Using ALL available GPUs."
        else
            echo "  → GPU_DEVICES=all but no GPU detected. Falling back to CPU."
            LLAMA_N_GPU_LAYERS=0
        fi
        ;;
    *)
        # Specific device(s) like "0", "0,1"
        export CUDA_VISIBLE_DEVICES="${GPU_DEVICES}"
        if detect_gpu; then
            echo "  → Using GPU device(s): ${GPU_DEVICES}"
        else
            echo "  → GPU_DEVICES=${GPU_DEVICES} but no GPU detected. Falling back to CPU."
            LLAMA_N_GPU_LAYERS=0
        fi
        ;;
esac

echo "  GPU Layers:       ${LLAMA_N_GPU_LAYERS}"
echo ""
export GPU_INFO  # Pass to agent.py

# ══════════════════════════════════════════════════════════════════════════
# STEP 3 — Model download
# ══════════════════════════════════════════════════════════════════════════

download_model() {
    local url="$1"
    local dest="$2"
    echo "  ↓ Downloading model..."
    echo "    From: ${url}"
    echo "    To:   ${dest}"
    echo ""
    # Use curl with progress bar
    curl -# -L "${url}" -o "${dest}.tmp" 2>&1
    echo ""
    if [ $? -ne 0 ]; then
        echo "  ✗ Download failed! Check MODEL_URL or your internet connection."
        rm -f "${dest}.tmp"
        exit 1
    fi
    mv "${dest}.tmp" "${dest}"
    echo "  ✓ Download complete!"
}

if [ -f "${MODEL_PATH}" ]; then
    echo "  ✓ Model file found: ${MODEL_PATH}"
else
    echo "  ⚠ Model file not found at: ${MODEL_PATH}"
    echo ""

    # Determine download URL
    DOWNLOAD_URL="${MODEL_URL}"
    if [ -z "${DOWNLOAD_URL}" ]; then
        # Construct from HuggingFace repo
        DOWNLOAD_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}"
        echo "  Constructed download URL from MODEL_REPO=${MODEL_REPO}"
    fi

    download_model "${DOWNLOAD_URL}" "${MODEL_PATH}"
    echo ""
fi

# Validate file looks like a GGUF
FILE_SIZE="$(stat -c%s "${MODEL_PATH}" 2>/dev/null || stat -f%z "${MODEL_PATH}" 2>/dev/null)"
if [ "${FILE_SIZE}" -lt 1000000 ]; then
    echo "  ⚠ Warning: Model file is very small (${FILE_SIZE} bytes). It may be corrupt or a placeholder."
fi
echo "  Model size: $(numfmt --to=iec-i "${FILE_SIZE}" 2>/dev/null || echo "${FILE_SIZE} bytes")"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# STEP 4 — Start llama-server (background)
# ══════════════════════════════════════════════════════════════════════════

echo "  Starting llama-server..."
echo ""

LLAMA_SERVER_ARGS=(
    -m "${MODEL_PATH}"
    --host "0.0.0.0"
    --port "${LLAMA_PORT}"
    -ngl "${LLAMA_N_GPU_LAYERS}"
    -c "${LLAMA_CTX_SIZE}"
    -np "${LLAMA_N_PARALLEL}"
    --temp "${LLAMA_TEMP}"
    --no-ui
    --no-warmup
    --metrics
)

echo "    llama-server ${LLAMA_SERVER_ARGS[*]}"
echo ""

llama-server "${LLAMA_SERVER_ARGS[@]}" &
LLAMA_PID=$!
echo "  llama-server started (PID: ${LLAMA_PID})"
echo ""

echo "  Waiting for server to be ready..."
for i in $(seq 1 30); do
    if curl -sf "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then
        echo "  ✓ Server ready! (${i}s)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ Server failed to start within 30 seconds."
        kill "${LLAMA_PID}" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done
echo ""

# ══════════════════════════════════════════════════════════════════════════
# STEP 5 — Start WebSocket agent (connects to coordinator via outbound WS)
# ══════════════════════════════════════════════════════════════════════════

echo "  Starting WebSocket agent..."
cd /app
python3 agent.py &
AGENT_PID=$!
echo "  Agent started (PID: ${AGENT_PID})"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# STEP 6 — Trap signals and wait
# ══════════════════════════════════════════════════════════════════════════

cleanup() {
    echo ""
    echo "  Shutting down..."
    kill "${LLAMA_PID}" "${AGENT_PID}" 2>/dev/null || true
    wait "${LLAMA_PID}" "${AGENT_PID}" 2>/dev/null || true
    echo "  ✓ Volunteer stopped. Thanks for contributing!"
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Volunteer is running — waiting for review requests...   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

wait -n 2>/dev/null || wait