#!/usr/bin/env python3
import json, os, socket, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND=os.environ.get('PROXY_POOL_AGENT_BIND','127.0.0.1')
PORT=int(os.environ.get('PROXY_POOL_AGENT_PORT','9100'))
TELEMT_SERVICE=os.environ.get('PROXY_POOL_TELEMT_SERVICE','telemt')

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): return
    def sendj(self, code, obj):
        b=json.dumps(obj, ensure_ascii=False).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path=='/healthz': return self.sendj(200,{'status':'ok'})
        if self.path=='/v1/status':
            return self.sendj(200, status())
        return self.sendj(404, {'error':'not found'})

def status():
    try:
        p=subprocess.run(['systemctl','is-active',TELEMT_SERVICE],capture_output=True,text=True,timeout=2)
        telemt=p.stdout.strip()=='active'
    except Exception:
        telemt=False
    return {'status':'up','agent_time':int(time.time()),'telemt':telemt,'telemt_service':TELEMT_SERVICE}

ThreadingHTTPServer((BIND,PORT),H).serve_forever()
