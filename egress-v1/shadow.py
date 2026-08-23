#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, socket, subprocess, time, tomllib, urllib.request
from pathlib import Path

ETC=Path('/etc/mtproxyl-egress'); CONFIG=ETC/'config.toml'; NODES=ETC/'nodes.d'
TEST_IP='149.154.167.51'; TEST_PORT=443

def run(a, timeout=5):
    return subprocess.run(a,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,check=False)

def load(p):
    with p.open('rb') as f:return tomllib.load(f)

def nodes():
    out=[]
    for p in NODES.glob('*.toml'):
        n=load(p); n['_path']=str(p); out.append(n)
    return sorted(out,key=lambda n:(int(n['priority']),n['id']))

def awg(n):
    iface=n['awg_interface']; base=Path('/sys/class/net')/iface
    if not base.exists(): return {'up':False,'interface':iface,'handshake_age_sec':-1,'rx_bytes':0,'tx_bytes':0}
    now=int(time.time()); hs=run(['awg','show',iface,'latest-handshakes'])
    epochs=[]
    for ln in hs.stdout.splitlines():
        ps=ln.split()
        if ps and ps[-1].isdigit(): epochs.append(int(ps[-1]))
    latest=max(epochs,default=0); age=(now-latest if latest else -1)
    tr=run(['awg','show',iface,'transfer']); rx=tx=0
    for ln in tr.stdout.splitlines():
        ps=ln.split()
        if len(ps)>=3:
            try: rx+=int(ps[-2]); tx+=int(ps[-1])
            except: pass
    return {'up':True,'interface':iface,'handshake_age_sec':age,'rx_bytes':rx,'tx_bytes':tx}

def ping(n):
    p=run(['ping','-I',n['awg_interface'],'-c','1','-W','1',n['remote_tunnel_ip']],3)
    if p.returncode:return False,None
    import re
    m=re.search(r'time[=<]([0-9.]+)\s*ms',p.stdout)
    return True,(float(m.group(1)) if m else None)

def tcp(n):
    s=socket.socket(); s.settimeout(2.5); started=time.monotonic()
    try:
        s.bind((n['local_tunnel_ip'],0)); s.connect((TEST_IP,TEST_PORT)); return True,round((time.monotonic()-started)*1000,1)
    except OSError:return False,None
    finally:s.close()

def agent(n):
    tf=Path(n.get('agent_token_file',''))
    if not tf.is_file():return {'reachable':False,'error':'token_missing'},None
    req=urllib.request.Request(f"http://{n['remote_tunnel_ip']}:{int(n.get('agent_port',9784))}/metrics",headers={'Authorization':'Bearer '+tf.read_text().strip()})
    started=time.monotonic()
    try:
        with urllib.request.urlopen(req,timeout=2.5) as r:d=json.loads(r.read())
        return {'reachable':True,'request_ms':round((time.monotonic()-started)*1000,1),'version':d.get('version')},{k:d.get(k) for k in ('hostname','uptime_sec','cpu','memory','disk','network')}
    except Exception as e:return {'reachable':False,'error':type(e).__name__},None

def one(n,cfg):
    a=awg(n); hsok=a['up'] and 0<=a['handshake_age_sec']<=int(cfg['manager'].get('handshake_max_age',180))
    pok,rtt=ping(n) if a['up'] else (False,None); tok,tms=tcp(n) if pok else (False,None)
    ag,sys=agent(n) if a['up'] else ({'reachable':False,'error':'awg_down'},None)
    return {'id':n['id'],'name':n['name'],'enabled':bool(n.get('enabled',True)),'priority':int(n['priority']),'public_ip':n.get('public_ip',''),'awg':a,'connectivity':{'tunnel':pok,'tunnel_rtt_ms':rtt,'telegram':tok,'telegram_tcp_ms':tms},'agent':ag,'system':sys,'health':bool(n.get('enabled',True)) and hsok and pok and tok}

def current_active(reg):
    legacy=Path('/var/lib/mtproxyl-egress/active')
    old=legacy.read_text().strip().casefold() if legacy.exists() else ''
    for n in reg:
        if old in {str(n['id']).casefold(),str(n['name']).casefold(),str(n.get('migration_source','')).casefold()}:return n['id']
    return None

def collect():
    cfg=load(CONFIG); reg=nodes(); rows=[one(n,cfg) for n in reg]
    enabled=[r for r in rows if r['enabled']]
    for i,r in enumerate(enabled):r['role']='primary' if i==0 else 'backup'
    for r in rows:
        if 'role' not in r:r['role']='disabled'
    active=current_active(reg)
    return {'version':'shadow-1','timestamp':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'mode':cfg.get('mode','auto'),'active_node':active,'nodes':rows}

def human(d):
    print('MTProxyL Dynamic Egress — SHADOW');print('================================')
    print('Mode:',d['mode']);print('Active registry ID:',d.get('active_node') or '-');print()
    for n in d['nodes']:
        flags=['HEALTHY' if n['health'] else 'DOWN',n['role'].upper()]
        if n['id']==d.get('active_node'):flags.append('ACTIVE')
        print(f"{n['priority']:>3} {n['name']} [{n['id']}] {' '.join(flags)}")
        print(f"    {n['public_ip']} {n['awg']['interface']} hs={n['awg']['handshake_age_sec']}s rtt={n['connectivity']['tunnel_rtt_ms']}ms TG={'OK' if n['connectivity']['telegram'] else 'FAIL'} Agent={'OK' if n['agent']['reachable'] else 'OFF'}")

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--json',action='store_true');a=ap.parse_args();d=collect()
    if a.json:print(json.dumps(d,ensure_ascii=False,indent=2))
    else:human(d)
    raise SystemExit(0 if all(n['health'] for n in d['nodes'] if n['enabled']) else 2)
if __name__=='__main__':main()
