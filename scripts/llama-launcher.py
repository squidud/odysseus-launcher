#!/usr/bin/env python3
"""
Launches llama-server instances from llama-config.json.
Called by llama-server.sh and the Odysseus.app config dialog.
"""
import json, os, socket, subprocess, sys
from pathlib import Path

LLAMA  = "/opt/homebrew/bin/llama-server"
CACHE  = Path.home() / "odysseus/data/huggingface/hub"
CONFIG = Path.home() / "odysseus/llama-config.json"
LOGS   = Path("/tmp/odysseus-llama")
LOGS.mkdir(exist_ok=True)


# ── System detection ───────────────────────────────────────────────────────

def _sysctl_int(key: str) -> int:
    try:
        out = subprocess.check_output(["sysctl", "-n", key], text=True).strip()
        return int(out)
    except Exception:
        return 0

def detect_ram_gb() -> int:
    mem = _sysctl_int("hw.memsize")
    return mem // (1024 ** 3) if mem else 8

def detect_cpu_count() -> int:
    n = _sysctl_int("hw.ncpu")
    return n if n else 4

def metal_available() -> bool:
    """Apple Silicon always has Metal; detect via GPU brand string."""
    try:
        out = subprocess.check_output(
            ["system_profiler", "SPDisplaysDataType"], text=True, stderr=subprocess.DEVNULL)
        return "Apple" in out
    except Exception:
        return True  # assume Metal on Apple Silicon

RAM_GB     = detect_ram_gb()
CPU_COUNT  = detect_cpu_count()
HAS_METAL  = metal_available()
# Offload all layers to Metal GPU (shared memory on Apple Silicon — safe with any model size)
GPU_LAYERS = 99 if HAS_METAL else 0

print(f"[launcher] System: {RAM_GB} GB RAM · {CPU_COUNT} CPU · Metal={'yes' if HAS_METAL else 'no'}", flush=True)


# ── File helpers ───────────────────────────────────────────────────────────

def find_file(name: str) -> Path | None:
    for p in CACHE.rglob(name):
        if not p.name.endswith(".incomplete"):
            return p
    return None


def file_size_gb(path: Path) -> float:
    try:
        return path.stat().st_size / (1024 ** 3)
    except Exception:
        return 0.0


def port_in_use(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def load_config() -> list[dict]:
    if not CONFIG.exists():
        return []
    return json.loads(CONFIG.read_text())


# ── RAM budget tracking ────────────────────────────────────────────────────

def ram_budget_ok(model_path: Path, already_loaded_gb: float) -> bool:
    """Return True if loading this model looks safe given available RAM."""
    model_gb = file_size_gb(model_path)
    # Reserve 4 GB for OS + Colima overhead; each model needs ~1.2x its file size in RAM
    needed = model_gb * 1.2
    available = RAM_GB - 4 - already_loaded_gb
    if needed > available:
        print(f"[launcher] WARNING: {model_path.name} needs ~{needed:.1f} GB but only "
              f"~{available:.1f} GB available — skipping auto-start", flush=True)
        return False
    return True


# ── Model launcher ─────────────────────────────────────────────────────────

def start_model(entry: dict, loaded_gb: float = 0.0) -> float:
    """Start a model. Returns GB used (0 if skipped)."""
    model_file = find_file(entry["file"])
    if not model_file:
        print(f"[launcher] {entry['file']}: not downloaded", flush=True)
        return 0.0

    port = entry["port"]
    if port_in_use(port):
        print(f"[launcher] port {port} already in use", flush=True)
        return file_size_gb(model_file)  # count it toward budget

    if not ram_budget_ok(model_file, loaded_gb):
        return 0.0

    cmd = [
        LLAMA,
        "--model", str(model_file),
        "--host", "0.0.0.0",
        "--port", str(port),
        "--ctx-size", str(entry.get("ctx", 8192)),
        "--n-gpu-layers", str(GPU_LAYERS),
        "--alias", model_file.stem,
    ]

    extra = entry.get("args", "")
    if extra:
        cmd += extra.split()

    mmproj_name = entry.get("mmproj")
    if mmproj_name:
        mp = find_file(mmproj_name)
        if mp:
            cmd += ["--mmproj", str(mp)]

    model_gb = file_size_gb(model_file)
    log = LOGS / f"{model_file.stem}.log"
    print(f"[launcher] {model_file.name} ({model_gb:.1f} GB) → :{port} "
          f"(gpu_layers={GPU_LAYERS})", flush=True)
    subprocess.Popen(cmd, stdout=open(log, "w"), stderr=subprocess.STDOUT)
    return model_gb


def stop_port(port: int):
    """Kill whatever is listening on port."""
    import signal
    try:
        result = subprocess.run(
            ["lsof", "-ti", f":{port}", "-sTCP:LISTEN"],
            capture_output=True, text=True)
        for pid in result.stdout.split():
            try:
                os.kill(int(pid), signal.SIGTERM)
            except Exception:
                pass
    except Exception:
        pass


def autostart():
    """Start all models marked autoStart=true, respecting the RAM budget."""
    if not Path(LLAMA).exists():
        print("[launcher] llama-server not found at /opt/homebrew/bin/llama-server", flush=True)
        return
    loaded_gb = 0.0
    for entry in load_config():
        if entry.get("autoStart"):
            used = start_model(entry, loaded_gb)
            loaded_gb += used


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "start":
        port = int(sys.argv[2])
        for entry in load_config():
            if entry["port"] == port:
                start_model(entry)
                break
    elif len(sys.argv) == 3 and sys.argv[1] == "stop":
        stop_port(int(sys.argv[2]))
    else:
        autostart()
