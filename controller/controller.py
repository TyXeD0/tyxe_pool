#!/usr/bin/env python3
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE = os.environ.get("PROXY_POOL_HOME", "/etc/proxy-pool")
STATE = os.path.join(BASE, "controller-state.json")
BIND = os.environ.get("PROXY_POOL_BIND", "127.0.0.1")
PORT = int(os.environ.get("PROXY_POOL_PORT", "9101"))

HTML = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Proxy Pool</title><style>
body{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#0f1115;color:#e8eaed}
main{max-width:1100px;margin:40px auto;padding:0 20px}h1{font-size:28px}.
card{background:#171a21;border:1px solid #272c36;border-radius:14px;padding:18px;margin:12px 0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}.ok{color:#6ee7a8}.bad{color:#ff8a8a}.muted{color:#9aa4b2}code{background:#0a0c10;padding:2px 5px;border-radius:5px}
</style></head><body><main>
<h1>Proxy Pool</h1><p class="muted">v0.1 controller · bootstrap dashboard</p>
<div class="grid" id="nodes"></div><div class="card"><h3>Architecture</h3><p>Controller/entry node → HAProxy → AWG/exit nodes → Telemt.</p><p class="muted">Automatic Telemt sync and Globalping are planned for the next milestone.</p></div>
<script>
async function load(){let r=await fetch('/api/nodes');let d=await r.json();let e=document.getElementById('nodes');e.innerHTML='';
for(const n of d.nodes){let ok=n.status==='up';e.innerHTML+=`<div class="card"><h3>${n.name}</h3><div class="${ok?'ok':'bad'}">${n.status.toUpperCase()}</div><p>${n.address}</p><p class="muted">last heartbeat: ${n.last_seen||'never'}</p></div>`}}
load();setInterval(load,5000);
</script></main></body></html>'''


def load_state():
    os.makedirs(BASE, exist_ok=True)
    if not os.path.exists(STATE):
        return {"version": 1, "nodes": []}
    with open(STATE, "r", encoding="utf-8") as f:
        return json.load(f)


def save_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    os.replace(tmp, STATE)


def tcp_check(host, port, timeout=2.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def refresh_nodes():
    while True:
        state = load_state()
        changed = False
        for node in state.get("nodes", []):
            host = node.get("address", "")
            port = int(node.get("agent_port", 9100))
            up = tcp_check(host, port)
            new = "up" if up else "down"
            if node.get("status") != new:
                node["status"] = new
                changed = True
            if up:
                node["last_seen"] = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
                changed = True
        if changed:
            save_state(state)
        time.sleep(5)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, code, body, content_type="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            return self._send(200, HTML, "text/html; charset=utf-8")
        if path == "/healthz":
            return self._send(200, '{"status":"ok"}')
        if path == "/api/nodes":
            return self._send(200, json.dumps(load_state(), ensure_ascii=False))
        self._send(404, '{"error":"not found"}')

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/nodes":
            return self._send(404, '{"error":"not found"}')
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self._send(400, '{"error":"invalid json"}')
        name = str(payload.get("name", "")).strip()
        address = str(payload.get("address", "")).strip()
        if not name or not address:
            return self._send(400, '{"error":"name and address are required"}')
        state = load_state()
        for n in state["nodes"]:
            if n["name"] == name:
                n.update(payload)
                n["status"] = "unknown"
                save_state(state)
                return self._send(200, json.dumps(n))
        node = {"name": name, "address": address, "agent_port": int(payload.get("agent_port", 9100)), "status": "unknown"}
        state["nodes"].append(node)
        save_state(state)
        return self._send(201, json.dumps(node))


def main():
    t = threading.Thread(target=refresh_nodes, daemon=True)
    t.start()
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.serve_forever()

if __name__ == "__main__":
    main()
