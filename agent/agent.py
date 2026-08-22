#!/usr/bin/env python3
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

VERSION = "0.3.0"
BIND = os.environ.get("PROXY_POOL_AGENT_BIND", "127.0.0.1")
PORT = int(os.environ.get("PROXY_POOL_AGENT_PORT", "9100"))
TELEMT_SERVICE = os.environ.get("PROXY_POOL_TELEMT_SERVICE", "telemt")
TELEMT_CONFIG = os.environ.get("PROXY_POOL_TELEMT_CONFIG", "/etc/telemt/telemt.toml")
TELEMT_BIN = os.environ.get("PROXY_POOL_TELEMT_BIN", "/bin/telemt")
TOKEN = os.environ.get("PROXY_POOL_AGENT_TOKEN", "")
NODE_NAME = os.environ.get("PROXY_POOL_NODE_NAME", os.uname().nodename)
LANG = os.environ.get("PROXY_POOL_LANG", "en")


def run(args, timeout=4):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except Exception:
        return None


def is_active(service):
    p = run(["systemctl", "is-active", service], 2)
    return bool(p and p.stdout.strip() == "active")


def service_state(service):
    p = run(["systemctl", "is-active", service], 2)
    if not p:
        return "unknown"
    state = p.stdout.strip()
    return state or "inactive"


def telemt_version():
    candidates = [TELEMT_BIN, "/usr/bin/telemt", "/usr/local/bin/telemt"]
    for path in candidates:
        if not os.path.isfile(path):
            continue
        for args in ([path, "--version"], [path, "-V"]):
            p = run(args, 3)
            if p and p.returncode == 0:
                text = (p.stdout or p.stderr).strip().splitlines()
                if text:
                    return text[0][:160]
    return ""


def uptime_s():
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return 0


def memory():
    values = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                key, rest = line.split(":", 1)
                if key in ("MemTotal", "MemAvailable"):
                    values[key] = int(rest.strip().split()[0]) // 1024
    except Exception:
        pass
    return {"total_mb": values.get("MemTotal", 0), "available_mb": values.get("MemAvailable", 0)}


def load1():
    try:
        return round(os.getloadavg()[0], 2)
    except Exception:
        return 0


def telemt_info():
    installed = any(os.path.isfile(p) for p in (TELEMT_BIN, "/usr/bin/telemt", "/usr/local/bin/telemt"))
    return {
        "installed": installed,
        "active": is_active(TELEMT_SERVICE),
        "service_state": service_state(TELEMT_SERVICE),
        "service": TELEMT_SERVICE,
        "version": telemt_version(),
        "config": TELEMT_CONFIG,
        "config_exists": os.path.isfile(TELEMT_CONFIG),
    }


def status():
    ti = telemt_info()
    return {
        "status": "up",
        "node_name": NODE_NAME,
        "agent_time": int(time.time()),
        "uptime_s": uptime_s(),
        "load1": load1(),
        "memory": memory(),
        "telemt": ti["active"],
        "telemt_info": ti,
        "telemt_service": TELEMT_SERVICE,
        "language": LANG,
        "agent_version": VERSION,
    }


def control_telemt(action):
    if action not in ("start", "stop", "restart"):
        return False, "unsupported action"
    p = run(["systemctl", action, TELEMT_SERVICE], 15)
    if not p:
        return False, "systemctl failed"
    if p.returncode != 0:
        return False, (p.stderr or p.stdout or "systemctl failed").strip()[-500:]
    time.sleep(0.4)
    return True, service_state(TELEMT_SERVICE)


def telemt_logs(lines=100):
    lines = max(10, min(int(lines), 500))
    p = run(["journalctl", "-u", TELEMT_SERVICE, "-n", str(lines), "--no-pager", "--output=short-iso"], 8)
    if not p:
        return ""
    return (p.stdout or p.stderr)[-65536:]


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def sendj(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def authorized(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def read_json(self):
        try:
            length = min(int(self.headers.get("Content-Length", "0") or 0), 65536)
            return json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            return self.sendj(200, {"status": "ok", "version": VERSION})
        if not self.authorized():
            return self.sendj(401, {"error": "unauthorized"})
        if parsed.path == "/v1/status":
            return self.sendj(200, status())
        if parsed.path == "/v1/telemt/logs":
            try:
                q = parsed.query.split("lines=", 1)[1].split("&", 1)[0] if "lines=" in parsed.query else "100"
                lines = int(q)
            except Exception:
                lines = 100
            return self.sendj(200, {"service": TELEMT_SERVICE, "logs": telemt_logs(lines)})
        return self.sendj(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if not self.authorized():
            return self.sendj(401, {"error": "unauthorized"})
        if parsed.path == "/v1/telemt/action":
            action = str(self.read_json().get("action", "")).strip().lower()
            ok, message = control_telemt(action)
            return self.sendj(200 if ok else 400, {"ok": ok, "action": action, "state": service_state(TELEMT_SERVICE), "message": message})
        return self.sendj(404, {"error": "not found"})


ThreadingHTTPServer((BIND, PORT), H).serve_forever()
