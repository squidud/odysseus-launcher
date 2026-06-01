#!/bin/zsh
# Odysseus service launcher — starts local AI models, task proxy, and image server.
# Model configuration lives in llama-config.json (edit there or via Odysseus > Model Configuration).

HOME_DIR="$HOME/odysseus"
LOG_DIR="/tmp/odysseus-llama"
mkdir -p "$LOG_DIR"

# ── Local AI models (reads llama-config.json) ──────────────────────────────
python3 "$HOME_DIR/llama-launcher.py"

# ── JSON task proxy (strips prose from model JSON responses) ────────────────
pkill -f "json-proxy.py" 2>/dev/null
python3 "$HOME_DIR/json-proxy.py" &
echo "[services] JSON task proxy on :8089"

# ── SDXL-Turbo image generation (Metal/MPS) ────────────────────────────────
pkill -f "image-server.py" 2>/dev/null
python3 "$HOME_DIR/image-server.py" >> /tmp/odysseus-image-server.log 2>&1 &
echo "[services] Image server starting on :8090"

# ── Register endpoints once models are up ──────────────────────────────────
(sleep 15 && python3 "$HOME_DIR/register-endpoints.py") &

wait
