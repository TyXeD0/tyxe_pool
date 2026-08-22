#!/usr/bin/env python3
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("PROXY_POOL_AGENT_BIND", "127.0.0.1")
PORT = int(os.environ.get("PROXY_POOL_AGENT_PORT", "9100"))
TELEMT_SERVICE = os.environ.get("PROXY_POOL_TELEMT_SERVICE", "telemt")
TOKEN = os.environ.get("PROXY_POOL_AGENT_TOKEN", "")
NODE_NAME = os.environ.get("PROXY_POOL_NODE_NAME", os.uname().nodename)
LANG = os.environ.get("PROXY_POOL_LANG", "en")


def is_active(service):
    try:
        p = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True, timeout=2)
        return p.stdout.strip() == "active"
    except Exception:
        return False


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


def status():
    return {
        "status": "up",
        "node_name": NODE_NAME,
        "agent_time": int(time.time()),
        "uptime_s": uptime_s(),
        "load1": load1(),
        "memory": memory(),
        "telemt": is_active(TELEMT_SERVICE),
        "telemt_service": TELEMT_SERVICE,
        "language": LANG,
        "agent_version": "0.2.1",
    }


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def sendj(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def authorized(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_GET(self):
        if self.path == "/healthz":
            return self.sendj(200, {"status": "ok"})
        if self.path == "/v1/status":
            if not self.authorized():
                return self.sendj(401, {"error": "unauthorized"})
            return self.sendj(200, status())
        return self.sendj(404, {"error": "not found"})


ThreadingHTTPServer((BIND, PORT), H).serve_forever()
