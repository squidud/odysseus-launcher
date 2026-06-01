# Odysseus Launcher

A native macOS app that bootstraps [Odysseus](https://github.com/pewdiepie-archdaemon/odysseus) — a self-hosted local AI assistant. It starts Colima, Docker, and local llama.cpp model servers in the background, then opens the Odysseus web UI in its own window.

On first launch, Odysseus is automatically cloned from GitHub.

## Requirements

- macOS 13+ (Apple Silicon recommended)
- [Homebrew](https://brew.sh)

Install dependencies:

```sh
brew install colima docker llama.cpp python3 git
pip3 install diffusers torch transformers accelerate
```

## Install

**Option 1 — build from source:**

```sh
git clone https://github.com/squidud/odysseus-launcher
cd odysseus-launcher
./build.sh
```

**Option 2 — download the pre-built app:**

Download `Odysseus.app.zip` from [Releases](../../releases/latest), unzip, and move to `/Applications`.

## First launch

The app will:
1. Clone Odysseus into `~/odysseus` (if not already there)
2. Configure Colima with appropriate CPU/RAM for your machine
3. Start Colima, Docker containers, and local AI model servers
4. Open the Odysseus UI

This takes 2-4 minutes on first launch. Subsequent launches are faster if services are already running.

## Model configuration

Download GGUF models from HuggingFace into `~/odysseus/data/huggingface/hub/` (or use the Odysseus cookbook).

Edit `~/odysseus/llama-config.json` to list your models and which ports they run on. A template is at `llama-config.template.json`. Use **Odysseus > Configure Odysseus** in the menu bar to manage models without editing JSON.

Models are registered automatically as Odysseus endpoints 15 seconds after startup.

## Scripts

`scripts/` contains the helper processes the launcher starts:

| Script | Purpose |
|---|---|
| `llama-server.sh` | Launches llama.cpp model servers |
| `llama-launcher.py` | Reads llama-config.json, starts models with RAM budget checks |
| `json-proxy.py` | Strips prose from model JSON responses (port 8089) |
| `image-server.py` | SDXL-Turbo image generation on Metal GPU (port 8090) |
| `register-endpoints.py` | Registers running models as Odysseus endpoints in the DB |

## Quit behavior

Quitting the app stops all local model servers, Docker containers, and the Colima VM.

## Sleep/wake

The app automatically reconnects after the Mac wakes from sleep.
