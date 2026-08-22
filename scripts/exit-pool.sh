#!/usr/bin/env bash
set -Eeuo pipefail

ETC=/etc/proxy-pool
SETTINGS=$ETC/settings.env
AWG_DIR=$ETC/awg-nodes
DP_DIR=$ETC/dataplane-nodes
POOL_DIR=$ETC/exit-pool
SHARED=$ETC/shared443.state
HAPROXY=/etc/haproxy/haproxy.cfg
BACKUPS=/var/lib/tyxe-pool-persistent/exit-pool

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
head1(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
yesno(){ local v=''; read -r -p "$1 [y/N]: " v </dev/tty || true; [[ $v =~ ^[yY]$ ]]; }
setting(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
safe_id(){ [[ $1 =~ ^[A-Za-z0-9_.-]{1,48}$ ]]; }
valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

preflight(){
  [[ -r $SETTINGS ]] || { red 'TYXE settings не найдены.'; return 1; }
  [[ $(setting "$SETTINGS" PROXY_POOL_ROLE) == controller ]] || { red 'Запускайте на ENTER/controller.'; return 1; }
  [[ -r $SHARED ]] || { red 'Shared-443 classifier не активен.'; return 1; }
  . "$SHARED"
  : "${FAKE_SNI:?}" "${PROXY_DOMAIN:?}"
  systemctl is-active --quiet haproxy || { red 'HAProxy не active.'; return 1; }
  haproxy -c -f "$HAPROXY" >/dev/null || { red 'HAProxy config невалиден.'; return 1; }
  grep -q '^backend tyxe_telemt$' "$HAPROXY" || { red 'backend tyxe_telemt не найден.'; return 1; }
  grep -q '^backend tyxe_https_decoy$' "$HAPROXY" || { red 'shared443 backend не найден.'; return 1; }
  install -d -m 700 "$POOL_DIR" "$BACKUPS"
}

ssh_for(){
  SSH_TARGET="root@$1"
  SSH_ARGS=(-p "$2" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ControlMaster=auto -o ControlPersist=120 -o ControlPath=/run/tyxe-exit-pool-%C)
  [[ -n ${3:-} ]] && SSH_ARGS+=(-i "$3")
}
rx(){ ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "$@"; }

load_awg(){
  local id=$1 f="$AWG_DIR/$1.state"
  safe_id "$id" || { red 'Некорректный node id.'; return 1; }
  [[ -r $f ]] || { red "AWG state не найден: $id. Сначала выполните tyxe-awg setup."; return 1; }
  . "$f"
  : "${NODE_ID:?}" "${EXIT_HOST:?}" "${EXIT_IP:?}" "${ENTER_IP:?}" "${LOCAL_IF:?}"
  SSH_PORT=${SSH_PORT:-22}; SSH_KEY=${SSH_KEY:-}
}

load_node(){
  local id=$1 f=''
  [[ -r "$POOL_DIR/$id.state" ]] && f="$POOL_DIR/$id.state"
  [[ -z $f && -r "$DP_DIR/$id.state" ]] && f="$DP_DIR/$id.state"
  [[ -n $f ]] || { red "State ноды не найден: $id"; return 1; }
  . "$f"
  : "${NODE_ID:?}" "${EXIT_HOST:?}" "${EXIT_IP:?}"
  SSH_PORT=${SSH_PORT:-22}; SSH_KEY=${SSH_KEY:-}
}

find_cfg(){
  rx "python3 - <<'PY'
from pathlib import Path
for p in (Path('/etc/telemt/telemt.toml'),Path('/etc/telemt.toml')):
    if p.is_file(): print(p); raise SystemExit
raise SystemExit(1)
PY"
}

telemt_port(){
  local cfg=$1
  rx "python3 - '$cfg' <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); text=p.read_text(encoding='utf-8',errors='replace')
try:
    import tomllib
    d=tomllib.loads(text)
    v=d.get('server',{}).get('port')
    if isinstance(v,int) and 1 <= v <= 65535:
        print(v); raise SystemExit
except Exception:
    pass
inside=False
for raw in text.splitlines():
    s=raw.strip()
    if s.startswith('[') and s.endswith(']'):
        inside=(s=='[server]'); continue
    if inside:
        m=re.match(r'port\\s*=\\s*([0-9]+)',s)
        if m and 1 <= int(m.group(1)) <= 65535:
            print(m.group(1)); raise SystemExit
raise SystemExit(2)
PY"
}

primary_id(){
  python3 - "$HAPROXY" <<'PY'
from pathlib import Path
import sys
inside=False; out=[]
for line in Path(sys.argv[1]).read_text().splitlines():
    s=line.strip()
    if s=='backend tyxe_telemt': inside=True; continue
    if inside and line and not line[0].isspace(): break
    if inside and s.startswith('server '):
        p=s.split()
        if 'backup' not in p[3:]: out.append(p[1])
if len(out)==1: print(out[0])
else: raise SystemExit(2)
PY
}

servers(){
  python3 - "$HAPROXY" <<'PY'
from pathlib import Path
import sys
inside=False
for line in Path(sys.argv[1]).read_text().splitlines():
    s=line.strip()
    if s=='backend tyxe_telemt': inside=True; continue
    if inside and line and not line[0].isspace(): break
    if inside and s.startswith('server '): print(s)
PY
}

haproxy_edit(){
  local mode=$1 id=$2 ip=${3:-} port=${4:-443} tmp old
  valid_port "$port" || { red "Некорректный backend port: $port"; return 1; }
  tmp=$(mktemp /etc/haproxy/.tyxe-pool.XXXXXX)
  old=$(mktemp /etc/haproxy/.tyxe-pool-old.XXXXXX)
  cp -a "$HAPROXY" "$old"
  python3 - "$HAPROXY" "$tmp" "$mode" "$id" "$ip" "$port" <<'PY'
from pathlib import Path
import re,sys
src,dst,mode,node,ip,port=sys.argv[1:7]
lines=Path(src).read_text().splitlines(); start=None
sections={'global','defaults','frontend','backend','listen','peers','resolvers','userlist','cache','program','mailers','ring'}
for i,l in enumerate(lines):
    if l.strip()=='backend tyxe_telemt': start=i; break
if start is None: raise SystemExit('backend missing')
end=len(lines)
for i in range(start+1,len(lines)):
    if lines[i] and not lines[i][0].isspace() and lines[i].split(None,1)[0] in sections: end=i; break
body=lines[start+1:end]; rx=re.compile(r'^\s*server\s+(\S+)\s+(\S+)(.*)$')
def tail(t,b):
    x=[v for v in t.split() if v!='backup']
    if b: x.append('backup')
    return (' '+' '.join(x)) if x else ''
if mode=='add':
    if any((m:=rx.match(l)) and m.group(1)==node for l in body): raise SystemExit('server exists')
    body.append(f'    server {node} {ip}:{port} check inter 5s rise 2 fall 3 send-proxy-v2 backup')
elif mode=='remove':
    new=[]; found=False
    for l in body:
        m=rx.match(l)
        if m and m.group(1)==node: found=True; continue
        new.append(l)
    if not found: raise SystemExit('server missing')
    body=new
else: raise SystemExit('bad mode')
items=[(i,rx.match(l)) for i,l in enumerate(body) if rx.match(l)]
if not items: raise SystemExit('refuse empty backend')
if mode=='remove' and not any('backup' not in m.group(3).split() for _,m in items):
    i,m=items[0]; n,a,t=m.groups(); body[i]=f'    server {n} {a}{tail(t,False)}'
Path(dst).write_text('\n'.join(lines[:start+1]+body+lines[end:])+'\n')
PY
  haproxy -c -f "$tmp" || { rm -f "$tmp" "$old"; return 1; }
  install -m 644 "$tmp" "$HAPROXY"; rm -f "$tmp"
  if systemctl reload haproxy && sleep 1 && systemctl is-active --quiet haproxy; then rm -f "$old"; return 0; fi
  red 'Reload HAProxy не подтвердился; восстанавливаю предыдущий config.'
  install -m 644 "$old" "$HAPROXY"; rm -f "$old"
  haproxy -c -f "$HAPROXY" >/dev/null && (systemctl reload haproxy || systemctl restart haproxy) || true
  return 1
}

clone_config(){
  local source=$1 target=$2 target_cfg=$3 target_ip=$4 target_port=$5 src_cfg tmp
  valid_port "$target_port" || { red "Некорректный Telemt backend port: $target_port"; return 1; }
  load_node "$source" || return 1
  local shost=$EXIT_HOST sport=$SSH_PORT skey=$SSH_KEY
  ssh_for "$shost" "$sport" "$skey"
  src_cfg=${TELEMT_CONFIG:-}; [[ -n $src_cfg ]] || src_cfg=$(find_cfg) || return 1
  rx "systemctl is-active --quiet telemt && ! grep -Eq '^\\s*\\[\\[server\\.listeners\\]\\]' '$src_cfg'" || { red 'Source Telemt не active или содержит [[server.listeners]].'; return 1; }
  tmp=$(mktemp /run/tyxe-telemt.XXXXXX); chmod 600 "$tmp"
  rx "cat '$src_cfg'" >"$tmp" || { rm -f "$tmp"; return 1; }

  load_awg "$target" || { rm -f "$tmp"; return 1; }
  ssh_for "$EXIT_HOST" "$SSH_PORT" "$SSH_KEY"
  ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "umask 077; cat > /run/tyxe-telemt-pool.toml" <"$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  rx "install -m 600 /run/tyxe-telemt-pool.toml '$target_cfg'; rm -f /run/tyxe-telemt-pool.toml"
  ssh "${SSH_ARGS[@]}" "$SSH_TARGET" 'bash -s' <<EOF
set -Eeuo pipefail
python3 - '$target_cfg' '$target_ip' '$target_port' '$PROXY_DOMAIN' <<'PY'
from pathlib import Path
import json,re,sys
p=Path(sys.argv[1]); ip=sys.argv[2]; port=sys.argv[3]; host=sys.argv[4]; lines=p.read_text().splitlines()
def patch(sec,vals):
    global lines
    h=f'[{sec}]'; s=next((i for i,l in enumerate(lines) if l.strip()==h),None)
    if s is None:
        if lines and lines[-1].strip(): lines.append('')
        lines += [h]+[f'{k} = {v}' for k,v in vals.items()]; return
    e=next((i for i in range(s+1,len(lines)) if lines[i].strip().startswith('[') and lines[i].strip().endswith(']')),len(lines))
    for k,v in vals.items():
        r=re.compile(r'^\\s*'+re.escape(k)+r'\\s*='); hits=[i for i in range(s+1,e) if r.match(lines[i])]
        if hits:
            lines[hits[0]]=f'{k} = {v}'
            for i in reversed(hits[1:]): del lines[i]; e-=1
        else: lines.insert(e,f'{k} = {v}'); e+=1
patch('server',{'port':port,'listen_addr_ipv4':json.dumps(ip),'proxy_protocol':'true'})
patch('general.links',{'public_host':json.dumps(host),'public_port':'443'})
p.write_text('\\n'.join(lines)+'\\n')
PY
systemctl restart telemt
sleep 2
systemctl is-active --quiet telemt
ss -ltnpH 'sport = :$target_port' | grep -F '$target_ip:$target_port' >/dev/null
EOF
}

add(){
  preflight || return 1
  local id=${1:-} source=${2:-}
  [[ -n $id ]] || { red 'Usage: tyxe-exit-pool add <new-node-id> [source-node-id]'; return 2; }
  [[ ! -e "$POOL_DIR/$id.state" && ! -e "$DP_DIR/$id.state" ]] || { red 'Нода уже участвует в dataplane/pool.'; return 1; }
  load_awg "$id" || return 1
  local thost=$EXIT_HOST tip=$EXIT_IP teip=$ENTER_IP tif=$LOCAL_IF ssh_port=$SSH_PORT tkey=$SSH_KEY
  [[ -e /sys/class/net/$tif ]] || { red "AWG interface $tif не поднят."; return 1; }
  ping -c 2 -W 2 "$tip" >/dev/null || { red "AWG target $tip недоступен."; return 1; }
  ssh_for "$thost" "$ssh_port" "$tkey"
  rx 'command -v telemt >/dev/null' || { red 'На target нет Telemt. Сначала установите TYXE EXIT/Telemt.'; return 1; }
  local tcfg backend_port; tcfg=$(find_cfg) || { red 'Telemt config target не найден.'; return 1; }
  backend_port=$(telemt_port "$tcfg") || { red 'Не удалось определить текущий Telemt port target.'; return 1; }
  valid_port "$backend_port" || { red "Некорректный Telemt port target: $backend_port"; return 1; }
  source=${source:-$(primary_id || true)}; [[ -n $source && $source != "$id" ]] || { red 'Не удалось определить source primary.'; return 1; }
  local ts rdir original
  ts=$(date +%Y%m%d-%H%M%S)
  rdir="/var/lib/tyxe-pool-persistent/exit-pool-backups/$id"
  original="$rdir/telemt.before-pool.$ts"
  rx "install -d -m 700 '$rdir'; cp -a '$tcfg' '$original'"
  install -d -m 700 "$BACKUPS/$id/$ts"; cp -a "$HAPROXY" "$BACKUPS/$id/$ts/haproxy.before-add"
  head1 "Add hot-backup: $id"
  echo "Source: $source"; echo "AWG: $teip -> $tip ($tif)"; echo "Telemt backend: $tip:$backend_port"
  yellow 'Telemt users/secrets будут клонированы с source; shared443 frontend не перезаписывается.'
  yesno "Добавить $id как HAProxy backup?" || return 0
  if ! clone_config "$source" "$id" "$tcfg" "$tip" "$backend_port"; then ssh_for "$thost" "$ssh_port" "$tkey"; rx "install -m 600 '$original' '$tcfg'; systemctl restart telemt" || true; return 1; fi
  timeout 5 bash -c "</dev/tcp/$tip/$backend_port" || { red "Target TCP/$backend_port недоступен; восстанавливаю target Telemt."; ssh_for "$thost" "$ssh_port" "$tkey"; rx "install -m 600 '$original' '$tcfg'; systemctl restart telemt" || true; return 1; }
  haproxy_edit add "$id" "$tip" "$backend_port" || { ssh_for "$thost" "$ssh_port" "$tkey"; rx "install -m 600 '$original' '$tcfg'; systemctl restart telemt" || true; return 1; }
  umask 077
  {
    printf 'NODE_ID=%q\n' "$id"; printf 'EXIT_HOST=%q\n' "$thost"; printf 'EXIT_IP=%q\n' "$tip"; printf 'ENTER_IP=%q\n' "$teip"; printf 'LOCAL_IF=%q\n' "$tif"
    printf 'SSH_PORT=%q\n' "$ssh_port"; printf 'SSH_KEY=%q\n' "$tkey"; printf 'TELEMT_CONFIG=%q\n' "$tcfg"; printf 'TELEMT_PORT=%q\n' "$backend_port"; printf 'ORIGINAL_TELEMT_BACKUP=%q\n' "$original"; printf 'SOURCE_NODE_ID=%q\n' "$source"
  } >"$POOL_DIR/$id.state"; chmod 600 "$POOL_DIR/$id.state"
  servers
  green "$id добавлен как hot-backup; текущий primary не изменён."
}

sync_node(){
  preflight || return 1
  local id=${1:-} source=${2:-}
  [[ -r "$POOL_DIR/$id.state" ]] || { red 'Target pool state не найден.'; return 1; }
  . "$POOL_DIR/$id.state"
  local thost=$EXIT_HOST tip=$EXIT_IP ssh_port=${SSH_PORT:-22} tkey=${SSH_KEY:-} tcfg=$TELEMT_CONFIG backend_port=${TELEMT_PORT:-}
  source=${source:-$(primary_id || true)}; [[ -n $source && $source != "$id" ]] || { red 'Укажите отдельную source-ноду.'; return 1; }
  ssh_for "$thost" "$ssh_port" "$tkey"
  [[ -n $backend_port ]] || backend_port=$(telemt_port "$tcfg") || { red 'Не удалось определить Telemt port target.'; return 1; }
  valid_port "$backend_port" || { red "Некорректный Telemt port target: $backend_port"; return 1; }
  local bak="/var/lib/tyxe-pool-persistent/exit-pool-backups/$id/telemt.before-sync.$(date +%Y%m%d-%H%M%S)"; rx "cp -a '$tcfg' '$bak'"
  yesno "Синхронизировать users/secrets $source -> $id?" || return 0
  clone_config "$source" "$id" "$tcfg" "$tip" "$backend_port" || { ssh_for "$thost" "$ssh_port" "$tkey"; rx "install -m 600 '$bak' '$tcfg'; systemctl restart telemt" || true; return 1; }
  green "Sync $source -> $id: OK"
}

rollback(){
  preflight || return 1
  local id=${1:-}; [[ -r "$POOL_DIR/$id.state" ]] || { red 'Pool state не найден.'; return 1; }
  . "$POOL_DIR/$id.state"
  local host=$EXIT_HOST port=${SSH_PORT:-22} key=${SSH_KEY:-} cfg=$TELEMT_CONFIG original=$ORIGINAL_TELEMT_BACKUP
  yellow 'Rollback удалит только эту backup-ноду из HAProxy и восстановит её исходный Telemt config. AWG/shared443/primary не меняются.'
  yesno "Откатить $id?" || return 0
  haproxy_edit remove "$id" || return 1
  ssh_for "$host" "$port" "$key"; rx "install -m 600 '$original' '$cfg'; systemctl restart telemt" || { red 'Нода уже исключена из HAProxy, но восстановление Telemt target требует ручной проверки.'; return 1; }
  rm -f "$POOL_DIR/$id.state"; green "$id удалён из pool."
}

status(){
  preflight || return 1
  head1 'TYXE multi-EXIT pool'
  printf 'FakeTLS: %s\nPublic:  %s:443\n\n' "$FAKE_SNI" "$PROXY_DOMAIN"
  local line id addr ip port role
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    id=$(awk '{print $2}' <<<"$line"); addr=$(awk '{print $3}' <<<"$line"); ip=${addr%:*}; port=${addr##*:}; role=PRIMARY; grep -qw backup <<<"$line" && role=BACKUP
    printf '%-18s %-8s %-22s TCP=' "$id" "$role" "$addr"
    timeout 3 bash -c "</dev/tcp/$ip/$port" 2>/dev/null && echo OPEN || echo DOWN
  done < <(servers)
}

case "${1:-status}" in
  add) shift; add "${1:-}" "${2:-}";;
  sync) shift; sync_node "${1:-}" "${2:-}";;
  rollback|remove) shift; rollback "${1:-}";;
  status) status;;
  *) echo 'Usage: tyxe-exit-pool [status|add <node> [source]|sync <node> [source]|rollback <node>]' >&2; exit 2;;
esac
