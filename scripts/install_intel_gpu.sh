#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  Intel GPU Driver & Runtime Installer for Southpaw Turbohaul
#  
#  Installs everything needed for llama.cpp SYCL + Vulkan backends
#  on Intel Arc / Data Center GPUs (Battlemage, Alchemist, etc.)
#
#  Tested on: Ubuntu 24.04 LTS, Intel Arc Pro B60 (BMG G21)
#
#  Components installed:
#    1. Intel GPU PPA + kernel drivers (xe/i915)
#    2. Level Zero runtime + loader (for SYCL backend)
#    3. OpenCL runtime (for GPU detection fallback)
#    4. Vulkan drivers + validation layers
#    5. Mesa GPU libraries (EGL, GL, GBM)
#    6. Intel media driver (VA-API video decode)
#    7. Intel oneAPI DPC++/C++ compiler (optional, for SYCL builds)
#    8. GPU tools (vulkaninfo, clinfo, intel_gpu_top)
#
#  Usage:
#    sudo bash install_intel_gpu.sh [--oneapi] [--vulkan-only|--sycl-only|--all]
#
#  Flags:
#    --oneapi        Also install Intel oneAPI basekit (~2.5GB)
#    --vulkan-only   Install Vulkan drivers only (no SYCL/Level Zero)
#    --sycl-only     Install SYCL/Level Zero only (no Vulkan)
#    --all           Install everything (default)
#    --check         Check current installation status only
#    --no-reboot     Skip reboot reminder
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_ONEAPI=0
INSTALL_VULKAN=1
INSTALL_SYCL=1
CHECK_ONLY=0
NO_REBOOT=0

for arg in "$@"; do
    case $arg in
        --oneapi)    INSTALL_ONEAPI=1 ;;
        --vulkan-only) INSTALL_SYCL=0 ;;
        --sycl-only) INSTALL_VULKAN=0 ;;
        --all)       INSTALL_VULKAN=1; INSTALL_SYCL=1; INSTALL_ONEAPI=1 ;;
        --check)     CHECK_ONLY=1 ;;
        --no-reboot) NO_REBOOT=1 ;;
        --help|-h)
            echo "Usage: sudo bash $0 [--oneapi] [--vulkan-only|--sycl-only|--all] [--check]"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
info() { echo -e "${BLUE}[·]${NC} $*"; }

# ─── Detect OS ───
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
    else
        err "Cannot detect OS. Only Ubuntu 24.04 is supported."
        exit 1
    fi
    
    if [ "$OS_ID" != "ubuntu" ] && [ "$OS_ID" != "debian" ]; then
        warn "This script is designed for Ubuntu/Debian. Detected: $OS_ID $OS_VERSION"
        warn "Proceed at your own risk."
    fi
    
    # Map codename for Intel GPU PPA
    case "$OS_VERSION" in
        24.04*) PPACODENAME="noble" ;;
        22.04*) PPACODENAME="jammy" ;;
        23.10*) PPACODENAME="mantic" ;;
        *)      PPACODENAME="noble" ;;
    esac
    
    info "OS: $OS_ID $OS_VERSION (PPA codename: $PPACODENAME)"
}

# ─── Detect GPU ───
detect_gpu() {
    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -iE "VGA|DISPLAY|3D" | grep -i intel || true)
    
    if [ -z "$gpu_info" ]; then
        err "No Intel GPU detected via lspci"
        echo "  Install pciutils: sudo apt install pciutils"
        exit 1
    fi
    
    echo "$gpu_info" | while IFS= read -r line; do
        local device_id
        device_id=$(echo "$line" | grep -oP '\[([0-9a-f]{4}):([0-9a-f]{4})\]' 2>/dev/null | head -1 || true)
        [ -z "$device_id" ] && device_id=$(echo "$line" | grep -oP '[0-9a-f]{4}' 2>/dev/null | tail -1 || true)
        info "GPU: $line"
        
        # Identify GPU generation by name or device ID
        local lower_line
        lower_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')
        case "$lower_line" in
            *e211*|*e212*)  info "  → Intel Arc Pro B60/B50 (Battlemage BMG)" ;;
            *e20b*)         info "  → Intel Arc B580 (Battlemage BMG)" ;;
            *e209*)         info "  → Intel Arc A770/A750 (Alchemist ACM)" ;;
            *569*|*56b*)    info "  → Intel Arc (Alchemist ACM)" ;;
            *9a49*|*9a40*)  info "  → Intel UHD/Arc integrated" ;;
            *)              info "  → Intel GPU detected" ;;
        esac
    done
    
    # Check kernel driver
    local driver
    driver=$(lspci -k 2>/dev/null | grep -A3 -i "VGA\|3D" | grep "Kernel driver" | awk '{print $NF}' | head -1)
    if [ -n "$driver" ]; then
        info "Kernel driver: $driver"
        if [ "$driver" = "xe" ]; then
            log "Using xe driver (correct for Battlemage)"
        elif [ "$driver" = "i915" ]; then
            info "Using i915 driver (correct for Alchemist, may work for Battlemage)"
        fi
    fi
}

# ─── Status check ───
check_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Intel GPU Installation Status"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # Kernel driver
    if lsmod 2>/dev/null | grep -q "xe\|i915"; then
        log "Kernel driver loaded: $(lsmod | grep -oE 'xe|i915' | head -1)"
    else
        err "No Intel GPU kernel driver loaded"
    fi
    
    # Vulkan
    if command -v vulkaninfo >/dev/null 2>&1; then
        local vk_name
        vk_name=$(vulkaninfo 2>/dev/null | grep "deviceName" | head -1 | awk -F= '{print $2}' | xargs)
        if [ -n "$vk_name" ] && echo "$vk_name" | grep -qi "intel"; then
            log "Vulkan: $vk_name"
        else
            err "Vulkan: no Intel device found (got: $vk_name)"
        fi
    else
        warn "Vulkan: vulkaninfo not installed"
    fi
    
    # Level Zero
    if dpkg -s intel-level-zero-gpu 2>/dev/null | grep -q "Status: install ok installed"; then
        log "Level Zero GPU runtime installed"
    else
        warn "Level Zero GPU runtime NOT installed (needed for SYCL)"
    fi
    
    if dpkg -s level-zero 2>/dev/null | grep -q "Status: install ok installed"; then
        log "Level Zero loader installed"
    else
        warn "Level Zero loader NOT installed"
    fi
    
    # OpenCL
    if command -v clinfo >/dev/null 2>&1; then
        local cl_platforms
        cl_platforms=$(clinfo 2>/dev/null | head -1)
        if echo "$cl_platforms" | grep -q "Intel"; then
            log "OpenCL: Intel GPU detected"
        else
            warn "OpenCL: no Intel platform found"
        fi
    else
        warn "clinfo not installed"
    fi
    
    # Mesa / EGL
    if dpkg -s mesa-vulkan-drivers 2>/dev/null | grep -q "Status: install ok installed"; then
        log "Mesa Vulkan drivers installed"
    else
        warn "Mesa Vulkan drivers NOT installed"
    fi
    
    # User groups
    local user_groups
    user_groups=$(groups "$SUDO_USER" 2>/dev/null || groups $(whoami) 2>/dev/null || echo "")
    local has_video has_render
    has_video=$(echo "$user_groups" | grep -cw "video" || echo 0)
    has_render=$(echo "$user_groups" | grep -cw "render" || echo 0)
    
    if [ "$has_video" -gt 0 ] && [ "$has_render" -gt 0 ]; then
        log "User groups: video ✓, render ✓"
    else
        warn "User groups: video=$has_video, render=$has_render"
        info "  Add user: sudo usermod -aG video,render $USER"
    fi
    
    # oneAPI
    if [ -f /opt/intel/oneapi/setvars.sh ]; then
        log "Intel oneAPI installed at /opt/intel/oneapi/"
        if command -v icpx >/dev/null 2>&1 || [ -f /opt/intel/oneapi/compiler/latest/bin/icpx ]; then
            log "  DPC++/C++ compiler (icpx) available"
        fi
    else
        warn "Intel oneAPI NOT installed (pass --oneapi to install)"
    fi
    
    # sycl-ls
    if [ -f /opt/intel/oneapi/setvars.sh ]; then
        local sycl_count
        sycl_count=$(bash -c "source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 && sycl-ls 2>/dev/null | grep -c Level" || echo 0)
        if [ "$sycl_count" -gt 0 ]; then
            log "SYCL Level Zero devices found: $sycl_count"
        else
            warn "No SYCL Level Zero devices found"
        fi
    fi
    
    # PPA
    if [ -f /etc/apt/sources.list.d/intel-gpu.list ] || ls /etc/apt/sources.list.d/intel-gpu-* >/dev/null 2>&1; then
        log "Intel GPU PPA configured"
    else
        warn "Intel GPU PPA NOT configured"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
}

# ─── Check root ───
check_root() {
    if [ "$EUID" -ne 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
        err "Run with sudo: sudo bash $0"
        exit 1
    fi
}

# ─── Install Intel GPU PPA ───
install_ppa() {
    info "Setting up Intel GPU PPA..."
    
    if [ -f /etc/apt/sources.list.d/intel-gpu.list ] || ls /etc/apt/sources.list.d/intel-gpu-* >/dev/null 2>&1; then
        log "Intel GPU PPA already configured"
        return
    fi
    
    # Add signing key
    wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
        gpg --dearmor --yes --output /usr/share/keyrings/intel-graphics.gpg
    
    # Add repository
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] \
https://repositories.intel.com/gpu/ubuntu $PPACODENAME client" | \
        tee /etc/apt/sources.list.d/intel-gpu.list > /dev/null
    
    apt-get update -qq
    log "Intel GPU PPA added"
}

# ─── Install Vulkan stack ───
install_vulkan() {
    info "Installing Vulkan drivers and runtime..."
    
    apt-get install -y -qq \
        intel-opencl-icd \
        mesa-vulkan-drivers \
        libvulkan1 \
        vulkan-tools \
        libegl-mesa0 \
        libegl1-mesa \
        libegl1-mesa-dev \
        libgbm1 \
        libgl1-mesa-dev \
        libgl1-mesa-dri \
        libglapi-mesa \
        libgles2-mesa-dev \
        libglx-mesa0 \
        libxatracker2 \
        2>/dev/null
    
    log "Vulkan + Mesa drivers installed"
}

# ─── Install Level Zero + SYCL runtime ───
install_sycl() {
    info "Installing Level Zero runtime + SYCL dependencies..."
    
    apt-get install -y -qq \
        intel-level-zero-gpu \
        level-zero \
        level-zero-dev \
        intel-igc-cm \
        intel-igc-opencl-2 \
        intel-ocloc \
        libigdgmm12 \
        libigc-dev \
        libigdfcl-dev \
        libigfxcmrt-dev \
        2>/dev/null
    
    log "Level Zero + SYCL runtime installed"
}

# ─── Install Intel media driver (VA-API) ───
install_media() {
    info "Installing Intel media driver (VA-API)..."
    
    apt-get install -y -qq \
        intel-media-va-driver-non-free \
        vainfo \
        2>/dev/null || \
    apt-get install -y -qq \
        intel-media-va-driver \
        vainfo \
        2>/dev/null
    
    log "Intel media driver installed"
}

# ─── Install oneAPI basekit ───
install_oneapi() {
    info "Installing Intel oneAPI basekit (~2.5GB, may take a while)..."
    
    if [ -f /opt/intel/oneapi/setvars.sh ]; then
        log "Intel oneAPI already installed at /opt/intel/oneapi/"
        return
    fi
    
    # Add oneAPI repo
    wget -qO- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
        gpg --dearmor --yes --output /usr/share/keyrings/oneapi-archive-keyring.gpg
    
    echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
https://apt.repos.intel.com/oneapi all main" | \
        tee /etc/apt/sources.list.d/oneAPI.list > /dev/null
    
    apt-get update -qq
    
    # Install just the DPC++ compiler (smaller than full basekit)
    if apt-cache show intel-oneapi-compiler-dpcpp-cpp >/dev/null 2>&1; then
        info "Installing Intel oneAPI DPC++/C++ compiler..."
        apt-get install -y -qq intel-oneapi-compiler-dpcpp-cpp 2>/dev/null
        log "Intel oneAPI DPC++ compiler installed"
    else
        warn "DPC++ compiler package not found, trying full basekit..."
        apt-get install -y -qq intel-basekit 2>/dev/null
        log "Intel oneAPI basekit installed"
    fi
    
    # Install MKL for potential matrix acceleration
    if apt-cache show intel-oneapi-mkl >/dev/null 2>&1; then
        apt-get install -y -qq intel-oneapi-mkl 2>/dev/null
        log "Intel MKL installed"
    fi
}

# ─── Fix user groups ───
fix_groups() {
    local target_user="${SUDO_USER:-$(whoami)}"
    
    if [ "$target_user" = "root" ]; then
        warn "Running as root, skipping group setup"
        return
    fi
    
    local needs_groups=""
    id -nG "$target_user" 2>/dev/null | grep -qw "video"  || needs_groups="$needs_groups video"
    id -nG "$target_user" 2>/dev/null | grep -qw "render" || needs_groups="$needs_groups render"
    
    if [ -n "$needs_groups" ]; then
        info "Adding $target_user to groups:$needs_groups"
        usermod -aG "${needs_groups# }" "$target_user"
        log "Groups updated. Run 'newgrp video render' or re-login."
    else
        log "User $target_user already in video + render groups"
    fi
}

# ─── Verify installation ───
verify() {
    info "Verifying installation..."
    echo ""
    
    local ok=0
    local total=0
    
    # Vulkan test
    if command -v vulkaninfo >/dev/null 2>&1; then
        total=$((total + 1))
        if vulkaninfo 2>/dev/null | grep -qi "intel.*arc\|intel.*B60\|BMG\|ACM"; then
            log "Vulkan: Intel GPU detected"
            ok=$((ok + 1))
        else
            warn "Vulkan: no Intel GPU found in vulkaninfo"
        fi
    fi
    
    # OpenCL test
    if command -v clinfo >/dev/null 2>&1; then
        total=$((total + 1))
        if clinfo 2>/dev/null | grep -qi "Intel.*OpenCL Graphics"; then
            log "OpenCL: Intel GPU detected"
            ok=$((ok + 1))
        else
            warn "OpenCL: no Intel GPU"
        fi
    fi
    
    # Level Zero test
    if dpkg -s intel-level-zero-gpu 2>/dev/null | grep -q "Status: install ok installed"; then
        total=$((total + 1))
        log "Level Zero: installed"
        ok=$((ok + 1))
    fi
    
    # SYCL test (needs oneAPI)
    if [ -f /opt/intel/oneapi/setvars.sh ]; then
        total=$((total + 1))
        local sycl_devices
        sycl_devices=$(bash -c "source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 && sycl-ls 2>/dev/null" || true)
        if echo "$sycl_devices" | grep -qi "intel\|Level"; then
            log "SYCL: Intel GPU found"
            echo "$sycl_devices" | head -5
            ok=$((ok + 1))
        else
            warn "SYCL: no Intel device found"
            echo "$sycl_devices"
        fi
    fi
    
    echo ""
    if [ "$ok" -eq "$total" ] && [ "$total" -gt 0 ]; then
        log "All $total checks passed!"
    elif [ "$total" -gt 0 ]; then
        warn "$ok/$total checks passed"
    else
        warn "No verifiable checks (install vulkan-tools and clinfo)"
    fi
}

# ─── Main ───
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  Intel GPU Driver & Runtime Installer                ║"
    echo "║  For Southpaw Turbohaul + llama.cpp SYCL/Vulkan      ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    
    detect_os
    detect_gpu
    
    if [ "$CHECK_ONLY" -eq 1 ]; then
        check_status
        exit 0
    fi
    
    check_root
    
    echo ""
    info "Installation plan:"
    [ "$INSTALL_VULKAN" -eq 1 ] && info "  ✓ Vulkan + Mesa drivers"
    [ "$INSTALL_SYCL" -eq 1 ] && info "  ✓ Level Zero + SYCL runtime"
    [ "$INSTALL_ONEAPI" -eq 1 ] && info "  ✓ Intel oneAPI DPC++ compiler"
    info "  ✓ Intel GPU PPA"
    info "  ✓ Media driver (VA-API)"
    info "  ✓ User group setup"
    echo ""
    
    # Install components
    install_ppa
    [ "$INSTALL_VULKAN" -eq 1 ] && install_vulkan
    [ "$INSTALL_SYCL" -eq 1 ] && install_sycl
    install_media
    [ "$INSTALL_ONEAPI" -eq 1 ] && install_oneapi
    fix_groups
    
    # Install GPU tools
    info "Installing GPU diagnostic tools..."
    apt-get install -y -qq pciutils vulkan-tools clinfo hwinfo 2>/dev/null || true
    
    echo ""
    verify
    
    if [ "$NO_REBOOT" -eq 0 ]; then
        echo ""
        warn "A reboot may be needed for driver changes to take effect."
        warn "Run '$0 --check' after reboot to verify."
    fi
}

main "$@"
