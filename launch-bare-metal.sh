#!/usr/bin/env bash
# Southpaw's Turbohaul — Bare Metal Launcher
# Uses pre-built AtomicBot llama-server + existing models on disk.
# No Docker required.
#
# Usage:
#   ./launch-bare-metal.sh                    # auto-detect, start on :11401
#   ./launch-bare-metal.sh --port 11402       # custom port
#   ./launch-bare-metal.sh --bg               # background mode

set -euo pipefail

ATOMIC_BUILD="${ATOMIC_BUILD:-${HOME}/projects/LLM-Infra/llama.cpp-atomic/build/bin}"
MODEL_DIR="${MODEL_DIR:-${HOME}/Models/storage/gguf}"
TURBOHAUL_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${TURBOHAUL_PORT:-11401}"
BG_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --bg)   BG_MODE=true; shift ;;
        *)      echo "Unknown: $1"; exit 1 ;;
    esac
done

# Verify atomic build exists
if [[ ! -f "${ATOMIC_BUILD}/llama-server" ]]; then
    echo "ERROR: AtomicBot llama-server not found at ${ATOMIC_BUILD}/llama-server"
    echo "Build it first: cd ~/projects/LLM-Infra/llama.cpp-atomic && cmake -B build -DGGML_CUDA=ON && cmake --build build -j\$(nproc)"
    exit 1
fi

# Set LD_LIBRARY_PATH so the atomic binary finds its own libs
export LD_LIBRARY_PATH="${ATOMIC_BUILD}:${LD_LIBRARY_PATH:-}"

# Verify the binary works
echo "=== llama-server version ==="
"${ATOMIC_BUILD}/llama-server" --version 2>&1 || { echo "ERROR: llama-server failed to start"; exit 1; }

# Check for models
echo ""
echo "=== Available Models ==="
ls -lh "${MODEL_DIR}"/Darwin-28B-REASON.*.gguf 2>/dev/null || echo "  (no Darwin models)"
ls -lh "${MODEL_DIR}"/Qwen3.6-35B-A3B-APEX-MTP-*.gguf 2>/dev/null || echo "  (no APEX-MTP models)"

# Install turbohaul if not already
if ! python3 -c "import turbohaul" 2>/dev/null; then
    echo ""
    echo "=== Installing turbohaul ==="
    cd "${TURBOHAUL_DIR}"
    pip install -e . 2>&1 | tail -3
    pip install jsonschema==4.21.1 2>/dev/null
fi

# Create state dir
mkdir -p "${TURBOHAUL_DIR}/state"

# Set environment
export TURBOHAUL_CONFIG_PATH="${TURBOHAUL_DIR}/docker/turbohaul.default.yaml"
export TURBOHAUL_ALLOW_PUBLIC_BIND=1
export SOUTHPAW_MODEL_DIR="${MODEL_DIR}"

# Override the llama_server_binary in config to point at atomic build
export TURBOHAUL_LLAMA_BINARY="${ATOMIC_BUILD}/llama-server"

echo ""
echo "=== Starting Southpaw Turbohaul on :${PORT} ==="
echo "  Binary: ${ATOMIC_BUILD}/llama-server"
echo "  Models: ${MODEL_DIR}"
echo "  State:  ${TURBOHAUL_DIR}/state"
echo ""

# Patch the default config to use our binary
CONFIG_FILE="${TURBOHAUL_DIR}/state/turbohaul-runtime.yaml"
cat > "${CONFIG_FILE}" <<EOF
server:
  host: 127.0.0.1
  port: ${PORT}
  allow_public_bind: true

storage:
  blob_store_path: ${TURBOHAUL_DIR}/state/blobs
  manifests_path: ${TURBOHAUL_DIR}/state/manifests
  import_allowed_root: ${MODEL_DIR}
  state_db_path: ${TURBOHAUL_DIR}/state/state.sqlite

runtime:
  llama_server_binary: ${ATOMIC_BUILD}/llama-server
  default_port_base: 11500

ui:
  enabled: true
  static_path: ${TURBOHAUL_DIR}/src/frontend/dist

queue:
  max_parallel_sidecars: 1
  grace_seconds: 30
  idle_hot_load_seconds: 600
  loading_health_timeout_s: 600

pull:
  hf_api_key_env: HF_API_KEY
  pull_concurrency: 2
EOF

if [[ "$BG_MODE" == "true" ]]; then
    nohup turbohaul-manager --config "${CONFIG_FILE}" > "${TURBOHAUL_DIR}/state/turbohaul.log" 2>&1 &
    PID=$!
    echo "Started in background (PID: ${PID})"
    echo "Logs: ${TURBOHAUL_DIR}/state/turbohaul.log"
    echo "Health check: curl http://127.0.0.1:${PORT}/health"
else
    exec turbohaul-manager --config "${CONFIG_FILE}"
fi
