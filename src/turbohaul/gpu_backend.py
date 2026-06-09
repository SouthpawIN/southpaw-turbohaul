"""GPU backend abstraction: NVIDIA (CUDA/nvidia-smi) + Intel (SYCL/sycl-smi).

The original turbohaul code hardcoded nvidia-smi for all GPU queries. This
module provides a backend-agnostic interface so the manager, safety gates,
and orphan reaper work transparently on Intel Arc / Data Center GPUs via
SYCL, as well as NVIDIA CUDA GPUs.

Auto-detection: gpu_backend() returns the right provider based on which
CLI tools are available on the host. The operator can override via
the TURBOHAUL_GPU_BACKEND env var or runtime.gpu_backend config key.

Provider contract:
  - get_used_vram_mib()      → int | None
  - get_free_vram_mib()      → int | None
  - get_total_vram_mib()     → int | None
  - scan_compute_apps()      → list[dict]  (pid, used_memory_mib)
  - gpu_backend_name()       → str ("cuda" | "sycl" | "none")
"""
from __future__ import annotations

from pathlib import Path

import logging
import os
import shutil
import subprocess
from enum import Enum
from typing import Any, Callable

log = logging.getLogger(__name__)


class GpuVendor(Enum):
    NVIDIA = "cuda"
    INTEL = "sycl"
    NONE = "none"


# ---------------------------------------------------------------------------
# Tool resolution (cached at module load, PATH-injection resistant)
# ---------------------------------------------------------------------------

_NVIDIA_SMI = shutil.which("nvidia-smi") or "/usr/bin/nvidia-smi"
_SYCL_SMI = shutil.which("sycl-smi") or "/usr/bin/sycl-smi"
_INTEL_GPU_TOP = shutil.which("intel_gpu_top") or "/usr/local/bin/intel_gpu_top"


def _has_nvidia_smi() -> bool:
    try:
        subprocess.check_output(
            [_NVIDIA_SMI, "--version"], stderr=subprocess.DEVNULL, timeout=5,
        )
        return True
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        return False


def _has_sycl_smi() -> bool:
    try:
        subprocess.check_output(
            [_SYCL_SMI, "--version"], stderr=subprocess.DEVNULL, timeout=5,
        )
        return True
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        return False


def _has_intel_gpu_top() -> bool:
    """Fallback detector: intel_gpu_top lists Intel GPU devices."""
    try:
        out = subprocess.check_output(
            [_INTEL_GPU_TOP, "--json", "-d", "0.1"],
            stderr=subprocess.DEVNULL, timeout=3,
        )
        return bool(out)
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        return False


def _has_dev_dri() -> bool:
    """Heuristic: /dev/dri/renderD128 exists → Intel (or other iGPU)."""
    return os.path.exists("/dev/dri/renderD128")


# ---------------------------------------------------------------------------
# Provider: NVIDIA
# ---------------------------------------------------------------------------

class NvidiaProvider:
    """GPU queries via nvidia-smi."""

    @staticmethod
    def get_used_vram_mib(gpu_index: int = 0) -> int | None:
        try:
            out = subprocess.check_output(
                [
                    _NVIDIA_SMI,
                    "--query-gpu=memory.used",
                    "--format=csv,noheader,nounits",
                    "-i", str(gpu_index),
                ],
                text=True, timeout=5,
            )
            return _parse_csv_int(out)
        except (FileNotFoundError, subprocess.SubprocessError, OSError):
            return None

    @staticmethod
    def get_free_vram_mib(gpu_index: int = 0) -> int | None:
        try:
            out = subprocess.check_output(
                [
                    _NVIDIA_SMI,
                    "--query-gpu=memory.free",
                    "--format=csv,noheader,nounits",
                    "-i", str(gpu_index),
                ],
                text=True, timeout=5,
            )
            return _parse_csv_int(out)
        except (FileNotFoundError, subprocess.SubprocessError, OSError):
            return None

    @staticmethod
    def get_total_vram_mib(gpu_index: int = 0) -> int | None:
        try:
            out = subprocess.check_output(
                [
                    _NVIDIA_SMI,
                    "--query-gpu=memory.total",
                    "--format=csv,noheader,nounits",
                    "-i", str(gpu_index),
                ],
                text=True, timeout=5,
            )
            return _parse_csv_int(out)
        except (FileNotFoundError, subprocess.SubprocessError, OSError):
            return None

    @staticmethod
    def scan_compute_apps() -> list[dict[str, Any]]:
        """Return [{pid, used_memory_mib}, ...] from nvidia-smi."""
        try:
            out = subprocess.check_output(
                [
                    _NVIDIA_SMI,
                    "--query-compute-apps=pid,used_memory",
                    "--format=csv,noheader,nounits",
                ],
                text=True, timeout=10,
            )
        except (FileNotFoundError, subprocess.SubprocessError):
            return []
        apps: list[dict[str, Any]] = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 2:
                try:
                    apps.append({"pid": int(parts[0]), "used_memory_mib": int(parts[1])})
                except ValueError:
                    continue
        return apps

    @staticmethod
    def gpu_backend_name() -> str:
        return "cuda"


# ---------------------------------------------------------------------------
# Provider: Intel (SYCL / sycl-smi)
# ---------------------------------------------------------------------------

class IntelProvider:
    """GPU queries via sycl-smi (Intel oneAPI Level Zero / SYCL runtime).

    sycl-smi is the Intel equivalent of nvidia-smi.  It ships with the
    oneAPI base toolkit and the intel-gpu-optimized container images.

    sycl-smi output format (CSV-like):
      Device  Name          EU EU/EUs  Cores  Memory     Temp
      0       Intel(R) Arc  128 128     8192   16384 MiB  42 C

    We parse memory fields via --showmem for used/free/total.

    On systems using the xe kernel driver (Linux 6.8+), sycl-smi may
    not be available.  We fall back to:
      1. intel_gpu_top (if available, supports i915)
      2. /sys/class/drm/card0/device/device (PCI device ID → known VRAM)
      3. lspci BAR size heuristic
    """

    # Known Intel GPU device IDs → VRAM in MiB.
    # xe driver systems expose the PCI device ID at
    # /sys/class/drm/card0/device/device
    _DEVICE_VRAM_MAP: dict[int, int] = {
        # DG2 / Arc A-series (discrete)
        0xe211: 16384,   # Arc A770
        0xe212: 16384,   # Arc A770M
        0xe213: 8192,    # Arc A750
        0xe215: 16384,   # Arc A770M (variant)
        0xe217: 16384,   # Arc A770 (variant)
        0xe218: 8192,    # Arc A750 (variant)
        0xe214: 10240,   # Arc A580
        0xe216: 10240,   # Arc A580 (variant)
        0xe219: 10240,   # Arc A580 (variant)
        0xe21b: 6144,    # Arc A380
        0xe21c: 4096,    # Arc A310
        0xe20b: 4096,    # Arc A350M
        0xe20a: 4096,    # Arc A370M
        0xe20c: 4096,    # Arc A370M (variant)
        0xe207: 12288,   # Arc A730M
        0xe208: 8192,    # Arc A570M
        0xe209: 8192,    # Arc A550M
        0xe205: 16384,   # Arc A770M (DG2)
        0xe206: 16384,   # Arc A770M (DG2)
        # Battlemage / Arc B-series (discrete)
        0xe220: 12288,   # Arc B580
        0xe221: 10240,   # Arc B570
        0xe222: 8192,    # Battlemage (Lunar Lake)
        0xe223: 8192,    # Battlemage (Arrow Lake)
        0xe224: 8192,    # Battlemage (Arrow Lake)
        0xe225: 8192,    # Arrow Lake-S
        0xe226: 8192,    # Arrow Lake-S (variant)
        0xe228: 12288,   # Battlemage G21
        0xe229: 10240,   # Battlemage G21 (variant)
        0xe22a: 6144,    # Battlemage G21 (variant)
        # Data Center GPU Max (Ponte Vecchio)
        0xbd4:  16384,   # Max 1100 (HBM2e)
        0xbd6:  49152,   # Max 1500 (HBM2e)
    }

    # Subsystem-based VRAM overrides for device IDs shared between
    # consumer and pro/workstation variants with different VRAM.
    # Key: (device_id, subsystem_vendor, subsystem_device) -> VRAM in MiB
    _SUBSYSTEM_VRAM_OVERRIDES: dict[tuple[int, int, int], int] = {
        # Arc Pro B60 (24GB) shares device ID 0xe211 with Arc A770 (16GB)
        (0xe211, 0x1849, 0x6023): 24576,   # ASRock Arc Pro B60 24GB
        (0xe211, 0x15B8, 0x6023): 24576,   # Sparkle Arc Pro B60 24GB
    }

    @staticmethod
    def _query_memory(gpu_index: int = 0) -> dict[str, int] | None:
        """Query memory via sycl-smi. Returns {total, used, free} in MiB or None."""
        try:
            out = subprocess.check_output(
                [_SYCL_SMI, "--showmem", "-d", str(gpu_index)],
                text=True, timeout=5,
            )
        except (FileNotFoundError, subprocess.SubprocessError, OSError):
            return None
        total = used = free = 0
        for line in out.splitlines():
            low = line.lower().strip()
            if "total" in low and "mi" in low:
                total = _parse_mem_line(line)
            elif "used" in low and "mi" in low:
                used = _parse_mem_line(line)
            elif "free" in low and "mi" in low:
                free = _parse_mem_line(line)
        if total > 0:
            return {"total": total, "used": used, "free": free if free > 0 else total - used}
        return None

    @staticmethod
    def _read_device_vram_mib() -> int | None:
        """Read total VRAM from PCI device ID (xe driver fallback)."""
        try:
            dev_path = Path("/sys/class/drm/card0/device/device")
            hex_id = dev_path.read_text().strip()
            device_id = int(hex_id, 16)
            # Try subsystem-based override first (handles Pro B60 vs A770)
            try:
                sub_vendor_path = Path("/sys/class/drm/card0/device/subsystem_vendor")
                sub_device_path = Path("/sys/class/drm/card0/device/subsystem_device")
                sub_vendor = int(sub_vendor_path.read_text().strip(), 16)
                sub_device = int(sub_device_path.read_text().strip(), 16)
                key = (device_id, sub_vendor, sub_device)
                override = IntelProvider._SUBSYSTEM_VRAM_OVERRIDES.get(key)
                if override is not None:
                    return override
            except (FileNotFoundError, ValueError, PermissionError):
                pass
            return IntelProvider._DEVICE_VRAM_MAP.get(device_id)
        except (FileNotFoundError, ValueError, PermissionError):
            return None

    @staticmethod
    def _estimate_vram_from_lspci() -> int | None:
        """Fallback: parse lspci BAR2 size as VRAM estimate.

        With resizable BAR enabled, BAR2 may be larger than actual VRAM,
        so this returns the PCI BAR size as an upper bound.  The caller
        should use min(bar2, device_known_vram) when available.
        """
        try:
            out = subprocess.check_output(
                ["lspci", "-s", "03:00.0", "-vv"],
                text=True, timeout=5,
            )
            for line in out.splitlines():
                if "Region 2" in line and "size" in line:
                    import re
                    m = re.search(r"size=(\d+)([GMTK])", line)
                    if m:
                        val = int(m.group(1))
                        unit = m.group(2)
                        if unit == "G":
                            val *= 1024
                        elif unit == "K":
                            val = val // 1024
                        return val
        except (FileNotFoundError, subprocess.SubprocessError):
            pass
        return None

    @staticmethod
    def get_used_vram_mib(gpu_index: int = 0) -> int | None:
        mem = IntelProvider._query_memory(gpu_index)
        if mem:
            return mem["used"]
        # xe driver: total is known from device ID, used = 0 (no probe)
        return None

    @staticmethod
    def get_free_vram_mib(gpu_index: int = 0) -> int | None:
        mem = IntelProvider._query_memory(gpu_index)
        if mem:
            return mem["free"]
        # xe driver: no free-memory probe available; try device ID total as proxy
        # (conservative: report total minus estimated 500MB overhead for driver)
        total = IntelProvider._read_device_vram_mib()
        if total is not None:
            return total - 500  # conservative: reserve for driver overhead
        return None

    @staticmethod
    def get_total_vram_mib(gpu_index: int = 0) -> int | None:
        mem = IntelProvider._query_memory(gpu_index)
        if mem:
            return mem["total"]
        # xe driver: read from PCI device ID table
        return IntelProvider._read_device_vram_mib()

    @staticmethod
    def scan_compute_apps() -> list[dict[str, Any]]:
        """Detect Intel GPU compute processes.

        Uses sycl-smi --compute-apps if available, falls back to scanning
        /proc/*/maps for i915 / xe kernel driver references.
        """
        # Try sycl-smi first
        try:
            out = subprocess.check_output(
                [_SYCL_SMI, "--show-compute-apps", "-d", "0"],
                text=True, timeout=5,
            )
            apps: list[dict[str, Any]] = []
            for line in out.splitlines():
                # sycl-smi format: "  PID   Name    GPU  Memory"
                parts = line.split()
                if len(parts) >= 1:
                    try:
                        pid = int(parts[0])
                        apps.append({"pid": pid, "used_memory_mib": 0})
                    except ValueError:
                        continue
            return apps
        except (FileNotFoundError, subprocess.SubprocessError, OSError):
            pass

        # Fallback: scan /proc for processes using Intel GPU via /dev/dri
        return _scan_dri_rendering_processes()

    @staticmethod
    def gpu_backend_name() -> str:
        return "sycl"


# ---------------------------------------------------------------------------
# Provider: None (CPU-only / dev mode)
# ---------------------------------------------------------------------------

class NullProvider:
    """No GPU detected — all queries return None / empty."""

    @staticmethod
    def get_used_vram_mib(gpu_index: int = 0) -> int | None:
        return None

    @staticmethod
    def get_free_vram_mib(gpu_index: int = 0) -> int | None:
        return None

    @staticmethod
    def get_total_vram_mib(gpu_index: int = 0) -> int | None:
        return None

    @staticmethod
    def scan_compute_apps() -> list[dict[str, Any]]:
        return []

    @staticmethod
    def gpu_backend_name() -> str:
        return "none"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_csv_int(out: str) -> int | None:
    """Extract first integer from nvidia-smi CSV output."""
    line = out.strip().splitlines()[0] if out.strip() else ""
    if not line:
        return None
    try:
        return int(line.strip().split(",")[0].strip())
    except (ValueError, IndexError):
        return None


def _parse_mem_line(line: str) -> int:
    """Extract a MiB integer from a sycl-smi memory line like '  16384 MiB'."""
    tokens = line.split()
    for tok in reversed(tokens):
        clean = tok.replace(",", "").replace("MiB", "").replace("Mi", "")
        try:
            return int(clean)
        except ValueError:
            continue
    return 0


def _scan_dri_rendering_processes() -> list[dict[str, Any]]:
    """Fallback: find processes with open file descriptors to /dev/dri/renderD*."""
    apps: list[dict[str, Any]] = []
    proc_root = __import__("pathlib").Path("/proc")
    if not proc_root.exists():
        return apps
    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        fd_dir = entry / "fd"
        if not fd_dir.exists():
            continue
        try:
            for fd_link in fd_dir.iterdir():
                try:
                    target = os.readlink(str(fd_link))
                    if "/dev/dri/renderD" in target:
                        apps.append({"pid": int(entry.name), "used_memory_mib": 0})
                        break
                except OSError:
                    continue
        except OSError:
            continue
    return apps


# ---------------------------------------------------------------------------
# Backend registry + auto-detection
# ---------------------------------------------------------------------------

_provider_instance: Any = None
_detected_vendor: GpuVendor | None = None


def detect_gpu_vendor(override: str | None = None) -> GpuVendor:
    """Auto-detect GPU vendor. Returns GpuVendor enum.

    Resolution order:
      1. override parameter (from TURBOHAUL_GPU_BACKEND env or config)
      2. nvidia-smi available → NVIDIA
      3. sycl-smi available → Intel
      4. /dev/dri/renderD128 exists → Intel (fallback heuristic)
      5. None → NullProvider (CPU-only / dev)
    """
    if override:
        low = override.lower().strip()
        if low in ("cuda", "nvidia", "nvidia-smi"):
            return GpuVendor.NVIDIA
        if low in ("sycl", "intel", "sycl-smi", "arc"):
            return GpuVendor.INTEL
        if low in ("none", "cpu", "off"):
            return GpuVendor.NONE

    if _has_nvidia_smi():
        log.info("gpu_backend: detected NVIDIA GPU via nvidia-smi")
        return GpuVendor.NVIDIA
    if _has_sycl_smi():
        log.info("gpu_backend: detected Intel GPU via sycl-smi")
        return GpuVendor.INTEL
    if _has_dev_dri():
        log.info("gpu_backend: detected Intel GPU via /dev/dri/renderD128 (fallback)")
        return GpuVendor.INTEL
    log.info("gpu_backend: no GPU detected — using null provider (CPU-only / dev)")
    return GpuVendor.NONE


def get_provider(override: str | None = None) -> Any:
    """Get the active GPU provider singleton."""
    global _provider_instance, _detected_vendor
    env_override = override or os.environ.get("TURBOHAUL_GPU_BACKEND")
    vendor = detect_gpu_vendor(env_override)
    if _provider_instance is not None and _detected_vendor == vendor:
        return _provider_instance
    _detected_vendor = vendor
    if vendor == GpuVendor.NVIDIA:
        _provider_instance = NvidiaProvider()
    elif vendor == GpuVendor.INTEL:
        _provider_instance = IntelProvider()
    else:
        _provider_instance = NullProvider()
    return _provider_instance


def gpu_backend_name(override: str | None = None) -> str:
    """Return 'cuda', 'sycl', or 'none'."""
    return get_provider(override).gpu_backend_name()


# ---------------------------------------------------------------------------
# Convenience functions (drop-in replacements for nvidia-smi calls)
# ---------------------------------------------------------------------------

def get_gpu_memory_used_mib(gpu_index: int = 0) -> int | None:
    """Return GPU memory used in MiB. Backend-agnostic."""
    return get_provider().get_used_vram_mib(gpu_index)


def get_gpu_memory_free_mib(gpu_index: int = 0) -> int | None:
    """Return GPU memory free in MiB. Backend-agnostic."""
    return get_provider().get_free_vram_mib(gpu_index)


def get_gpu_memory_total_mib(gpu_index: int = 0) -> int | None:
    """Return GPU total memory in MiB. Backend-agnostic."""
    return get_provider().get_total_vram_mib(gpu_index)


def scan_gpu_compute_apps() -> list[dict[str, Any]]:
    """Return [{pid, used_memory_mib}]. Backend-agnostic."""
    return get_provider().scan_compute_apps()
