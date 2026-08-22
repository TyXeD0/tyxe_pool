#!/usr/bin/env python3
import html
import json
import os
import socket
import threading
import time
import uuid
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE = os.environ.get("PROXY_POOL_HOME", "/etc/proxy-pool")
STATE = os.path.join(BASE, "controller-state.json")
BIND = os.environ.get("PROXY_POOL_BIND", "127.0.0.1")
PORT = int(os.environ.get("PROXY_POOL_PORT", "9101"))
LANG = os.environ.get("PROXY_POOL_LANG", "en") if os.environ.get("PROXY_POOL_LANG") in ("ru", "en") else "en"
POLL_INTERVAL = int(os.environ.get("PROXY_POOL_POLL_INTERVAL", "5"))
LOCK = threading.RLock()

TEXT = {
    "ru": {
        "title": "TYXE Pool",
        "subtitle": "Центральная панель · Node Manager v0.2",
        "nodes": "Ноды",
        "add": "Добавить ноду",
        "name": "Имя",
        "address": "Адрес / tunnel IP",
        "port": "Порт агента",
        "token": "API token агента",
        "save": "Добавить",
        "remove": "Удалить",
        "status": "Статус",
        "telemt": "Telemt",
        "last": "Последняя проверка",
        "cpu": "Load average",
        "memory": "Свободная RAM",
        "uptime": "Uptime",
        "empty": "Ноды пока не добавлены.",
        "architecture": "Архитектура",
        "arch_text": "ENTER/controller → HAProxy → AWG/transport → EXIT nodes → Telemt",
        "note": "v0.2 регистрирует и мониторит node-agent. Удалённая установка Telemt по SSH и синхронизация secrets будут добавлены следующим этапом.",
        "auth": "ошибка авторизации",
        "down": "недоступна",
        "up": "доступна",
        "unknown": "неизвестно",
        "saving": "Сохранение...",
    },
    "en": {
        "title": "TYXE Pool",
        "subtitle": "Central panel · Node Manager v0.2",
        "nodes": "Nodes",
        "add": "Add node",
        "name": "Name",
        "address": "Address / tunnel IP",
        "port": "Agent port",
        "token": "Agent API token",
        "save": "Add",
        "remove": "Remove",
        "status": "Status",
        "telemt": "Telemt",
        "last": "Last check",
        "cpu": "Load average",
        "memory": "Free RAM",
        "uptime": "Uptime",
        "empty": "No nodes have been added yet.",
        "architecture": "Architecture",
        "arch_text": "ENTER/controller → HAProxy → AWG/transport → EXIT nodes → Telemt",
        "note": "v0.2 registers and monitors node-agents. SSH Telemt provisioning and secret synchronization are the next milestone.",
        "auth": "authentication error",
        "down": "down",
        "up": "up",
        "unknown": "unknown",
        "saving": "Saving...",
    },
}
T = TEXT[LANG]


def default_state():
    return {"version": 2, "language": LANG, "nodes": []}


def load_state():
    with LOCK:
        os.makedirs(BASE, exist_ok=True)
        if not os.path.exists(STATE):
            return default_state()
        try:
            with open(STATE, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return default_state()
        data.setdefault("version", 2)
        data.setdefault("language", LANG)
        data.setdefault("nodes", [])
        return data


def save_state(state):
    with LOCK:
        os.makedirs(BASE, exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE)


def public_node(node):
    # Never expose node API tokens to the browser/API response.
    result = {k: v for k, v in node.items() if k != "token"}
    result["has_token"] = bool(node.get("token"))
    return result


def agent_status(node):
    address = node.get("address", "")
    port = int(node.get("agent_port", 9100))
    url = f"http://{address}:{port}/v1/status"
    headers = {"Accept": "application/json"}
    token = node.get("token", "")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=2.5) as response:
            if response.status != 200:
                return False, {"probe_error": f"HTTP {response.status}"}
            payload = json.loads(response.read().decode("utf-8"))
            return True, payload
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            return False, {"probe_error": "auth"}
        return False, {"probe_error": f"HTTP {exc.code}"}
    except (urllib.error.URLError, socket.timeout, TimeoutError, ValueError, OSError) as exc:
        return False, {"probe_error": type(exc).__name__}


def refresh_nodes():
    while True:
        state = load_state()
        changed = False
        for node in state.get("nodes", []):
            ok, payload = agent_status(node)
            new_status = "up" if ok else ("auth_error" if payload.get("probe_error") == "auth" else "down")
            if node.get("status") != new_status:
                node["status"] = new_status
                changed = True
            node["last_check"] = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
            node["probe_error"] = payload.get("probe_error", "")
            if ok:
                node["last_seen"] = node["last_check"]
                node["metrics"] = payload
            changed = True
        if changed:
            save_state(state)
        time.sleep(max(2, POLL_INTERVAL))


def escjs(value):
    return json.dumps(value, ensure_ascii=False)


def page_html():
    tx = {k: html.escape(str(v)) for k, v in T.items()}
    js_text = json.dumps(T, ensure_ascii=False)
    return f'''<!doctype html>
<html lang="{LANG}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{tx["title"]}</title><style>
:root{{color-scheme:dark}}*{{box-sizing:border-box}}body{{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#0f1115;color:#e8eaed}}
main{{max-width:1180px;margin:34px auto;padding:0 20px}}h1{{font-size:30px;margin-bottom:4px}}h2{{margin-top:28px}}.muted{{color:#9aa4b2}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(285px,1fr));gap:12px}}
.card{{background:#171a21;border:1px solid #292f3a;border-radius:14px;padding:18px;margin:12px 0}}.ok{{color:#6ee7a8}}.bad{{color:#ff8a8a}}.warn{{color:#ffd166}}
label{{display:block;margin:10px 0 5px;color:#b9c1cc}}input{{width:100%;padding:10px 11px;background:#0e1117;border:1px solid #303846;border-radius:8px;color:#fff}}
button{{margin-top:12px;padding:9px 13px;border:0;border-radius:8px;cursor:pointer}}button.danger{{background:#5b2323;color:#fff}}button.primary{{background:#e8eaed;color:#111}}
.kv{{display:grid;grid-template-columns:120px 1fr;gap:5px;font-size:14px;margin-top:10px}}code{{background:#0a0c10;padding:2px 5px;border-radius:5px}}
</style></head><body><main>
<h1>{tx["title"]}</h1><p class="muted">{tx["subtitle"]} · {html.escape(LANG.upper())}</p>
<h2>{tx["nodes"]}</h2><div class="grid" id="nodes"></div>
<div class="card"><h3>{tx["add"]}</h3><form id="addForm">
<label>{tx["name"]}</label><input id="name" required placeholder="PL1">
<label>{tx["address"]}</label><input id="address" required placeholder="10.10.1.1">
<label>{tx["port"]}</label><input id="port" type="number" value="9100" min="1" max="65535" required>
<label>{tx["token"]}</label><input id="token" type="password" autocomplete="off" placeholder="optional / опционально">
<button class="primary" type="submit">{tx["save"]}</button> <span class="muted" id="formStatus"></span></form></div>
<div class="card"><h3>{tx["architecture"]}</h3><p><code>{tx["arch_text"]}</code></p><p class="muted">{tx["note"]}</p></div>
<script>
const T={js_text};
function fmtSecs(s){{if(s===undefined||s===null)return '-';s=Number(s);const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);return `${{d}}d ${{h}}h ${{m}}m`;}}
function statusLabel(s){{if(s==='up')return T.up;if(s==='auth_error')return T.auth;if(s==='down')return T.down;return T.unknown;}}
async function load(){{const r=await fetch('/api/nodes');const d=await r.json();const e=document.getElementById('nodes');e.innerHTML='';
if(!d.nodes.length){{e.innerHTML=`<div class="card muted">${{T.empty}}</div>`;return;}}
for(const n of d.nodes){{const ok=n.status==='up', cls=ok?'ok':(n.status==='auth_error'?'warn':'bad');const m=n.metrics||{{}};const mem=m.memory||{{}};
e.innerHTML+=`<div class="card"><h3>${{escapeHtml(n.name)}}</h3><div class="${{cls}}">${{statusLabel(n.status).toUpperCase()}}</div><div class="kv"><span>${{T.address}}</span><span>${{escapeHtml(n.address)}}:${{n.agent_port}}</span><span>${{T.telemt}}</span><span>${{m.telemt===true?'UP':(m.telemt===false?'DOWN':'-')}}</span><span>${{T.cpu}}</span><span>${{escapeHtml(String(m.load1??'-'))}}</span><span>${{T.memory}}</span><span>${{mem.available_mb??'-'}} MB</span><span>${{T.uptime}}</span><span>${{fmtSecs(m.uptime_s)}}</span><span>${{T.last}}</span><span>${{escapeHtml(n.last_check||'-')}}</span></div><button class="danger" onclick="removeNode('${{encodeURIComponent(n.id)}}')">${{T.remove}}</button></div>`;}}
}}
function escapeHtml(s){{return String(s).replace(/[&<>'"]/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}}[c]));}}
async function removeNode(id){{if(!confirm(T.remove+'?'))return;await fetch('/api/nodes/'+id,{{method:'DELETE'}});load();}}
document.getElementById('addForm').addEventListener('submit',async ev=>{{ev.preventDefault();const st=document.getElementById('formStatus');st.textContent=T.saving;const nameEl=document.getElementById('name'),addressEl=document.getElementById('address'),portEl=document.getElementById('port'),tokenEl=document.getElementById('token');const payload={{name:nameEl.value.trim(),address:addressEl.value.trim(),agent_port:Number(portEl.value),token:tokenEl.value.trim()}};const r=await fetch('/api/nodes',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify(payload)}});const d=await r.json();st.textContent=r.ok?'OK':(d.error||'Error');if(r.ok){{nameEl.value='';addressEl.value='';tokenEl.value='';portEl.value='9100';load();}}}});
load();setInterval(load,5000);
</script></main></body></html>'''


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, code, body, content_type="application/json; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            return self._send(200, page_html(), "text/html; charset=utf-8")
        if path == "/healthz":
            return self._send(200, json.dumps({"status": "ok", "language": LANG}))
        if path == "/api/settings":
            return self._send(200, json.dumps({"language": LANG, "version": "0.2.0"}))
        if path == "/api/nodes":
            state = load_state()
            return self._send(200, json.dumps({"nodes": [public_node(n) for n in state["nodes"]]}, ensure_ascii=False))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/nodes":
            return self._send(404, json.dumps({"error": "not found"}))
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self._send(400, json.dumps({"error": "invalid json"}))
        name = str(payload.get("name", "")).strip()
        address = str(payload.get("address", "")).strip()
        try:
            agent_port = int(payload.get("agent_port", 9100))
        except (TypeError, ValueError):
            return self._send(400, json.dumps({"error": "invalid agent_port"}))
        if not name or not address or not (1 <= agent_port <= 65535):
            return self._send(400, json.dumps({"error": "name, address and valid agent_port are required"}))
        token = str(payload.get("token", "")).strip()
        state = load_state()
        for node in state["nodes"]:
            if node.get("name") == name:
                node.update({"address": address, "agent_port": agent_port, "status": "unknown"})
                if token:
                    node["token"] = token
                save_state(state)
                return self._send(200, json.dumps(public_node(node), ensure_ascii=False))
        node = {"id": uuid.uuid4().hex[:12], "name": name, "address": address, "agent_port": agent_port, "token": token, "status": "unknown", "created_at": int(time.time())}
        state["nodes"].append(node)
        save_state(state)
        return self._send(201, json.dumps(public_node(node), ensure_ascii=False))

    def do_DELETE(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/nodes/"):
            return self._send(404, json.dumps({"error": "not found"}))
        node_id = path.split("/", 3)[-1]
        state = load_state()
        old_len = len(state["nodes"])
        state["nodes"] = [n for n in state["nodes"] if n.get("id") != node_id]
        if len(state["nodes"]) == old_len:
            return self._send(404, json.dumps({"error": "node not found"}))
        save_state(state)
        return self._send(200, json.dumps({"status": "deleted"}))


def main():
    os.makedirs(BASE, exist_ok=True)
    if not os.path.exists(STATE):
        save_state(default_state())
    threading.Thread(target=refresh_nodes, daemon=True).start()
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    srv.serve_forever()


if __name__ == "__main__":
    main()
