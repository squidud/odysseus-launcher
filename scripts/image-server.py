#!/usr/bin/env python3
"""
OpenAI-compatible image generation server using SDXL-Turbo on Apple Silicon (Metal/MPS).
Provides /v1/images/generations and /v1/models for Odysseus.
Runs natively on macOS — no Docker required.
"""

import argparse, base64, io, json, logging, time
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(level=logging.INFO, format="[image-server] %(message)s")
log = logging.getLogger(__name__)

MODEL_ID   = "stabilityai/sdxl-turbo"
MODEL_NAME = "sdxl-turbo"
PORT       = 8090
_pipe      = None


def load_pipeline():
    global _pipe
    import torch
    from diffusers import AutoPipelineForText2Image

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    dtype  = torch.float16

    log.info(f"Loading {MODEL_ID} on {device} ({dtype}) …")
    _pipe = AutoPipelineForText2Image.from_pretrained(
        MODEL_ID,
        torch_dtype=dtype,
        variant="fp16",
    ).to(device)
    _pipe.set_progress_bar_config(disable=True)
    log.info("Model ready.")


def generate(prompt: str, steps: int = 4, size: str = "1024x1024") -> str:
    """Return base64-encoded PNG."""
    import torch
    w, h = (int(x) for x in size.lower().replace("x", "x").split("x")) if "x" in size else (1024, 1024)
    w, h = max(256, min(w, 1024)), max(256, min(h, 1024))

    with torch.inference_mode():
        image = _pipe(
            prompt=prompt,
            num_inference_steps=steps,
            guidance_scale=0.0,   # SDXL-Turbo uses guidance_scale=0
            width=w,
            height=h,
        ).images[0]

    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def _send(self, status: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            self._send(200, {"data": [{"id": MODEL_NAME, "object": "model", "type": "image"}]})
        else:
            self._send(404, {"error": "Not found"})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("images/generations"):
            self._send(404, {"error": "Not found"}); return

        length = int(self.headers.get("Content-Length", 0))
        body   = json.loads(self.rfile.read(length) or b"{}")

        prompt  = body.get("prompt", "")
        n       = body.get("n", 1)
        size    = body.get("size", "1024x1024")
        steps   = body.get("num_inference_steps", 4)

        if not prompt:
            self._send(400, {"error": "prompt is required"}); return

        t0 = time.time()
        log.info(f"Generating: {prompt[:60]!r} size={size} steps={steps}")
        try:
            data = [{"b64_json": generate(prompt, steps=steps, size=size)} for _ in range(n)]
            log.info(f"Done in {time.time()-t0:.1f}s")
            self._send(200, {"created": int(t0), "data": data})
        except Exception as e:
            log.error(f"Generation failed: {e}")
            self._send(500, {"error": str(e)})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()

    load_pipeline()

    server = HTTPServer(("0.0.0.0", args.port), Handler)
    log.info(f"Listening on :{args.port}")
    server.serve_forever()
