#!/usr/bin/env python3
import hashlib
import hmac
import html
import json
import os
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

VERSION = "0.2.1"
BASE = os.environ.get("PROXY_POOL_HOME", "/etc/proxy-pool")
STATE = os.path.join(BASE, "controller-state.json")
BIND = os.environ.get("PROXY_POOL_BIND", "127.0.0.1")
PORT = int(os.environ.get("PROXY_POOL_PORT", "9101"))
LANG = os.environ.get("PROXY_POOL_LANG", "en") if os.environ.get("PROXY_POOL_LANG") in ("ru", "en") else "en"
POLL_INTERVAL = int(os.environ.get("PROXY_POOL_POLL_INTERVAL", "5"))
ADMIN_USER = os.environ.get("PROXY_POOL_ADMIN_USER", "admin")
ADMIN_HASH = os.environ.get("PROXY_POOL_ADMIN_HASH", "")
SESSION_SECRET = os.environ.get("PROXY_POOL_SESSION_SECRET", "")
LOCAL_API_TOKEN = os.environ.get("PROXY_POOL_LOCAL_API_TOKEN", "")
COOKIE_SECURE = os.environ.get("PROXY_POOL_COOKIE_SECURE", "0") == "1"
SESSION_TTL = int(os.environ.get("PROXY_POOL_SESSION_TTL", "43200"))
LOCK = threading.RLock()

TEXT = {
    "ru": {
        "title": "TYXE Pool", "subtitle": "Центральная панель · Node Manager v0.2.1", "nodes": "Ноды",
        "add": "Добавить ноду", "name": "Имя", "address": "Адрес / tunnel IP", "port": "Порт агента",
        "token": "API token агента", "save": "Добавить", "remove": "Удалить", "status": "Статус",
        "telemt": "Telemt", "last": "Последняя проверка", "cpu": "Load average", "memory": "Свободная RAM",
        "uptime": "Uptime", "empty": "Ноды пока не добавлены.", "architecture": "Архитектура",
        "arch_text": "ENTER/controller → transport → EXIT → Telemt", "note": "Тестовый режим: один ENTER + один EXIT. Telemt/MTProxyL и transport будут добавлены следующим этапом.",
        "auth": "ошибка авторизации", "down": "недоступна", "up": "доступна", "unknown": "неизвестно",
        "saving": "Сохранение...", "login_title": "Вход в TYXE Pool", "login": "Логин", "password": "Пароль",
        "sign_in": "Войти", "bad_login": "Неверный логин или пароль.", "logout": "Выйти",
    },
    "en": {
        "title": "TYXE Pool", "subtitle": "Central panel · Node Manager v0.2.1", "nodes": "Nodes",
        "add": "Add node", "name": "Name", "address": "Address / tunnel IP", "port": "Agent port",
        "token": "Agent API token", "save": "Add", "remove": "Remove", "status": "Status",
        "telemt": "Telemt", "last": "Last check", "cpu": "Load average", "memory": "Free RAM",
        "uptime": "Uptime", "empty": "No nodes have been added yet.", "architecture": "Architecture",
        "arch_text": "ENTER/controller → transport → EXIT → Telemt", "note": "Test mode: one ENTER + one EXIT. Telemt/MTProxyL and transport are the next milestone.",
        "auth": "authentication error", "down": "down", "up": "up", "unknown": "unknown",
        "saving": "Saving...", "login_title": "Sign in to TYXE Pool", "login": "Username", "password": "Password",
        "sign_in": "Sign in", "bad_login": "Invalid username or password.", "logout": "Sign out",
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
        data.setdefault("version", 2); data.setdefault("language", LANG); data.setdefault("nodes", [])
        return data


def save_state(state):
    with LOCK:
        os.makedirs(BASE, exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
        os.chmod(tmp, 0o600); os.replace(tmp, STATE)


def public_node(node):
    result = {k: v for k, v in node.items() if k != "token"}
    result["has_token"] = bool(node.get("token"))
    return result


def agent_status(node):
    address = node.get("address", ""); port = int(node.get("agent_port", 9100))
    req = urllib.request.Request(f"http://{address}:{port}/v1/status", headers={"Accept": "application/json"}, method="GET")
    token = node.get("token", "")
    if token: req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=2.5) as response:
            if response.status != 200: return False, {"probe_error": f"HTTP {response.status}"}
            return True, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return False, {"probe_error": "auth" if exc.code == 401 else f"HTTP {exc.code}"}
    except (urllib.error.URLError, socket.timeout, TimeoutError, ValueError, OSError) as exc:
        return False, {"probe_error": type(exc).__name__}


def refresh_nodes():
    while True:
        state = load_state()
        for node in state.get("nodes", []):
            ok, payload = agent_status(node)
            node["status"] = "up" if ok else ("auth_error" if payload.get("probe_error") == "auth" else "down")
            node["last_check"] = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
            node["probe_error"] = payload.get("probe_error", "")
            if ok:
                node["last_seen"] = node["last_check"]; node["metrics"] = payload
        save_state(state)
        time.sleep(max(2, POLL_INTERVAL))


def verify_password(password):
    try:
        algo, rounds_s, salt_hex, digest_hex = ADMIN_HASH.split(":", 3)
        if algo != "pbkdf2_sha256": return False
        got = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt_hex), int(rounds_s)).hex()
        return hmac.compare_digest(got, digest_hex)
    except Exception:
        return False


def sign_session(expiry, nonce):
    msg = f"{ADMIN_USER}:{expiry}:{nonce}".encode()
    return hmac.new(SESSION_SECRET.encode(), msg, hashlib.sha256).hexdigest()


def new_session():
    expiry = int(time.time()) + SESSION_TTL; nonce = secrets.token_hex(16)
    sig = sign_session(expiry, nonce)
    token = f"{expiry}.{nonce}.{sig}"
    csrf = hmac.new(SESSION_SECRET.encode(), ("csrf:" + token).encode(), hashlib.sha256).hexdigest()
    return token, csrf


def valid_session(token):
    try:
        expiry_s, nonce, sig = token.split(".", 2); expiry = int(expiry_s)
        if expiry < int(time.time()): return False
        return hmac.compare_digest(sig, sign_session(expiry, nonce))
    except Exception:
        return False


def csrf_for(token):
    return hmac.new(SESSION_SECRET.encode(), ("csrf:" + token).encode(), hashlib.sha256).hexdigest()


def login_html(error=""):
    err = f'<p class="err">{html.escape(error)}</p>' if error else ""
    return f'''<!doctype html><html lang="{LANG}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(T["login_title"])}</title><style>
    :root{{color-scheme:dark}}body{{font-family:system-ui,-apple-system,sans-serif;background:#0f1115;color:#e8eaed;margin:0}}main{{max-width:390px;margin:13vh auto;padding:24px}}.card{{background:#171a21;border:1px solid #292f3a;border-radius:16px;padding:24px}}label{{display:block;margin:14px 0 6px}}input{{width:100%;box-sizing:border-box;padding:11px;background:#0e1117;border:1px solid #303846;border-radius:8px;color:#fff}}button{{width:100%;margin-top:18px;padding:11px;border:0;border-radius:8px;cursor:pointer}}.err{{color:#ff8a8a}}</style></head><body><main><div class="card"><h1>{html.escape(T["login_title"])}</h1>{err}<form method="post" action="/login"><label>{html.escape(T["login"])}</label><input name="username" autocomplete="username" required autofocus><label>{html.escape(T["password"])}</label><input name="password" type="password" autocomplete="current-password" required><button type="submit">{html.escape(T["sign_in"])}</button></form></div></main></body></html>'''


def page_html(csrf):
    tx = {k: html.escape(str(v)) for k, v in T.items()}; js_text = json.dumps(T, ensure_ascii=False)
    return f'''<!doctype html><html lang="{LANG}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{tx["title"]}</title><style>
:root{{color-scheme:dark}}*{{box-sizing:border-box}}body{{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#0f1115;color:#e8eaed}}main{{max-width:1180px;margin:34px auto;padding:0 20px}}header{{display:flex;justify-content:space-between;align-items:center;gap:15px}}h1{{font-size:30px;margin-bottom:4px}}h2{{margin-top:28px}}.muted{{color:#9aa4b2}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(285px,1fr));gap:12px}}.card{{background:#171a21;border:1px solid #292f3a;border-radius:14px;padding:18px;margin:12px 0}}.ok{{color:#6ee7a8}}.bad{{color:#ff8a8a}}.warn{{color:#ffd166}}label{{display:block;margin:10px 0 5px;color:#b9c1cc}}input{{width:100%;padding:10px 11px;background:#0e1117;border:1px solid #303846;border-radius:8px;color:#fff}}button,.btn{{margin-top:12px;padding:9px 13px;border:0;border-radius:8px;cursor:pointer;text-decoration:none;display:inline-block}}button.danger{{background:#5b2323;color:#fff}}button.primary{{background:#e8eaed;color:#111}}.btn{{background:#2a303b;color:#fff}}.kv{{display:grid;grid-template-columns:120px 1fr;gap:5px;font-size:14px;margin-top:10px}}code{{background:#0a0c10;padding:2px 5px;border-radius:5px}}</style></head><body><main><header><div><h1>{tx["title"]}</h1><p class="muted">{tx["subtitle"]} · {html.escape(LANG.upper())}</p></div><a class="btn" href="/logout">{tx["logout"]}</a></header><h2>{tx["nodes"]}</h2><div class="grid" id="nodes"></div><div class="card"><h3>{tx["add"]}</h3><form id="addForm"><label>{tx["name"]}</label><input id="name" required placeholder="PL1"><label>{tx["address"]}</label><input id="address" required placeholder="10.10.1.1"><label>{tx["port"]}</label><input id="port" type="number" value="9100" min="1" max="65535" required><label>{tx["token"]}</label><input id="token" type="password" autocomplete="off"><button class="primary" type="submit">{tx["save"]}</button> <span class="muted" id="formStatus"></span></form></div><div class="card"><h3>{tx["architecture"]}</h3><p><code>{tx["arch_text"]}</code></p><p class="muted">{tx["note"]}</p></div><script>
const T={js_text}, CSRF={json.dumps(csrf)}; function fmtSecs(s){{if(s===undefined||s===null)return '-';s=Number(s);const d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);return `${{d}}d ${{h}}h ${{m}}m`;}}function statusLabel(s){{if(s==='up')return T.up;if(s==='auth_error')return T.auth;if(s==='down')return T.down;return T.unknown;}}function escapeHtml(s){{return String(s).replace(/[&<>'"]/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}}[c]));}}async function api(url,opt={{}}){{opt.headers=Object.assign({{}},opt.headers||{{}},{{'X-TYXE-CSRF':CSRF}});const r=await fetch(url,opt);if(r.status===401)location='/login';return r;}}async function load(){{const r=await api('/api/nodes');if(!r.ok)return;const d=await r.json();const e=document.getElementById('nodes');e.innerHTML='';if(!d.nodes.length){{e.innerHTML=`<div class="card muted">${{T.empty}}</div>`;return;}}for(const n of d.nodes){{const ok=n.status==='up',cls=ok?'ok':(n.status==='auth_error'?'warn':'bad'),m=n.metrics||{{}},mem=m.memory||{{}};e.innerHTML+=`<div class="card"><h3>${{escapeHtml(n.name)}}</h3><div class="${{cls}}">${{statusLabel(n.status).toUpperCase()}}</div><div class="kv"><span>${{T.address}}</span><span>${{escapeHtml(n.address)}}:${{n.agent_port}}</span><span>${{T.telemt}}</span><span>${{m.telemt===true?'UP':(m.telemt===false?'DOWN':'-')}}</span><span>${{T.cpu}}</span><span>${{escapeHtml(String(m.load1??'-'))}}</span><span>${{T.memory}}</span><span>${{mem.available_mb??'-'}} MB</span><span>${{T.uptime}}</span><span>${{fmtSecs(m.uptime_s)}}</span><span>${{T.last}}</span><span>${{escapeHtml(n.last_check||'-')}}</span></div><button class="danger" onclick="removeNode('${{encodeURIComponent(n.id)}}')">${{T.remove}}</button></div>`;}}}}async function removeNode(id){{if(!confirm(T.remove+'?'))return;await api('/api/nodes/'+id,{{method:'DELETE'}});load();}}document.getElementById('addForm').addEventListener('submit',async ev=>{{ev.preventDefault();const st=document.getElementById('formStatus');st.textContent=T.saving;const p={{name:name.value.trim(),address:address.value.trim(),agent_port:Number(port.value),token:token.value.trim()}};const r=await api('/api/nodes',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify(p)}});const d=await r.json();st.textContent=r.ok?'OK':(d.error||'Error');if(r.ok){{name.value='';address.value='';token.value='';port.value='9100';load();}}}});load();setInterval(load,5000);
</script></main></body></html>'''


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): return
    def _send(self, code, body, content_type="application/json; charset=utf-8", headers=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", content_type); self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff"); self.send_header("X-Frame-Options", "DENY"); self.send_header("Referrer-Policy", "no-referrer")
        if headers:
            for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def _cookie_token(self):
        c = SimpleCookie(); c.load(self.headers.get("Cookie", "")); morsel = c.get("tyxe_session"); return morsel.value if morsel else ""
    def _local_api_auth(self): return bool(LOCAL_API_TOKEN) and hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {LOCAL_API_TOKEN}")
    def _session_auth(self):
        token = self._cookie_token(); return token if token and valid_session(token) else ""
    def _authorized(self): return self._local_api_auth() or bool(self._session_auth())
    def _csrf_ok(self):
        if self._local_api_auth(): return True
        token = self._session_auth(); return bool(token) and hmac.compare_digest(self.headers.get("X-TYXE-CSRF", ""), csrf_for(token))
    def _redirect(self, loc, cookie=None):
        headers = [("Location", loc)]
        if cookie: headers.append(("Set-Cookie", cookie))
        self._send(303, b"", "text/plain", headers)
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz": return self._send(200, json.dumps({"status": "ok"}))
        if path == "/login":
            if self._session_auth(): return self._redirect("/")
            return self._send(200, login_html(), "text/html; charset=utf-8")
        if path == "/logout":
            cookie = "tyxe_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" + ("; Secure" if COOKIE_SECURE else "")
            return self._redirect("/login", cookie)
        if not self._authorized(): return self._redirect("/login") if path == "/" else self._send(401, json.dumps({"error":"unauthorized"}))
        token = self._session_auth()
        if path == "/": return self._send(200, page_html(csrf_for(token) if token else ""), "text/html; charset=utf-8")
        if path == "/api/settings": return self._send(200, json.dumps({"language": LANG, "version": VERSION}))
        if path == "/api/nodes":
            state=load_state(); return self._send(200, json.dumps({"nodes":[public_node(n) for n in state["nodes"]]}, ensure_ascii=False))
        return self._send(404, json.dumps({"error":"not found"}))
    def do_POST(self):
        path=urlparse(self.path).path
        length=min(int(self.headers.get("Content-Length","0") or 0), 65536)
        raw=self.rfile.read(length)
        if path == "/login":
            form=urllib.parse.parse_qs(raw.decode("utf-8", "replace")); user=form.get("username",[""])[0]; password=form.get("password",[""])[0]
            if hmac.compare_digest(user, ADMIN_USER) and verify_password(password):
                token,_=new_session(); cookie=f"tyxe_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}" + ("; Secure" if COOKIE_SECURE else "")
                return self._redirect("/", cookie)
            time.sleep(0.35); return self._send(401, login_html(T["bad_login"]), "text/html; charset=utf-8")
        if not self._authorized(): return self._send(401, json.dumps({"error":"unauthorized"}))
        if not self._csrf_ok(): return self._send(403, json.dumps({"error":"csrf"}))
        if path != "/api/nodes": return self._send(404, json.dumps({"error":"not found"}))
        try: payload=json.loads(raw or b"{}")
        except Exception: return self._send(400, json.dumps({"error":"invalid json"}))
        name=str(payload.get("name","")).strip(); address=str(payload.get("address","")).strip()
        try: agent_port=int(payload.get("agent_port",9100))
        except (TypeError,ValueError): return self._send(400,json.dumps({"error":"invalid agent_port"}))
        if not name or not address or not (1<=agent_port<=65535): return self._send(400,json.dumps({"error":"name, address and valid agent_port are required"}))
        token=str(payload.get("token","")).strip(); state=load_state()
        for node in state["nodes"]:
            if node.get("name")==name:
                node.update({"address":address,"agent_port":agent_port,"status":"unknown"});
                if token: node["token"]=token
                save_state(state); return self._send(200,json.dumps(public_node(node),ensure_ascii=False))
        node={"id":uuid.uuid4().hex[:12],"name":name,"address":address,"agent_port":agent_port,"token":token,"status":"unknown","created_at":int(time.time())}
        state["nodes"].append(node); save_state(state); return self._send(201,json.dumps(public_node(node),ensure_ascii=False))
    def do_DELETE(self):
        path=urlparse(self.path).path
        if not self._authorized(): return self._send(401,json.dumps({"error":"unauthorized"}))
        if not self._csrf_ok(): return self._send(403,json.dumps({"error":"csrf"}))
        if not path.startswith("/api/nodes/"): return self._send(404,json.dumps({"error":"not found"}))
        node_id=path.split("/",3)[-1]; state=load_state(); old=len(state["nodes"]); state["nodes"]=[n for n in state["nodes"] if n.get("id")!=node_id]
        if len(state["nodes"])==old: return self._send(404,json.dumps({"error":"node not found"}))
        save_state(state); return self._send(200,json.dumps({"status":"deleted"}))


def main():
    if not ADMIN_HASH or not SESSION_SECRET:
        raise SystemExit("panel credentials are not configured")
    os.makedirs(BASE, exist_ok=True)
    if not os.path.exists(STATE): save_state(default_state())
    threading.Thread(target=refresh_nodes, daemon=True).start()
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()

if __name__ == "__main__": main()
