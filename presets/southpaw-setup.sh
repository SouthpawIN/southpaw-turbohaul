#!/usr/bin/env bash
# Southpaw's Turbohaul Setup Script
# Auto-detects hardware, selects optimal model quants, downloads if needed,
# registers manifests with Turbohaul, and starts the server.
#
# Usage:
#   southpaw-setup                    # auto-detect hardware, setup everything
#   southpaw-setup --preset dual-3090 # force a specific hardware preset
#   southpaw-setup --list             # show available presets
#   southpaw-setup --dry-run          # show what would happen without doing it

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRESETS_FILE="${SOUTHPAW_PRESETS_FILE:-/etc/turbohaul/southpaw-presets.yaml}"
MODEL_DIR="${SOUTHPAW_MODEL_DIR:-${HOME}/Models/storage/gguf}"
TURBOHAUL_HOST="${TURBOHAUL_HOST:-http://127.0.0.1:11401}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[southpaw]${NC} $*"; }
warn() { echo -e "${YELLOW}[southpaw]${NC} $*"; }
err()  { echo -e "${RED}[southpaw]${NC} $*" >&2; }

# ---------- Hardware Detection ----------

detect_gpus() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo "none"
        return
    fi

    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits 2>/dev/null || echo "none"
}

get_total_vram() {
    local gpu_info
    gpu_info=$(detect_gpus)
    if [[ "$gpu_info" == "none" ]]; then
        echo 0
        return
    fi
    echo "$gpu_info" | awk -F', ' '{sum += $3} END {print sum}'
}

get_gpu_count() {
    local gpu_info
    gpu_info=$(detect_gpus)
    if [[ "$gpu_info" == "none" ]]; then
        echo 0
        return
    fi
    echo "$gpu_info" | wc -l
}

get_single_gpu_vram() {
    local gpu_info
    gpu_info=$(detect_gpus)
    if [[ "$gpu_info" == "none" ]]; then
        echo 0
        return
    fi
    # Return the smallest GPU VRAM (for conservative matching)
    echo "$gpu_info" | awk -F', ' 'NR==1{min=$3} {if($3<min) min=$3} END{print min}'
}

detect_hardware_preset() {
    local gpu_count single_vram
    gpu_count=$(get_gpu_count)
    single_vram=$(get_single_gpu_vram)

    if [[ "$gpu_count" -eq 0 ]]; then
        echo "api-only"
    elif [[ "$gpu_count" -ge 2 && "$single_vram" -ge 20000 ]]; then
        echo "dual-24gb"
    elif [[ "$gpu_count" -ge 2 && "$single_vram" -ge 40000 ]]; then
        echo "dual-48gb"
    elif [[ "$single_vram" -ge 40000 ]]; then
        echo "single-48gb"
    elif [[ "$single_vram" -ge 20000 ]]; then
        echo "single-24gb"
    elif [[ "$single_vram" -ge 14000 ]]; then
        echo "single-16gb"
    elif [[ "$single_vram" -ge 6000 ]]; then
        echo "single-8gb"
    else
        echo "api-only"
    fi
}

# ---------- Model Download ----------

download_model() {
    local url="$1"
    local dest="$2"
    local filename
    filename=$(basename "$dest")

    if [[ -f "$dest" ]]; then
        log "Already downloaded: ${filename}"
        return 0
    fi

    log "Downloading ${filename}..."
    mkdir -p "$(dirname "$dest")"

    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url"
    elif command -v curl &>/dev/null; then
        curl -L --progress-bar -o "$dest" "$url"
    else
        err "Neither wget nor curl found. Install one and retry."
        return 1
    fi

    log "Downloaded: ${filename} ($(du -h "$dest" | cut -f1))"
}

# ---------- Turbohaul Manifest Registration ----------

register_manifest() {
    local tag="$1"
    local gguf_path="$2"
    shift 2
    local flags=("$@")

    log "Registering manifest: ${tag}"

    # Build the manifest JSON
    local manifest
    manifest=$(cat <<EOF
{
    "model_path": "${gguf_path}",
    "flags": {
$(printf '        "%s": %s,\n' "${flags[@]}" | sed '$ s/,$//')
    }
}
EOF
)

    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "${TURBOHAUL_HOST}/api/manifests/${tag}" \
        -H "Content-Type: application/json" \
        -d "$manifest" 2>/dev/null || echo "000")

    if [[ "$response" == "200" || "$response" == "201" ]]; then
        log "Registered: ${tag}"
    else
        warn "Failed to register ${tag} (HTTP ${response}). Is turbohaul running?"
    fi
}

# ---------- Preset Commands ----------

list_presets() {
    echo -e "${CYAN}Available Hardware Presets:${NC}"
    echo "  single-8gb    Single GPU, 6-12GB VRAM (GTX 1070, RTX 3060 8GB)"
    echo "  single-16gb   Single GPU, 14-16GB VRAM (RTX 4060 Ti 16GB, RTX 4070 Ti)"
    echo "  single-24gb   Single GPU, 20-24GB VRAM (RTX 3090, RTX 4090) <- RECOMMENDED"
    echo "  dual-24gb     Dual GPU, 24GB each (2x RTX 3090, 2x RTX 4090)"
    echo "  single-48gb   Single GPU, 40-48GB VRAM (RTX 5090, A6000)"
    echo "  dual-48gb     Dual GPU, 48GB each (2x A6000 Ada)"
    echo "  api-only      No local models (API providers only)"
    echo ""
    echo -e "${CYAN}Available Model Presets:${NC}"
    echo "  darwin-28b-reason   Darwin-28B-REASON (STEM reasoning, GPQA 89.39%)"
    echo "  apex-mtp-35b-a3b   APEX-MTP 35B-A3B (MoE, MTP speculative, 1M ctx)"
    echo "  qwen36-27b          Qwen 3.6 27B (general purpose, tool calling)"
    echo "  qwen36-35b-a3b      Qwen 3.6 35B-A3B (lightweight MoE)"
}

show_status() {
    log "Hardware Detection:"
    echo "  GPUs: $(get_gpu_count)"
    echo "  Single GPU VRAM: $(get_single_gpu_vram) MB"
    echo "  Preset: $(detect_hardware_preset)"
    echo ""
    log "Model Directory: ${MODEL_DIR}"
    echo "  Darwin-28B: $(ls -la "${MODEL_DIR}"/Darwin-28B-REASON.*.gguf 2>/dev/null | awk '{print $NF, $5}' || echo 'not found')"
    echo "  APEX-MTP:   $(ls -la "${MODEL_DIR}"/Qwen3.6-35B-A3B-APEX-MTP-*.gguf 2>/dev/null | awk '{print $NF, $5}' || echo 'not found')"
}

# ---------- Main ----------

main() {
    local preset=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --preset)   preset="$2"; shift 2 ;;
            --list)     list_presets; return 0 ;;
            --dry-run)  dry_run=true; shift ;;
            --status)   show_status; return 0 ;;
            --help|-h)  echo "Usage: southpaw-setup [--preset NAME] [--list] [--dry-run] [--status]"; return 0 ;;
            *)          err "Unknown option: $1"; return 1 ;;
        esac
    done

    # Detect hardware if no preset specified
    if [[ -z "$preset" ]]; then
        preset=$(detect_hardware_preset)
        log "Auto-detected hardware preset: ${preset}"
    fi

    # Show what we'll do
    show_status
    echo ""

    if [[ "$preset" == "api-only" ]]; then
        log "No local models needed for API-only preset."
        return 0
    fi

    # For now, just show the recommended setup
    # Full implementation would parse YAML and auto-download/register
    log "Recommended setup for ${preset}:"
    echo "  Main model: Darwin-28B-REASON (GPU 0)"
    echo "  Aux model:  APEX-MTP 35B-A3B (GPU 1)" 
    echo ""
    log "Model directory: ${MODEL_DIR}"
    echo ""
    echo "To download missing models:"
    echo "  wget -O ${MODEL_DIR}/Darwin-28B-REASON.Q4_K_M.gguf \\"
    echo "    'https://huggingface.co/mradermacher/Darwin-28B-REASON-GGUF/resolve/main/Darwin-28B-REASON.Q4_K_M.gguf'"
    echo ""
    echo "  wget -O ${MODEL_DIR}/Qwen3.6-35B-A3B-APEX-MTP-I-Compact.gguf \\"
    echo "    'https://huggingface.co/mudler/Qwen3.6-35B-A3B-APEX-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-APEX-MTP-I-Compact.gguf'"
    echo ""
    log "Start turbohaul: turbohaul-manager --config /etc/turbohaul/turbohaul.yaml"
}

main "$@"
