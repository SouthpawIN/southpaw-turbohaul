#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
#  SOUTHPAW'S MODEL SERVER — One-Click Install
#  
#  Usage:
#    curl -sSL https://raw.githubusercontent.com/SouthpawIN/southpaw-turbohaul/main/install.sh | bash
#
#  Or clone and run:
#    git clone https://github.com/SouthpawIN/southpaw-turbohaul.git
#    cd southpaw-turbohaul && bash install.sh
# ═══════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
err()  { echo -e "${RED}[install]${NC} $*" >&2; }

INSTALL_DIR="${SOUTHPAW_INSTALL:-$HOME/.local/share/southpaw-models}"
BIN_DIR="${SOUTHPAW_BIN:-$HOME/.local/bin}"
MODEL_DIR="${SOUTHPAW_MODEL_DIR:-$HOME/Models/storage/gguf}"

# ─── Preflight ───

check_deps() {
    local missing=()
    command -v nvidia-smi &>/dev/null || missing+=("nvidia-smi (NVIDIA drivers)")
    command -v python3 &>/dev/null || missing+=("python3")
    command -v pip3 &>/dev/null || missing+=("pip3")
    command -v git &>/dev/null || missing+=("git")
    command -v cmake &>/dev/null || missing+=("cmake")
    command -v systemctl &>/dev/null || missing+=("systemd")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies:"
        for d in "${missing[@]}"; do echo "  - $d"; done
        exit 1
    fi

    # Check for NVIDIA GPU
    if ! nvidia-smi &>/dev/null; then
        err "No NVIDIA GPU detected. This setup requires an NVIDIA GPU with CUDA."
        exit 1
    fi

    log "Dependencies OK"
}

# ─── Hardware ───

detect_hardware() {
    echo -e "${CYAN}═══ Hardware Detection ═══${NC}"
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null
    echo ""
    local vram
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader -i 0 2>/dev/null | tr -d ' MiB')
    if [[ "$vram" -lt 6000 ]]; then echo "tier=8gb"
    elif [[ "$vram" -lt 14000 ]]; then echo "tier=16gb"
    elif [[ "$vram" -lt 28000 ]]; then echo "tier=24gb"
    elif [[ "$vram" -lt 40000 ]]; then echo "tier=32gb"
    else echo "tier=48gb"
    fi
}

# ─── Build llama.cpp (AtomicBot fork with TQ3/TQ4 + MTP) ───

build_llama() {
    local build_dir="$INSTALL_DIR/llama.cpp-atomic"

    if [[ -f "$build_dir/build/bin/llama-server" ]]; then
        log "llama.cpp already built"
        return 0
    fi

    log "Building AtomicBot's llama.cpp (TQ3/TQ4 + MTP + NextN)..."
    log "This takes 5-10 minutes on first install."

    mkdir -p "$INSTALL_DIR"
    git clone --depth 1 https://github.com/AtomicBot-ai/atomic-llama-cpp-turboquant.git "$build_dir" 2>&1 | tail -3

    cd "$build_dir"
    cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5
    cmake --build build -j$(nproc) 2>&1 | tail -5

    if [[ ! -f "build/bin/llama-server" ]]; then
        err "Build failed. Check build output above."
        exit 1
    fi

    log "Build complete!"
}

# ─── Install southpaw-models CLI ───

install_cli() {
    log "Installing southpaw-models CLI..."

    mkdir -p "$BIN_DIR" "$INSTALL_DIR"

    # Copy models config
    cp "$(dirname "$0")/models.yaml" "$INSTALL_DIR/models.yaml" 2>/dev/null || \
        cp models.yaml "$INSTALL_DIR/models.yaml" 2>/dev/null || true

    # Copy the CLI script
    cp "$(dirname "$0")/bin/southpaw-models" "$BIN_DIR/southpaw-models" 2>/dev/null || \
        cp bin/southpaw-models "$BIN_DIR/southpaw-models" 2>/dev/null || true

    chmod +x "$BIN_DIR/southpaw-models"

    # Update paths in the script
    sed -i "s|SOUTHPAW_MODELS_CONFIG:-.*|SOUTHPAW_MODELS_CONFIG:-$INSTALL_DIR/models.yaml\"|" "$BIN_DIR/southpaw-models" 2>/dev/null || true
    sed -i "s|SOUTHPAW_LLAMA_BIN:-.*|SOUTHPAW_LLAMA_BIN:-$INSTALL_DIR/llama.cpp-atomic/build/bin/llama-server\"|" "$BIN_DIR/southpaw-models" 2>/dev/null || true
    sed -i "s|SOUTHPAW_LLAMA_LIB:-.*|SOUTHPAW_LLAMA_LIB:-$INSTALL_DIR/llama.cpp-atomic/build/bin\"|" "$BIN_DIR/southpaw-models" 2>/dev/null || true

    # Add to PATH if needed
    if ! echo "$PATH" | grep -q "$BIN_DIR"; then
        echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$HOME/.bashrc"
        warn "Added $BIN_DIR to PATH. Run: source ~/.bashrc"
    fi

    log "CLI installed to $BIN_DIR/southpaw-models"
}

# ─── Install Hermes skill ───

install_skill() {
    local skill_dir="$HOME/.hermes/skills/southpaw-models"
    mkdir -p "$skill_dir"

    cp "$(dirname "$0")/models.yaml" "$skill_dir/models.yaml" 2>/dev/null || true
    cp "$(dirname "$0")/SKILL.md" "$skill_dir/SKILL.md" 2>/dev/null || true

    log "Hermes skill installed to $skill_dir"
}

# ─── Main ───

main() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║    Southpaw's Model Server — Installer                ║"
    echo "║    Curated local inference for Hermes Agent           ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_deps
    detect_hardware
    echo ""

    build_llama
    install_cli
    install_skill

    echo ""
    log "═══ Installation Complete! ═══"
    echo ""
    echo "  Next steps:"
    echo "    southpaw-models list          # See available models"
    echo "    southpaw-models darwin+apex   # Start full local setup"
    echo "    southpaw-models status        # Check what's running"
    echo ""
    echo "  Models auto-download on first use."
    echo "  Services auto-start and auto-restart on crash."
    echo ""
}

main "$@"
