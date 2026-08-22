#!/usr/bin/env bash
set -Eeuo pipefail

ETC=/etc/proxy-pool
AWG_DIR=/etc/amnezia/amneziawg
NODES_DIR=$ETC/awg-nodes
BACKUP_ROOT=/var/lib/proxy-pool/awg-nodes
REMOTE_IF=awg0
REMOTE_SERVICE=awg-quick@awg0
DROPIN=/etc/systemd/system/proxy-pool-agent.service.d/10-tyxe-awg.conf
DEFAULT_POOLS="10.10.10.0/24,10.254.0.0/16,172.31.240.0/20,192.168.250.0/24"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
cyan(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
read_tty(){ local __name="$1" __prompt="$2" __value=''; read -r -p "$__prompt" __value </dev/tty || true; printf -v "$__name" '%s' "$__value"; }
ask(){ local n="$1" p="$2" d="$3" v=''; read_tty v "$p [$d]: "; printf -v "$n" '%s' "${v:-$d}"; }
yesno(){ local p="$1" v=''; read_tty v "$p [y/N]: "; [[ "$v" =~ ^[yY]$ ]]; }
getenv(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_ipv4(){ python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1])
except Exception: raise SystemExit(1)
PY
}
safe_id(){ python3 - "$1" <<'PY'
import re,sys
s=re.sub(r'[^A-Za-z0-9_.-]+','-',sys.argv[1].strip()).strip('-._')
print((s or 'exit')[:48])
PY
}

[[ $EUID -eq 0 ]] || { red 'Запустите через sudo/root.'; exit 1; }

require_enter(){
  [[ -r $ETC/settings.env ]] || { red 'TYXE Controller не найден.'; exit 1; }
  [[ "$(getenv "$ETC/settings.env" PROXY_POOL_ROLE)" == controller ]] || { red 'tyxe-awg нужно запускать на ENTER/controller.'; exit 1; }
  install -d -m 700 "$NODES_DIR" "$BACKUP_ROOT"
}

ssh_build(){
  SSH=(-p "$SSH_PORT" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  [[ -n ${SSH_KEY:-} ]] && SSH+=(-i "$SSH_KEY")
  TARGET="root@$EXIT_HOST"
}
rx(){ ssh "${SSH[@]}" "$TARGET" "$@"; }
rscript(){ ssh "${SSH[@]}" "$TARGET" 'bash -s'; }

install_awg_local(){
  command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1 && modprobe amneziawg >/dev/null 2>&1 && return
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || { red 'AWG beta сейчас рассчитан на Ubuntu 22.04/24.04.'; return 1; }
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)" openssh-client iputils-ping curl iproute2
  grep -Rqs 'ppa.launchpadcontent.net/amnezia/ppa' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || add-apt-repository -y ppa:amnezia/ppa
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg
  modprobe amneziawg
  command -v awg >/dev/null && command -v awg-quick >/dev/null
}

install_awg_remote(){
  rscript <<'REMOTE'
set -Eeuo pipefail
if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1 && modprobe amneziawg >/dev/null 2>&1; then exit 0; fi
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || { echo 'TYXE: EXIT должен быть Ubuntu 22.04/24.04 для текущего AWG beta.' >&2; exit 1; }
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)" iproute2
grep -Rqs 'ppa.launchpadcontent.net/amnezia/ppa' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || add-apt-repository -y ppa:amnezia/ppa
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg
modprobe amneziawg
command -v awg >/dev/null && command -v awg-quick >/dev/null
REMOTE
}

network_snapshot_local(){
  python3 - "$NODES_DIR" <<'PY'
import glob,ipaddress,json,pathlib,re,subprocess,sys
state_dir=pathlib.Path(sys.argv[1])
nets=set()
def add(v):
    try:
        n=ipaddress.ip_network(v, strict=False)
        if n.version==4: nets.add(str(n))
    except Exception: pass
try:
    data=json.loads(subprocess.check_output(['ip','-j','addr','show'],text=True))
    for it in data:
        for a in it.get('addr_info',[]):
            if a.get('family')=='inet': add(f"{a.get('local')}/{a.get('prefixlen')}")
except Exception: pass
try:
    data=json.loads(subprocess.check_output(['ip','-j','route','show','table','all'],text=True))
    for r in data:
        d=r.get('dst')
        if d and d!='default': add(d)
except Exception: pass
for pat in ('/etc/amnezia/amneziawg/*.conf','/etc/wireguard/*.conf'):
    for fn in glob.glob(pat):
        try: text=pathlib.Path(fn).read_text(errors='ignore')
        except Exception: continue
        for m in re.finditer(r'(?im)^\s*Address\s*=\s*([^\n#]+)',text):
            for v in m.group(1).split(','): add(v.strip())
for fn in state_dir.glob('*.state'):
    try: text=fn.read_text(errors='ignore')
    except Exception: continue
    m=re.search(r'(?m)^NETWORK_CIDR=(.+)$',text)
    if m: add(m.group(1).strip().strip("'\""))
print('\n'.join(sorted(nets)))
PY
}

network_snapshot_remote(){
  rscript <<'REMOTE'
python3 - <<'PY'
import glob,ipaddress,json,pathlib,re,subprocess
nets=set()
def add(v):
    try:
        n=ipaddress.ip_network(v, strict=False)
        if n.version==4: nets.add(str(n))
    except Exception: pass
try:
    data=json.loads(subprocess.check_output(['ip','-j','addr','show'],text=True))
    for it in data:
        for a in it.get('addr_info',[]):
            if a.get('family')=='inet': add(f"{a.get('local')}/{a.get('prefixlen')}")
except Exception: pass
try:
    data=json.loads(subprocess.check_output(['ip','-j','route','show','table','all'],text=True))
    for r in data:
        d=r.get('dst')
        if d and d!='default': add(d)
except Exception: pass
for pat in ('/etc/amnezia/amneziawg/*.conf','/etc/wireguard/*.conf'):
    for fn in glob.glob(pat):
        try: text=pathlib.Path(fn).read_text(errors='ignore')
        except Exception: continue
        for m in re.finditer(r'(?im)^\s*Address\s*=\s*([^\n#]+)',text):
            for v in m.group(1).split(','): add(v.strip())
print('\n'.join(sorted(nets)))
PY
REMOTE
}

select_local_interface(){
  local i name
  for i in $(seq 0 63); do
    name="awg$i"
    [[ -e "/sys/class/net/$name" ]] && continue
    [[ -e "$AWG_DIR/$name.conf" ]] && continue
    grep -Rqs "^LOCAL_IF=$name$" "$NODES_DIR"/*.state 2>/dev/null && continue
    LOCAL_IF="$name"; LOCAL_SERVICE="awg-quick@$name"; LOCAL_CONF="$AWG_DIR/$name.conf"; return 0
  done
  red 'Нет свободного имени awg0..awg63 на ENTER.'
  return 1
}

allocate_network(){
  local local_file remote_file pools allocated
  local_file=$(mktemp); remote_file=$(mktemp)
  network_snapshot_local >"$local_file"
  network_snapshot_remote >"$remote_file"
  pools="${TYXE_AWG_POOLS:-$DEFAULT_POOLS}"
  allocated=$(python3 - "$local_file" "$remote_file" "$pools" <<'PY'
import ipaddress,sys
def readnets(path):
    out=[]
    for s in open(path,encoding='utf-8',errors='ignore'):
        s=s.strip()
        if not s: continue
        try: out.append(ipaddress.ip_network(s,strict=False))
        except Exception: pass
    return out
occupied=readnets(sys.argv[1])+readnets(sys.argv[2])
pools=[x.strip() for x in sys.argv[3].split(',') if x.strip()]
for p in pools:
    try: pool=ipaddress.ip_network(p,strict=False)
    except Exception: continue
    if pool.version!=4 or pool.prefixlen>30: continue
    for cand in pool.subnets(new_prefix=30):
        if any(cand.overlaps(o) for o in occupied): continue
        hosts=list(cand.hosts())
        print(cand,hosts[0],hosts[1])
        raise SystemExit
raise SystemExit(2)
PY
  ) || {
    rm -f "$local_file" "$remote_file"
    red "Не найден свободный /30 в пулах: $pools"
    red 'Задайте, например: TYXE_AWG_POOLS=10.200.0.0/16 sudo -E tyxe-awg setup'
    return 1
  }
  rm -f "$local_file" "$remote_file"
  read -r NETWORK_CIDR EXIT_IP ENTER_IP <<<"$allocated"
}

save_state(){
  umask 077
  {
    printf 'NODE_ID=%q\n' "$NODE_ID"
    printf 'NODE_NAME=%q\n' "$NODE_NAME"
    printf 'EXIT_HOST=%q\n' "$EXIT_HOST"
    printf 'SSH_PORT=%q\n' "$SSH_PORT"
    printf 'SSH_KEY=%q\n' "$SSH_KEY"
    printf 'AWG_PORT=%q\n' "$AWG_PORT"
    printf 'NETWORK_CIDR=%q\n' "$NETWORK_CIDR"
    printf 'ENTER_IP=%q\n' "$ENTER_IP"
    printf 'EXIT_IP=%q\n' "$EXIT_IP"
    printf 'LOCAL_IF=%q\n' "$LOCAL_IF"
    printf 'LOCAL_SERVICE=%q\n' "$LOCAL_SERVICE"
    printf 'LOCAL_CONF=%q\n' "$LOCAL_CONF"
    printf 'AGENT_PORT=%q\n' "$AGENT_PORT"
    printf 'ENTER_PUBLIC_IP=%q\n' "$ENTER_PUBLIC_IP"
    printf 'LOCAL_BACKUP=%q\n' "$LOCAL_BACKUP"
    printf 'REMOTE_BACKUP=%q\n' "$REMOTE_BACKUP"
    printf 'REMOTE_SETTINGS_BACKUP=%q\n' "$REMOTE_SETTINGS_BACKUP"
    printf 'REMOTE_DROPIN_BACKUP=%q\n' "$REMOTE_DROPIN_BACKUP"
    printf 'LOCAL_WAS_ACTIVE=%q\n' "$LOCAL_WAS_ACTIVE"
    printf 'REMOTE_WAS_ACTIVE=%q\n' "$REMOTE_WAS_ACTIVE"
    printf 'UFW_ADDED=%q\n' "$UFW_ADDED"
  } > "$STATE"
  chmod 600 "$STATE"
}

choose_state(){
  local requested="${1:-}" count
  if [[ -n "$requested" ]]; then
    STATE="$NODES_DIR/$requested.state"
    [[ -r "$STATE" ]] || { red "AWG node state не найден: $requested"; return 1; }
    return
  fi
  mapfile -t states < <(find "$NODES_DIR" -maxdepth 1 -type f -name '*.state' -printf '%f\n' 2>/dev/null | sort)
  count=${#states[@]}
  (( count > 0 )) || { red 'AWG node state не найден.'; return 1; }
  if (( count == 1 )); then STATE="$NODES_DIR/${states[0]}"; return; fi
  printf 'Настроенные AWG-ноды:\n'; printf '  %s\n' "${states[@]%.state}"
  red 'Укажите node id: tyxe-awg status <id> или tyxe-awg rollback <id>'
  return 1
}

load_state(){
  choose_state "${1:-}" || return 1
  . "$STATE"
  AGENT_PORT=${AGENT_PORT:-9100}
  LOCAL_SERVICE=${LOCAL_SERVICE:-awg-quick@${LOCAL_IF:-awg0}}
  LOCAL_CONF=${LOCAL_CONF:-$AWG_DIR/${LOCAL_IF:-awg0}.conf}
  ssh_build
}

backup_all(){
  NODE_BACKUP_DIR="$BACKUP_ROOT/$NODE_ID"
  install -d -m 700 "$NODE_BACKUP_DIR"
  TS=$(date +%s)
  LOCAL_WAS_ACTIVE=$(systemctl is-active "$LOCAL_SERVICE" 2>/dev/null || true)
  REMOTE_WAS_ACTIVE=$(rx "systemctl is-active '$REMOTE_SERVICE' 2>/dev/null || true")
  LOCAL_BACKUP="$NODE_BACKUP_DIR/${LOCAL_IF}.local.$TS"
  [[ -f $LOCAL_CONF ]] && cp -a "$LOCAL_CONF" "$LOCAL_BACKUP" || : > "$LOCAL_BACKUP.absent"
  REMOTE_BACKUP="/var/lib/proxy-pool/awg-nodes/$NODE_ID/awg0.remote.$TS"
  REMOTE_SETTINGS_BACKUP="/var/lib/proxy-pool/awg-nodes/$NODE_ID/settings.$TS"
  REMOTE_DROPIN_BACKUP="/var/lib/proxy-pool/awg-nodes/$NODE_ID/dropin.$TS"
  rscript <<REMOTE
set -Eeuo pipefail
mkdir -p '/var/lib/proxy-pool/awg-nodes/$NODE_ID'
chmod 700 '/var/lib/proxy-pool/awg-nodes/$NODE_ID'
[[ -f '$AWG_DIR/$REMOTE_IF.conf' ]] && cp -a '$AWG_DIR/$REMOTE_IF.conf' '$REMOTE_BACKUP' || : > '$REMOTE_BACKUP.absent'
[[ -f '$ETC/settings.env' ]] && cp -a '$ETC/settings.env' '$REMOTE_SETTINGS_BACKUP' || : > '$REMOTE_SETTINGS_BACKUP.absent'
[[ -f '$DROPIN' ]] && cp -a '$DROPIN' '$REMOTE_DROPIN_BACKUP' || : > '$REMOTE_DROPIN_BACKUP.absent'
REMOTE
}

gen_configs(){
  read -r JC JMIN JMAX S1 S2 S3 H1 H2 H3 H4 < <(python3 - <<'PY'
import random
jc=random.randint(4,10); jmin=random.randint(8,40); jmax=random.randint(max(60,jmin+20),120)
s1=random.randint(15,120)
while True:
    s2=random.randint(15,120)
    if s1+56 != s2: break
s3=random.randint(0,48)
h=random.sample(range(100000,2100000000),4)
print(jc,jmin,jmax,s1,s2,s3,*h)
PY
)
  EPRIV=$(awg genkey); EPUB=$(printf %s "$EPRIV" | awg pubkey)
  XPRIV=$(awg genkey); XPUB=$(printf %s "$XPRIV" | awg pubkey)
  PSK=$(awg genpsk)
  install -d -m 700 "$AWG_DIR"; umask 077
  cat > "$LOCAL_CONF" <<EOF
[Interface]
Address = $ENTER_IP/30
PrivateKey = $EPRIV
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = 0
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $XPUB
PresharedKey = $PSK
Endpoint = $EXIT_HOST:$AWG_PORT
AllowedIPs = $EXIT_IP/32
PersistentKeepalive = 25
EOF
  chmod 600 "$LOCAL_CONF"
  rscript <<EOF
set -Eeuo pipefail
install -d -m 700 '$AWG_DIR'
cat > '$AWG_DIR/$REMOTE_IF.conf' <<'CFG'
[Interface]
Address = $EXIT_IP/30
ListenPort = $AWG_PORT
PrivateKey = $XPRIV
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = 0
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $EPUB
PresharedKey = $PSK
AllowedIPs = $ENTER_IP/32
CFG
chmod 600 '$AWG_DIR/$REMOTE_IF.conf'
EOF
  unset EPRIV XPRIV PSK
}

remote_setting(){
  local key="$1"
  rx "python3 - '$key'" <<'PY'
from pathlib import Path
import sys
key=sys.argv[1]+'='; p=Path('/etc/proxy-pool/settings.env')
for line in p.read_bytes().decode('utf-8',errors='ignore').splitlines():
    if line.startswith(key):
        print(line.split('=',1)[1].strip().strip('"').strip("'")); break
PY
}

move_agent(){
  rscript <<EOF
set -Eeuo pipefail
python3 - '$ETC/settings.env' '$EXIT_IP' <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); ip=sys.argv[2]
text=p.read_bytes().decode('utf-8',errors='ignore'); out=[]; seen=False
for line in text.splitlines():
    if line.startswith('PROXY_POOL_AGENT_BIND='):
        out.append('PROXY_POOL_AGENT_BIND='+ip); seen=True
    else: out.append(line)
if not seen: out.append('PROXY_POOL_AGENT_BIND='+ip)
p.write_text('\n'.join(out)+'\n',encoding='utf-8')
PY
install -d -m 755 /etc/systemd/system/proxy-pool-agent.service.d
cat > '$DROPIN' <<'UNIT'
[Unit]
Requires=$REMOTE_SERVICE
After=$REMOTE_SERVICE

[Service]
ExecStartPost=
ExecStartPost=/usr/bin/timeout 10 /bin/sh -c 'until /usr/bin/curl -fsS "http://$EXIT_IP:$AGENT_PORT/healthz" >/dev/null 2>&1; do sleep 0.25; done'
UNIT
systemctl daemon-reload
systemd-analyze verify proxy-pool-agent.service >/dev/null
systemctl restart proxy-pool-agent
EOF
}

register_node(){
  local lt cp count name payload
  lt=$(getenv "$ETC/settings.env" PROXY_POOL_LOCAL_API_TOKEN)
  cp=$(getenv "$ETC/settings.env" PROXY_POOL_PORT); cp=${cp:-9101}
  [[ -n $lt && -n ${TOKEN:-} ]] || return 0
  count=$(curl -fsS -H "Authorization: Bearer $lt" "http://127.0.0.1:$cp/api/nodes" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("nodes",[])))')
  [[ $count == 0 ]] || { yellow 'Controller уже содержит EXIT; текущий stabilization guard пока не разрешает автодобавить вторую ноду.'; return 0; }
  name=$(curl -fsS -H "Authorization: Bearer $TOKEN" "http://$EXIT_IP:$AGENT_PORT/v1/status" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("node_name","PL EXIT"))')
  payload=$(python3 - "$name" "$EXIT_IP" "$AGENT_PORT" "$TOKEN" <<'PY'
import json,sys
print(json.dumps({"name":sys.argv[1],"address":sys.argv[2],"agent_port":int(sys.argv[3]),"token":sys.argv[4]}))
PY
)
  curl -fsS -H "Authorization: Bearer $lt" -H 'Content-Type: application/json' -d "$payload" "http://127.0.0.1:$cp/api/nodes" >/dev/null
}

setup(){
  require_enter
  exec 9>"$ETC/awg-allocator.lock"
  if command -v flock >/dev/null 2>&1; then flock -x 9; else yellow 'flock не найден; параллельный запуск tyxe-awg setup не поддерживается.'; fi
  cyan 'TYXE AWG ENTER ↔ EXIT'
  ask EXIT_HOST 'Публичный IPv4/hostname EXIT' ''
  [[ -n $EXIT_HOST && $EXIT_HOST =~ ^[A-Za-z0-9._-]+$ ]] || { red 'Некорректный EXIT host.'; exit 1; }
  ask SSH_PORT 'SSH-порт EXIT' 22; valid_port "$SSH_PORT" || { red 'Некорректный SSH-порт.'; exit 1; }
  ask SSH_KEY 'SSH private key (пусто = password/ssh-agent)' ''
  [[ -z $SSH_KEY || -r $SSH_KEY ]] || { red 'SSH key не читается.'; exit 1; }
  ask AWG_PORT 'UDP-порт AWG на EXIT' 8443; valid_port "$AWG_PORT" || { red 'Некорректный AWG-порт.'; exit 1; }
  ssh_build
  cyan 'SSH'
  rx 'id -u' | grep -qx 0 || { red 'Для beta нужен root SSH на EXIT.'; exit 1; }
  ENTER_PUBLIC_IP=$(rx "printf '%s\n' \"\$SSH_CLIENT\" | awk '{print \$1}'")
  valid_ipv4 "$ENTER_PUBLIC_IP" || { red 'EXIT не смог определить публичный IPv4 ENTER.'; exit 1; }
  green "EXIT видит ENTER как $ENTER_PUBLIC_IP"
  rx "test -f '$ETC/settings.env' && grep -q '^PROXY_POOL_ROLE=agent' '$ETC/settings.env'" || { red 'На EXIT не обнаружен TYXE Agent.'; exit 1; }
  NODE_NAME=$(remote_setting PROXY_POOL_NODE_NAME || true); NODE_NAME=${NODE_NAME:-PL-EXIT}
  BASE_NODE_ID=$(safe_id "$NODE_NAME")
  if grep -Rqs "^EXIT_HOST=$(printf '%q' "$EXIT_HOST")$" "$NODES_DIR"/*.state 2>/dev/null; then red "EXIT $EXIT_HOST уже имеет AWG-state на этом ENTER."; exit 1; fi
  NODE_ID="$BASE_NODE_ID"
  if [[ -e "$NODES_DIR/$NODE_ID.state" ]]; then suffix=$(printf '%s' "$EXIT_HOST" | sha256sum | cut -c1-8); NODE_ID="${BASE_NODE_ID}-${suffix}"; fi
  if rx "test -e '$AWG_DIR/$REMOTE_IF.conf' || ip link show '$REMOTE_IF' >/dev/null 2>&1"; then red "На EXIT уже существует $REMOTE_IF или его конфиг. TYXE не будет перезаписывать существующий туннель."; exit 1; fi
  AGENT_PORT=$(remote_setting PROXY_POOL_AGENT_PORT || true); AGENT_PORT=${AGENT_PORT:-9100}; valid_port "$AGENT_PORT" || { red 'Некорректный порт EXIT Agent.'; exit 1; }

  cyan 'Адресация'
  select_local_interface
  allocate_network
  green "Выделено: $NETWORK_CIDR  EXIT=$EXIT_IP  ENTER=$ENTER_IP  ENTER-if=$LOCAL_IF"

  cyan 'AmneziaWG'; install_awg_local; install_awg_remote
  STATE="$NODES_DIR/$NODE_ID.state"; LOCAL_SERVICE="awg-quick@$LOCAL_IF"; LOCAL_CONF="$AWG_DIR/$LOCAL_IF.conf"
  cyan 'Backup'; backup_all; UFW_ADDED=0; save_state
  systemctl stop "$LOCAL_SERVICE" 2>/dev/null || true; rx "systemctl stop '$REMOTE_SERVICE' 2>/dev/null || true"; gen_configs
  if rx "command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'"; then
    if ! rx "ufw status | grep -Fq '$AWG_PORT/udp'"; then rx "ufw allow from '$ENTER_PUBLIC_IP' to any port '$AWG_PORT' proto udp"; UFW_ADDED=1; else yellow "На EXIT уже есть UFW-правило для $AWG_PORT/udp; TYXE не изменяет пользовательское правило."; fi
  fi
  save_state
  cyan 'Start'; rx "systemctl enable '$REMOTE_SERVICE' >/dev/null 2>&1 || true; systemctl restart '$REMOTE_SERVICE'"; systemctl enable "$LOCAL_SERVICE" >/dev/null 2>&1 || true; systemctl restart "$LOCAL_SERVICE"
  cyan 'Agent'; TOKEN=$(remote_setting PROXY_POOL_AGENT_TOKEN || true); move_agent
  cyan 'Проверка'
  ping -c 3 -W 2 "$EXIT_IP" >/dev/null || { red "Нет ping до $EXIT_IP. Для отката: sudo tyxe-awg rollback $NODE_ID"; exit 1; }
  green "ping $EXIT_IP: OK"
  if [[ -n ${TOKEN:-} ]]; then curl -fsS -H "Authorization: Bearer $TOKEN" "http://$EXIT_IP:$AGENT_PORT/v1/status" | python3 -m json.tool || { red "Agent через AWG недоступен. Для отката: sudo tyxe-awg rollback $NODE_ID"; exit 1; }; register_node; else yellow 'Agent token на EXIT не найден; туннель поднят, но Agent API не проверен.'; fi
  green "AWG pair готов: $NODE_ID / $NETWORK_CIDR / $LOCAL_IF"
  echo 'Следующий этап: Telemt proxy_protocol/bind + HAProxy.'
}

status(){
  require_enter; load_state "${1:-}" || exit 1
  cyan "AWG status: $NODE_ID"
  printf 'Network: %s\nENTER: %s (%s)\nEXIT:  %s\n' "$NETWORK_CIDR" "$ENTER_IP" "$LOCAL_IF" "$EXIT_IP"
  systemctl status "$LOCAL_SERVICE" --no-pager -l || true; awg show "$LOCAL_IF" || true; ping -c 2 -W 2 "$EXIT_IP" || true
  if [[ -n ${AGENT_PORT:-} ]]; then curl -fsS "http://$EXIT_IP:$AGENT_PORT/healthz" || true; echo; fi
  rx "systemctl status '$REMOTE_SERVICE' --no-pager -l" || true
}

list_pairs(){
  require_enter
  printf '%-18s %-8s %-18s %-16s %-16s %s\n' NODE INTERFACE NETWORK ENTER EXIT PUBLIC_EXIT
  local f; shopt -s nullglob
  for f in "$NODES_DIR"/*.state; do ( . "$f"; printf '%-18s %-8s %-18s %-16s %-16s %s\n' "${NODE_ID:-?}" "${LOCAL_IF:-?}" "${NETWORK_CIDR:-?}" "${ENTER_IP:-?}" "${EXIT_IP:-?}" "${EXIT_HOST:-?}" ); done
}

rollback(){
  require_enter; load_state "${1:-}" || exit 1
  yesno "Откатить AWG pair $NODE_ID ($NETWORK_CIDR)?" || exit 0
  systemctl disable --now "$LOCAL_SERVICE" 2>/dev/null || true; rx "systemctl disable --now '$REMOTE_SERVICE' 2>/dev/null || true" || true
  [[ -f $LOCAL_BACKUP ]] && install -Dm 600 "$LOCAL_BACKUP" "$LOCAL_CONF" || rm -f "$LOCAL_CONF"
  rscript <<EOF
set -Eeuo pipefail
[[ -f '$REMOTE_BACKUP' ]] && install -Dm 600 '$REMOTE_BACKUP' '$AWG_DIR/$REMOTE_IF.conf' || rm -f '$AWG_DIR/$REMOTE_IF.conf'
[[ -f '$REMOTE_SETTINGS_BACKUP' ]] && install -Dm 600 '$REMOTE_SETTINGS_BACKUP' '$ETC/settings.env' || true
[[ -f '$REMOTE_DROPIN_BACKUP' ]] && install -Dm 644 '$REMOTE_DROPIN_BACKUP' '$DROPIN' || rm -f '$DROPIN'
systemctl daemon-reload
systemctl restart proxy-pool-agent 2>/dev/null || true
EOF
  [[ ${LOCAL_WAS_ACTIVE:-inactive} == active ]] && systemctl start "$LOCAL_SERVICE" || true
  [[ ${REMOTE_WAS_ACTIVE:-inactive} == active ]] && rx "systemctl start '$REMOTE_SERVICE'" || true
  [[ ${UFW_ADDED:-0} == 1 ]] && rx "ufw --force delete allow from '$ENTER_PUBLIC_IP' to any port '$AWG_PORT' proto udp" || true
  rm -f "$STATE"; green "AWG pair $NODE_ID откатан. Остальные пары не затронуты."
}

case "${1:-setup}" in
  setup|install) setup;;
  list) list_pairs;;
  status) shift; status "${1:-}";;
  rollback|uninstall) shift; rollback "${1:-}";;
  *) echo "Usage: $0 [setup|list|status [node-id]|rollback [node-id]]" >&2; exit 2;;
esac