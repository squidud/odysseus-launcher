#!/usr/bin/env python3
"""Auto-register running llama-server instances as Odysseus model endpoints.
Reads llama-config.json to discover all configured ports — no hardcoded list.
Only fills empty settings slots; never overwrites user choices."""

import sqlite3, uuid, json, time, re, urllib.request, os
from datetime import datetime, timezone
from pathlib import Path

DB       = os.path.expanduser("~/odysseus/data/app.db")
SETTINGS = os.path.expanduser("~/odysseus/data/settings.json")
CONFIG   = os.path.expanduser("~/odysseus/llama-config.json")

# Extra services that aren't in llama-config.json
EXTRA = [
    {"port": 8089, "name": "JSON Task Proxy",  "roles": ["task"]},
    {"port": 8090, "name": "SDXL-Turbo Image", "roles": ["image"]},
]

ROLE_KEYS = {
    "chat":     ("default_endpoint_id",  "default_model"),
    "utility":  ("utility_endpoint_id",  "utility_model"),
    "task":     ("task_endpoint_id",     "task_model"),
    "research": ("research_endpoint_id", "research_model"),
    "vision":   (None,                   "vision_model"),
    "image":    ("image_endpoint_id",    "image_model"),
}


def infer_roles(filename: str) -> list[str]:
    """Guess model roles from filename patterns."""
    name = filename.lower()
    if any(x in name for x in ["vl", "vision", "llava", "minicpm-v", "qwen2.5-vl"]):
        return ["vision"]
    if any(x in name for x in ["coder", "code", "starcoder", "deepseek-coder"]):
        return ["coding"]  # register but don't auto-assign to standard roles
    # Estimate active parameter count
    m = re.search(r"(\d+(?:\.\d+)?)b", name)
    params = float(m.group(1)) if m else 7.0
    if "a3b" in name:
        params = 3.0  # MoE model, 3B active params
    if params <= 4:
        return ["utility", "task"]
    return ["chat", "research"]


def server_ready(port: int, retries: int = 3) -> bool:
    url = f"http://localhost:{port}/v1/models"
    for _ in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=3) as r:
                return r.status == 200
        except Exception:
            pass
        time.sleep(2)
    return False


def get_model_ids(port: int) -> list[str]:
    try:
        with urllib.request.urlopen(f"http://localhost:{port}/v1/models", timeout=3) as r:
            data = json.loads(r.read())
            entries = data.get("data") or data.get("models", [])
            return [e.get("id") or e.get("name") for e in entries
                    if e.get("id") or e.get("name")]
    except Exception:
        return []


def upsert_endpoint(conn, name: str, base_url: str, models: list) -> str:
    now = datetime.now(timezone.utc).isoformat()
    cached = json.dumps(models)
    row = conn.execute("SELECT id FROM model_endpoints WHERE base_url=?", (base_url,)).fetchone()
    if row:
        conn.execute(
            "UPDATE model_endpoints SET name=?, cached_models=?, is_enabled=1, updated_at=? "
            "WHERE base_url=?",
            (name, cached, now, base_url))
        return row[0]
    ep_id = uuid.uuid4().hex[:8]
    conn.execute(
        "INSERT INTO model_endpoints(id,name,base_url,is_enabled,model_type,cached_models,"
        "created_at,updated_at) VALUES(?,?,?,1,'llm',?,?,?)",
        (ep_id, name, base_url, cached, now, now))
    return ep_id


def load_settings() -> dict:
    if os.path.exists(SETTINGS):
        return json.loads(open(SETTINGS).read())
    return {}


def save_settings(s: dict):
    open(SETTINGS, "w").write(json.dumps(s, indent=2))


def load_llama_config() -> list[dict]:
    if os.path.exists(CONFIG):
        return json.loads(open(CONFIG).read())
    return []


# ── Main ─────────────────────────────────────────────────────────────────────

print("Registering local model endpoints...")
conn = sqlite3.connect(DB)
settings = load_settings()

registered = []  # list of (ep_id, roles, primary_model)

# Scan llama-config.json for all configured ports
for entry in load_llama_config():
    port = entry.get("port")
    filename = entry.get("file", "")
    if not port or not filename:
        continue

    base_url = f"http://host.docker.internal:{port}/v1"
    display  = filename.replace(".gguf", "").replace("-Instruct", "").replace("_", " ") + " (local)"

    if not server_ready(port):
        print(f"  :{port} {filename}: offline — skipping")
        continue

    models = get_model_ids(port)
    if not models:
        print(f"  :{port} {filename}: no models returned — skipping")
        continue

    ep_id  = upsert_endpoint(conn, display, base_url, models)
    roles  = infer_roles(filename)
    primary = models[0]
    print(f"  :{port} {display!r} → roles: {roles}, model: {primary}")
    registered.append((ep_id, roles, primary))

# Extra services (JSON proxy, image server)
for svc in EXTRA:
    port = svc["port"]
    base_url = f"http://host.docker.internal:{port}/v1"
    if server_ready(port, retries=2):
        ep_id = upsert_endpoint(conn, svc["name"], base_url, [])
        registered.append((ep_id, svc["roles"], ""))
        print(f"  :{port} {svc['name']!r} registered")

# Assign roles — only fill empty slots, never overwrite user choices
for ep_id, roles, primary_model in registered:
    for role in roles:
        ep_key, model_key = ROLE_KEYS.get(role, (None, None))
        ep_empty  = not settings.get(ep_key,   "").strip() if ep_key    else True
        mod_empty = not settings.get(model_key, "").strip() if model_key else True
        if ep_key and ep_empty:
            settings[ep_key] = ep_id
        if model_key and mod_empty and primary_model:
            settings[model_key] = primary_model

conn.commit()
conn.close()
save_settings(settings)
print("Done.")
