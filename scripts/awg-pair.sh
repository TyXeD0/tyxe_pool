#!/usr/bin/env bash
set -Eeuo pipefail

ETC=/etc/proxy-pool
AWG_DIR=/etc/amnezia/amneziawg
AWG_CONF=$AWG_DIR/awg0.conf
AWG_SERVICE=awg-quick@awg0
STATE=$ETC/awg-pair.state
BACKUP=/var/lib/proxy-pool/awg-pair
DROPIN=/etc/systemd/system/proxy-pool-agent.service.d/10-tyxe-awg.conf

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
cyan(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
read_tty(){ local n="$1" p="$2" v=''; read -r -p "$p" v </dev/tty || true; printf -v "$n" '%s' "$v"; }
ask(){ local n="$1" p="$2" d="$3" v=''; read_tty v "$p [$d]: "; printf -v "$n" '%s' "${v:-$d}"; }
yesno(){ local p="$1" v=''; read_tty v "$p [y/N]: "; [[ "$v" =~ ^[yY]$ ]]; }
getenv(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }

[[ $EUID -eq 0 ]] || { red 'Запустите через sudo/root.'; exit 1; }

require_enter(){
  [[ -r $ETC/settings.env ]] || { red 'TYXE Controller не найден.'; exit 1; }
  [[ "$(getenv "$ETC/settings.env" PROXY_POOL_ROLE)" == controller ]] || { red 'tyxe-awg нужно запускать на ENTER/controller.'; exit 1; }
}

ssh_build(){
  SSH=(-p "$SSH_PORT" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
  [[ -n ${SSH_KEY:-} ]] && SSH+=(-i "$SSH_KEY")
  TARGET="root@$EXIT_HOST"
}
rx(){ ssh "${SSH[@]}" "$TARGET" "$@"; }
rscript(){ ssh "${SSH[@]}" "$TARGET" 'bash -s'; }

install_awg_local(){
  command -v awg >/dev/null 2>&1 && modprobe amneziawg >/dev/null 2>&1 && return
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || { red 'AWG beta сейчас рассчитан на Ubuntu 22.04/24.04.'; return 1; }
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)"
  grep -Rqs 'ppa.launchpadcontent.net/amnezia/ppa' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || add-apt-repository -y ppa:amnezia/ppa
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg
  modprobe amneziawg
}

install_awg_remote(){
  rscript <<'REMOTE'
set -Eeuo pipefail
command -v awg >/dev/null 2>&1 && modprobe amneziawg >/dev/null 2>&1 && exit 0
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || { echo 'TYXE: EXIT должен быть Ubuntu 22.04/24.04 для текущего AWG beta.' >&2; exit 1; }
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)"
grep -Rqs 'ppa.launchpadcontent.net/amnezia/ppa' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || add-apt-repository -y ppa:amnezia/ppa
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg
modprobe amneziawg
REMOTE
}

save_state(){
  install -d -m 700 "$ETC"
  umask 077
  {
    printf 'EXIT_HOST=%q\n' "$EXIT_HOST"
    printf 'SSH_PORT=%q\n' "$SSH_PORT"
    printf 'SSH_KEY=%q\n' "$SSH_KEY"
    printf 'AWG_PORT=%q\n' "$AWG_PORT"
    printf 'ENTER_IP=%q\n' "$ENTER_IP"
    printf 'EXIT_IP=%q\n' "$EXIT_IP"
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

load_state(){
  [[ -r $STATE ]] || { red 'AWG state не найден.'; exit 1; }
  # STATE создаёт только TYXE через printf %q.
  # shellcheck disable=SC1090
  . "$STATE"
  ssh_build
}

backup_all(){
  install -d -m 700 "$BACKUP"
  TS=$(date +%s)
  LOCAL_WAS_ACTIVE=$(systemctl is-active "$AWG_SERVICE" 2>/dev/null || true)
  REMOTE_WAS_ACTIVE=$(rx "systemctl is-active '$AWG_SERVICE' 2>/dev/null || true")
  LOCAL_BACKUP="$BACKUP/awg0.local.$TS"
  [[ -f $AWG_CONF ]] && cp -a "$AWG_CONF" "$LOCAL_BACKUP" || : > "$LOCAL_BACKUP.absent"

  REMOTE_BACKUP="/var/lib/proxy-pool/awg-pair/awg0.remote.$TS"
  REMOTE_SETTINGS_BACKUP="/var/lib/proxy-pool/awg-pair/settings.$TS"
  REMOTE_DROPIN_BACKUP="/var/lib/proxy-pool/awg-pair/dropin.$TS"
  rscript <<REMOTE
set -Eeuo pipefail
mkdir -p /var/lib/proxy-pool/awg-pair
chmod 700 /var/lib/proxy-pool/awg-pair
[[ -f '$AWG_CONF' ]] && cp -a '$AWG_CONF' '$REMOTE_BACKUP' || : > '$REMOTE_BACKUP.absent'
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

  install -d -m 700 "$AWG_DIR"
  umask 077
  cat > "$AWG_CONF" <<EOF
[Interface]
Address = $ENTER_IP/24
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
  chmod 600 "$AWG_CONF"

  rscript <<EOF
set -Eeuo pipefail
install -d -m 700 '$AWG_DIR'
cat > '$AWG_CONF' <<'CFG'
[Interface]
Address = $EXIT_IP/24
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
chmod 600 '$AWG_CONF'
EOF
  unset EPRIV XPRIV PSK
}

move_agent(){
  rx "test -f '$ETC/settings.env'" || return 0
  rscript <<EOF
set -Eeuo pipefail
python3 - '$ETC/settings.env' '$EXIT_IP' <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); ip=sys.argv[2]
text=p.read_bytes().decode('utf-8',errors='ignore')
out=[]; seen=False
for line in text.splitlines():
    if line.startswith('PROXY_POOL_AGENT_BIND='):
        out.append('PROXY_POOL_AGENT_BIND='+ip); seen=True
    else: out.append(line)
if not seen: out.append('PROXY_POOL_AGENT_BIND='+ip)
p.write_text('\\n'.join(out)+'\\n',encoding='utf-8')
PY
install -d -m 755 /etc/systemd/system/proxy-pool-agent.service.d
cat > '$DROPIN' <<'UNIT'
[Unit]
Requires=awg-quick@awg0.service
After=awg-quick@awg0.service
UNIT
systemctl daemon-reload
systemctl restart proxy-pool-agent
EOF
}

remote_token(){
  rscript <<'REMOTE'
python3 - <<'PY'
from pathlib import Path
p=Path('/etc/proxy-pool/settings.env')
for l in p.read_text(encoding='utf-8',errors='ignore').splitlines():
    if l.startswith('PROXY_POOL_AGENT_TOKEN='):
        print(l.split('=',1)[1].strip().strip('"').strip("'")); break
PY
REMOTE
}

register_node(){
  local lt cp count name payload
  lt=$(getenv "$ETC/settings.env" PROXY_POOL_LOCAL_API_TOKEN)
  cp=$(getenv "$ETC/settings.env" PROXY_POOL_PORT); cp=${cp:-9101}
  [[ -n $lt && -n ${TOKEN:-} ]] || return 0
  count=$(curl -fsS -H "Authorization: Bearer $lt" "http://127.0.0.1:$cp/api/nodes" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("nodes",[])))')
  [[ $count == 0 ]] || { echo 'Controller уже содержит EXIT — автодобавление пропущено.'; return 0; }
  name=$(curl -fsS -H "Authorization: Bearer $TOKEN" "http://$EXIT_IP:9100/v1/status" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("node_name","PL EXIT"))')
  payload=$(python3 - "$name" "$EXIT_IP" "$TOKEN" <<'PY'
import json,sys
print(json.dumps({"name":sys.argv[1],"address":sys.argv[2],"agent_port":9100,"token":sys.argv[3]}))
PY
)
  curl -fsS -H "Authorization: Bearer $lt" -H 'Content-Type: application/json' -d "$payload" "http://127.0.0.1:$cp/api/nodes" >/dev/null
}

setup(){
  require_enter
  cyan 'TYXE AWG ENTER ↔ EXIT'
  [[ ! -r $STATE ]] || { yesno 'AWG pair уже настроен. Пересоздать?' || exit 0; }

  ask EXIT_HOST 'Публичный IP/hostname EXIT' ''
  [[ $EXIT_HOST =~ ^[A-Za-z0-9._:-]+$ ]] || { red 'Некорректный EXIT host.'; exit 1; }
  ask SSH_PORT 'SSH-порт EXIT' 22
  ask SSH_KEY 'SSH private key (пусто = password/ssh-agent)' ''
  [[ -z $SSH_KEY || -r $SSH_KEY ]] || { red 'SSH key не читается.'; exit 1; }
  ask AWG_PORT 'UDP-порт AWG на EXIT' 8443
  ask ENTER_IP 'Tunnel IP ENTER' 10.10.10.2
  ask EXIT_IP 'Tunnel IP EXIT' 10.10.10.1
  ssh_build

  cyan 'SSH'
  rx 'id -u' | grep -qx 0 || { red 'Для beta нужен root SSH на EXIT.'; exit 1; }
  ENTER_PUBLIC_IP=$(rx "printf '%s\n' \"\$SSH_CLIENT\" | awk '{print \$1}'")
  green "EXIT видит ENTER как $ENTER_PUBLIC_IP"

  cyan 'AmneziaWG'
  install_awg_local
  install_awg_remote

  cyan 'Backup'
  backup_all
  UFW_ADDED=0
  save_state

  systemctl stop "$AWG_SERVICE" 2>/dev/null || true
  rx "systemctl stop '$AWG_SERVICE' 2>/dev/null || true"
  gen_configs

  if rx "command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'"; then
    if ! rx "ufw status | grep -Fq '$AWG_PORT/udp'"; then
      rx "ufw allow from '$ENTER_PUBLIC_IP' to any port '$AWG_PORT' proto udp"
      UFW_ADDED=1
    fi
  fi
  save_state

  cyan 'Start'
  rx "systemctl enable '$AWG_SERVICE' >/dev/null 2>&1 || true; systemctl restart '$AWG_SERVICE'"
  systemctl enable "$AWG_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$AWG_SERVICE"

  cyan 'Agent'
  TOKEN=$(remote_token || true)
  move_agent

  cyan 'Проверка'
  ping -c 3 -W 2 "$EXIT_IP" >/dev/null || { red 'Нет ping до EXIT tunnel IP.'; exit 1; }
  green "ping $EXIT_IP: OK"
  if [[ -n ${TOKEN:-} ]]; then
    curl -fsS -H "Authorization: Bearer $TOKEN" "http://$EXIT_IP:9100/v1/status" | python3 -m json.tool
    register_node
  fi
  green 'AWG pair готов. Agent API доступен только через туннель.'
  echo 'Следующий этап: Telemt proxy_protocol/bind + HAProxy.'
}

status(){
  load_state
  cyan 'AWG status'
  systemctl status "$AWG_SERVICE" --no-pager -l || true
  awg show awg0 || true
  ping -c 2 -W 2 "$EXIT_IP" || true
  rx "systemctl status '$AWG_SERVICE' --no-pager -l" || true
}

rollback(){
  load_state
  yesno 'Откатить AWG pair?' || exit 0
  systemctl disable --now "$AWG_SERVICE" 2>/dev/null || true
  rx "systemctl disable --now '$AWG_SERVICE' 2>/dev/null || true" || true

  [[ -f $LOCAL_BACKUP ]] && install -Dm 600 "$LOCAL_BACKUP" "$AWG_CONF" || rm -f "$AWG_CONF"
  rscript <<EOF
set -Eeuo pipefail
[[ -f '$REMOTE_BACKUP' ]] && install -Dm 600 '$REMOTE_BACKUP' '$AWG_CONF' || rm -f '$AWG_CONF'
[[ -f '$REMOTE_SETTINGS_BACKUP' ]] && install -Dm 600 '$REMOTE_SETTINGS_BACKUP' '$ETC/settings.env' || true
[[ -f '$REMOTE_DROPIN_BACKUP' ]] && install -Dm 644 '$REMOTE_DROPIN_BACKUP' '$DROPIN' || rm -f '$DROPIN'
systemctl daemon-reload
systemctl restart proxy-pool-agent 2>/dev/null || true
EOF
  [[ ${LOCAL_WAS_ACTIVE:-inactive} == active ]] && systemctl start "$AWG_SERVICE" || true
  [[ ${REMOTE_WAS_ACTIVE:-inactive} == active ]] && rx "systemctl start '$AWG_SERVICE'" || true
  [[ ${UFW_ADDED:-0} == 1 ]] && rx "ufw --force delete allow from '$ENTER_PUBLIC_IP' to any port '$AWG_PORT' proto udp" || true
  rm -f "$STATE"
  green 'AWG pair откатан. Пакет amneziawg намеренно оставлен установленным.'
}

case "${1:-setup}" in
  setup|install) setup;;
  status) status;;
  rollback|uninstall) rollback;;
  *) echo "Usage: $0 [setup|status|rollback]" >&2; exit 2;;
esac
