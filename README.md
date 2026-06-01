# Odysseus Launcher

A native macOS app that bootstraps [Odysseus](https://github.com/pewdiepie-archdaemon/odysseus), a self-hosted local AI assistant. It manages Colima, Docker, and local llama.cpp model servers, then opens the Odysseus web UI in its own window.

On first launch, Odysseus is cloned from GitHub automatically.

## Requirements

- macOS 13+ on Apple Silicon
- [Homebrew](https://brew.sh)

Install dependencies:

```sh
brew install colima docker llama.cpp python3 git
pip3 install diffusers torch transformers accelerate
```

## Install

**Option 1 — pre-built app:**

Download `Odysseus.app.zip` from [Releases](../../releases/latest), unzip, and move to `/Applications`.

**Option 2 — build from source:**

```sh
git clone https://github.com/squidud/odysseus-launcher
cd odysseus-launcher
./build.sh
```

`build.sh` compiles the app, installs it to `/Applications`, and copies the launcher scripts to `~/odysseus/`.

## First launch

The app will:

1. Clone Odysseus into `~/odysseus` if it is not already present
2. Configure Colima with CPU and RAM appropriate for your machine (first time only)
3. Start Colima and Docker containers
4. Start local AI model servers
5. Open the Odysseus UI

First launch takes 2-4 minutes. Subsequent launches are fast if services are already running.

## Local models

Download GGUF models from HuggingFace into `~/odysseus/data/huggingface/hub/`.

Use **Odysseus > Configure Odysseus** (Cmd+,) to manage which models load automatically, load or unload individual models, and check for updates. The dialog shows your system RAM and detects Metal GPU availability.

Models are registered as Odysseus endpoints automatically 15 seconds after startup. All running model servers are detected — no manual configuration required.

A starter `llama-config.json` is written to `~/odysseus/` on first install. Recommended models for Apple Silicon (16 GB+ RAM):

| Role | Model |
|---|---|
| Chat / Research | Meta-Llama-3.1-8B-Instruct Q6_K |
| Utility / Tasks | Qwen2.5-3B-Instruct Q6_K |
| Vision | Qwen2.5-VL-7B-Instruct Q4_K_M |
| Coding | Qwen2.5-Coder-7B-Instruct Q4_K_M |
| Image generation | SDXL-Turbo (via `image-server.py`, Metal GPU) |

## Scripts

The `scripts/` directory contains helper processes started alongside Odysseus:

| Script | Purpose |
|---|---|
| `llama-server.sh` | Launches llama.cpp model servers from `llama-config.json` |
| `llama-launcher.py` | Reads config, checks RAM budget, starts models with Metal GPU |
| `json-proxy.py` | Strips prose wrapping from model JSON responses (port 8089) |
| `image-server.py` | SDXL-Turbo image generation on Metal GPU (port 8090) |
| `register-endpoints.py` | Registers running model servers as Odysseus endpoints |

## Behavior

- **Quit** — stops all model servers, Docker containers, and Colima
- **Sleep/wake** — reconnects automatically when the Mac wakes
- **Config dialog** — Odysseus menu > Configure Odysseus (Cmd+,)
- **Updates** — Configure Odysseus dialog > Check for Updates

## Troubleshooting

**Stuck on startup:** Cold start (Colima off) takes 1-3 minutes. The progress bar advances through each stage. If it times out, the web view loads anyway and retries automatically.

**Models not showing in Odysseus:** Models are registered 15 seconds after startup. Open Settings in Odysseus after that delay. The Configure Odysseus dialog shows live port status.
