#!/usr/bin/env python3
"""
Odysseus JSON task proxy — sits between Odysseus and llama-server for the
task/utility endpoint. Extracts valid JSON from model responses that wrap
their output in conversational prose, so memory extraction, auto-naming,
and skill extraction reliably get parseable JSON back.

Runs on port 8089, forwards to port 8086 (Qwen2.5-3B).
Register http://host.docker.internal:8089/v1 as the task endpoint in Odysseus.
"""

import re
import json
import http.server
import urllib.request
import urllib.error

UPSTREAM = "http://localhost:8086"
LISTEN_PORT = 8089


def _extract_json(text: str) -> str:
    """Try to pull the first valid JSON array or object out of model output."""
    text = text.strip()

    # Already clean JSON
    if text.startswith(("[", "{")):
        return text

    # Strip markdown fences (```json ... ``` or ``` ... ```)
    fence = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    if fence:
        candidate = fence.group(1).strip()
        try:
            json.loads(candidate)
            return candidate
        except ValueError:
            pass

    # Find first [...] or {...} block
    for pattern in (r"(\[[\s\S]*?\])", r"(\{[\s\S]*?\})"):
        for match in re.finditer(pattern, text):
            candidate = match.group(1)
            try:
                json.loads(candidate)
                return candidate
            except ValueError:
                continue

    return text  # Return as-is; let caller handle parse failure


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress request logs

    def do_GET(self):
        # Forward /v1/models and /slots transparently
        try:
            url = UPSTREAM + self.path
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=10) as r:
                body = r.read()
                self.send_response(r.status)
                for k, v in r.getheaders():
                    if k.lower() not in ("transfer-encoding", "connection"):
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
        except Exception as e:
            self.send_error(502, str(e))

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        is_chat = self.path.rstrip("/").endswith("chat/completions")

        try:
            url = UPSTREAM + self.path
            req = urllib.request.Request(url, data=body,
                                         headers={"Content-Type": "application/json"},
                                         method="POST")
            with urllib.request.urlopen(req, timeout=60) as r:
                resp_body = r.read()
                status = r.status
                resp_headers = list(r.getheaders())
        except urllib.error.HTTPError as e:
            resp_body = e.read()
            status = e.code
            resp_headers = list(e.headers.items())
        except Exception as e:
            self.send_error(502, str(e))
            return

        # Patch chat/completions responses: clean up JSON-in-prose
        if is_chat and status == 200:
            try:
                data = json.loads(resp_body)
                choices = data.get("choices", [])
                for choice in choices:
                    msg = choice.get("message", {})
                    content = msg.get("content", "")
                    if content:
                        cleaned = _extract_json(content)
                        if cleaned != content:
                            msg["content"] = cleaned
                resp_body = json.dumps(data).encode()
            except Exception:
                pass  # leave response untouched if anything fails

        self.send_response(status)
        for k, v in resp_headers:
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", LISTEN_PORT), ProxyHandler)
    print(f"[json-proxy] Listening on :{LISTEN_PORT} → upstream {UPSTREAM}")
    server.serve_forever()
