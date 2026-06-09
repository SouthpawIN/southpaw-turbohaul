#!/bin/bash
# Intel GPU Health Check — quick diagnostic for turbohaul
# Usage: bash intel_gpu_health.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$*"; }
section() { printf "\n${CYAN}── %s ──${NC}\n" "$*"; }

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       Intel GPU Health Check — Turbohaul              ║"
echo "╚═══════════════════════════════════════════════════════╝"

# ─── Hardware ───
section "Hardware"
GPU_LINE=$(lspci 2>/dev/null | grep -iE "VGA|3D" | grep -i intel | head -1)
if [ -n "$GPU_LINE" ]; then
    pass "$GPU_LINE"
else
    fail "No Intel GPU detected"
fi

DRIVER=$(lspci -k 2>/dev/null | grep -A3 "VGA" | grep "driver in use" | awk -F': ' '{print $2}' | head -1)
if [ "$DRIVER" = "xe" ]; then
    pass "Kernel driver: xe (Battlemage)"
elif [ "$DRIVER" = "i915" ]; then
    pass "Kernel driver: i915 (Alchemist)"
elif [ -n "$DRIVER" ]; then
    warn "Kernel driver: $DRIVER"
else
    fail "No kernel driver detected"
fi

# ─── VRAM ───
section "VRAM Detection"
if [ -f /opt/data/southpaw-turbohaul/src/turbohaul/gpu_backend.py ]; then
    python3 -c "
import sys; sys.path.insert(0, '/opt/data/southpaw-turbohaul/src')
from turbohaul.gpu_backend import get_gpu_memory_total_mib, detect_gpu_vendor, get_gpu_memory_free_mib
vendor = detect_gpu_vendor()
total = get_gpu_memory_total_mib()
free = get_gpu_memory_free_mib()
if total > 0:
    print(f'  ✓ GPU vendor: {vendor}, Total: {total} MiB ({total//1024} GB), Free: {free} MiB')
else:
    print(f'  ! GPU vendor: {vendor}, VRAM detection failed')
" 2>/dev/null || warn "gpu_backend.py error"
fi

# ─── Vulkan ───
section "Vulkan Backend"
if command -v vulkaninfo >/dev/null 2>&1; then
    VK_DEVICE=$(vulkaninfo 2>/dev/null | grep "deviceName" | head -1 | sed 's/.*= *//')
    if echo "$VK_DEVICE" | grep -qi "intel"; then
        pass "Vulkan device: $VK_DEVICE"
    else
        fail "Vulkan: no Intel device (got: ${VK_DEVICE:-none})"
    fi
else
    warn "vulkaninfo not found (install: sudo apt install vulkan-tools)"
fi

# ─── SYCL / Level Zero ───
section "SYCL / Level Zero"
if [ -f /opt/intel/oneapi/setvars.sh ]; then
    pass "oneAPI installed"
    SYCL_OUT=$(bash -c "source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 && sycl-ls 2>&1" || true)
    if echo "$SYCL_OUT" | grep -qi "level.*zero"; then
        pass "SYCL Level Zero devices:"
        echo "$SYCL_OUT" | grep -i "level\|intel" | head -3 | while IFS= read -r l; do
            printf "       %s\n" "$l"
        done
    else
        warn "No SYCL Level Zero devices"
    fi
    ICPX=$(bash -c "source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 && which icpx 2>/dev/null" || true)
    [ -n "$ICPX" ] && pass "DPC++ compiler: $ICPX"
else
    warn "oneAPI not installed"
fi

# ─── llama.cpp Binaries ───
section "llama.cpp Binaries"
FOUND=0
for BIN_DIR in "$HOME/llama-cpp/build-vulkan" "$HOME/llama-cpp/build"; do
    BIN="$BIN_DIR/bin/llama-server"
    if [ -f "$BIN" ]; then
        BACKEND="unknown"
        if ldd "$BIN" 2>/dev/null | grep -q "libvulkan"; then
            BACKEND="Vulkan"
        elif ldd "$BIN" 2>/dev/null | grep -q "sycl"; then
            BACKEND="SYCL"
        fi
        SIZE=$(du -h "$BIN" 2>/dev/null | cut -f1)
        pass "$BACKEND backend: $BIN ($SIZE)"
        FOUND=$((FOUND + 1))
    fi
done
[ "$FOUND" -eq 0 ] && warn "No llama.cpp binaries found"

# ─── User Permissions ───
section "User Permissions"
USER="${SUDO_USER:-$(whoami)}"
id -nG "$USER" 2>/dev/null | grep -qw video && pass "video group" || fail "$USER not in video group"
id -nG "$USER" 2>/dev/null | grep -qw render && pass "render group" || fail "$USER not in render group"
for dev in /dev/dri/renderD128 /dev/dri/card0; do
    [ -e "$dev" ] && pass "$dev" || warn "$dev missing"
done

# ─── Quick Benchmark ───
section "Quick Benchmark (TinyLlama)"
TINY="$HOME/turbohaul-models/tinyllama-1.1b-q2_k.gguf"
if [ -f "$TINY" ]; then
    VKBIN="$HOME/llama-cpp/build-vulkan/bin/llama-bench"
    if [ -f "$VKBIN" ]; then
        TG=$($VKBIN -m "$TINY" -n 32 -p 64 -r 1 -ngl 999 -fa auto -o csv --no-warmup 2>/dev/null | \
            awk -F',' 'NR>1 && $35+0>0 {print $40}')
        if [ -n "$TG" ] && [ "$(python3 -c "print(1 if $TG > 1 else 0)" 2>/dev/null)" = "1" ]; then
            pass "Vulkan TG: ${TG} tok/s"
        else
            warn "Vulkan benchmark failed"
        fi
    fi

    SYCLBIN="$HOME/llama-cpp/build/bin/llama-bench"
    if [ -f "$SYCLBIN" ] && [ -f /opt/intel/oneapi/setvars.sh ]; then
        TG=$(bash -c "source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 && $SYCLBIN -m $TINY -n 32 -p 64 -r 1 -ngl 999 -fa auto -o csv --no-warmup 2>/dev/null" | \
            awk -F',' 'NR>1 && $35+0>0 {print $40}')
        if [ -n "$TG" ] && [ "$(python3 -c "print(1 if $TG > 1 else 0)" 2>/dev/null)" = "1" ]; then
            pass "SYCL TG: ${TG} tok/s"
        else
            warn "SYCL benchmark failed"
        fi
    fi
else
    warn "TinyLlama not found at $TINY"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo ""
