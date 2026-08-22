#!/usr/bin/env bash
set -Eeuo pipefail

ETC=/etc/proxy-pool
STATE_DIR=$ETC/antidpi
STATE_FILE=$STATE_DIR/zapret2.state
ROOT=/opt/tyxe-zapret2
CONF_DIR=/etc/tyxe-zapret2
CONF=$CONF_DIR/mtproto.conf
LUA=$ROOT/lua/mtproto.lua
START=/usr/local/sbin/tyxe-zapret2-start
UNIT=/etc/systemd/system/tyxe-zapret2.service
SYSCTL=/etc/sysctl.d/99-tyxe-zapret2.conf
TABLE=TYXE_MTProto
PORT=443
ZAPRET2_VER=v1.0.3

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
cyan(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
getenv_file(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
yesno(){ local p="$1" v=''; read -r -p "$p [y/N]: " v </dev/tty || true; [[ "$v" =~ ^[yY]$ ]]; }

[[ $EUID -eq 0 ]] || { red 'Запустите через sudo/root.'; exit 1; }

require_enter(){
  [[ -r $ETC/settings.env ]] || { red 'TYXE Controller не найден.'; return 1; }
  [[ "$(getenv_file "$ETC/settings.env" PROXY_POOL_ROLE)" == controller ]] || { red 'Анти-DPI модуль ставится на ENTER/controller.'; return 1; }
  systemctl is-active haproxy >/dev/null 2>&1 || { red 'HAProxy не active. Сначала должен быть настроен dataplane.'; return 1; }
  ss -ltnpH 'sport = :443' 2>/dev/null | grep -q haproxy || { red 'HAProxy не слушает TCP/443 на ENTER.'; return 1; }
  install -d -m 700 "$STATE_DIR"
}

pick_queue(){
  local q used
  used=''
  [[ -r /proc/net/netfilter/nfnetlink_queue ]] && used=$(awk '{print $1}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null || true)
  for q in $(seq 200 239); do
    if ! grep -qx "$q" <<<"$used"; then
      QNUM=$q
      return 0
    fi
  done
  red 'Не удалось найти свободную NFQUEUE в диапазоне 200..239.'
  return 1
}

preflight(){
  cyan 'Preflight anti-DPI'
  require_enter
  [[ ! -e $STATE_FILE ]] || { red 'TYXE Zapret2 уже настроен. Используйте status или rollback.'; return 1; }
  if systemctl list-unit-files mtproxyl-zapret2.service >/dev/null 2>&1 || nft list table ip MTProtoL >/dev/null 2>&1; then
    red 'Обнаружен существующий MTProxyL Zapret2. Два обработчика TCP/443 одновременно ставить нельзя.'
    return 1
  fi
  if systemctl list-unit-files tyxe-zapret2.service >/dev/null 2>&1 || nft list table ip "$TABLE" >/dev/null 2>&1; then
    red 'Найдены остатки предыдущего TYXE Zapret2 без state. Удалите их вручную после проверки.'
    return 1
  fi
  pick_queue
  green "Client-facing listener: HAProxy TCP/$PORT"
  green "NFQUEUE: $QNUM"
  green "Zapret2 release: $ZAPRET2_VER"
}

install_deps(){
  cyan 'Dependencies'
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y nftables curl tar ca-certificates
  modprobe nfnetlink_queue
}

install_zapret2(){
  cyan 'Zapret2'
  local machine arch tmp unpack root lua_dir
  machine=$(uname -m)
  case "$machine" in
    x86_64|amd64) arch=linux-x86_64 ;;
    aarch64|arm64) arch=linux-arm64 ;;
    *) red "Неподдерживаемая архитектура: $machine"; return 1 ;;
  esac
  tmp=$(mktemp /tmp/tyxe-zapret2.XXXXXX.tar.gz)
  unpack=$(mktemp -d /tmp/tyxe-zapret2.XXXXXX)
  trap 'rm -rf "${tmp:-}" "${unpack:-}"' RETURN
  curl -fL --retry 3 --connect-timeout 15 -o "$tmp" \
    "https://github.com/bol-van/zapret2/releases/download/${ZAPRET2_VER}/zapret2-${ZAPRET2_VER}.tar.gz"
  tar xzf "$tmp" -C "$unpack"
  root=$(find "$unpack" -maxdepth 1 -mindepth 1 -type d | head -n1)
  [[ -n $root ]] || { red 'Архив zapret2 имеет неожиданную структуру.'; return 1; }
  install -d -m 755 "$ROOT/bin" "$ROOT/lua" "$CONF_DIR"
  install -m 755 "$root/binaries/$arch/nfqws2" "$ROOT/bin/nfqws2"
  lua_dir=''
  for d in "$root/nfq2/lua" "$root/lua" "$root/nfq/lua"; do
    if compgen -G "$d/zapret-lib.lua*" >/dev/null; then lua_dir=$d; break; fi
  done
  [[ -n $lua_dir ]] || { red 'Lua-библиотеки zapret2 не найдены.'; return 1; }
  cp -f "$lua_dir"/zapret-lib.lua* "$ROOT/lua/"
  cp -f "$lua_dir"/zapret-antidpi.lua* "$ROOT/lua/"
  "$ROOT/bin/nfqws2" --version
  trap - RETURN
  rm -rf "$tmp" "$unpack"
}

write_profile(){
  cyan 'MTProxyL-compatible profile'
  cat > "$CONF" <<EOF
--qnum $QNUM
--fwmark=0x40000000
--server
--lua-init=@$ROOT/lua/zapret-lib.lua
--lua-init=@$ROOT/lua/zapret-antidpi.lua
--lua-init=@$LUA
--filter-tcp=$PORT
--out-range=a
--in-range=a
--payload-disable=all
--lua-desync=tyxe_mtproto_fix
--new
EOF

  cat > "$LUA" <<'LUAEOF'
function tyxe_mtproto_fix(ctx, d)
    local flags = d.dis.tcp.th_flags

    if bitand(flags, TH_SYN + TH_ACK) == TH_SYN then
        local o = d.dis.tcp.options
        if d.dis.tcp.th_win == 65535 and #o == 8 and
           o[1].kind == 2 and o[2].kind == 1 and o[3].kind == 3 and o[4].kind == 1 and
           o[5].kind == 1 and o[6].kind == 8 and o[7].kind == 4 and o[8].kind == 0 then
            instance_cutoff(ctx, nil)
            d.arg.fwmark = 0x40000
            rawsend_dissect_segmented(d)
            return VERDICT_DROP
        end
    end

    if bitand(flags, TH_SYN + TH_ACK) == (TH_SYN + TH_ACK) then
        d.track.lua_state["tyxe_ack0"] = d.dis.tcp.th_ack
        d.dis.tcp.th_win = 1400
        return VERDICT_MODIFY
    end

    if direction_check(d) and bitand(flags, TH_SYN + TH_ACK) == TH_ACK then
        local a0 = d.track and d.track.lua_state["tyxe_ack0"]
        if a0 and (d.dis.tcp.th_ack - a0 >= 1400) then
            instance_cutoff(ctx, true)
            d.arg.fwmark = 0x40000
            rawsend_dissect_segmented(d)
            return VERDICT_DROP
        end
        d.dis.tcp.th_win = 10
        return VERDICT_MODIFY
    end

    if #d.dis.payload == 0 or d.track == nil or d.track.pos.client.tcp.rseq ~= 1 then
        return VERDICT_PASS
    end

    local n = 400
    local p1 = string.sub(d.dis.payload, 1, n)
    local p2 = string.sub(d.dis.payload, n + 1, 2 * n)
    local p3 = string.sub(d.dis.payload, 2 * n + 1)
    rawsend_payload_segmented(d, p1)
    rawsend_payload_segmented(d, p3, 2 * n)
    d.arg["badsum"] = true
    rawsend_payload_segmented(d, p2, n)
    instance_cutoff(ctx, false)
    return VERDICT_DROP
end
LUAEOF

  cat > "$START" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
TABLE='$TABLE'
PORT='$PORT'
QNUM='$QNUM'
FWMARK='0x40000000'
CTMARK='0x00040000'
BOTH='0x40040000'
ACK_ONLY='tcp flags & (fin | syn | rst | ack) == ack'

sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true
nft delete table ip "\$TABLE" 2>/dev/null || true
nft add table ip "\$TABLE"
nft "add chain ip \$TABLE predefrag { type filter hook output priority -401; policy accept; }"
nft "add rule ip \$TABLE predefrag meta mark \$BOTH counter accept"
nft "add rule ip \$TABLE predefrag meta mark and \$FWMARK != 0x00000000 counter notrack"
nft "add chain ip \$TABLE output { type route hook output priority mangle; policy accept; }"
nft "add rule ip \$TABLE output meta mark and \$BOTH == \$BOTH ct mark set \$CTMARK counter accept"
nft "add chain ip \$TABLE postrouting { type filter hook postrouting priority srcnat + 1; policy accept; }"
nft "add rule ip \$TABLE postrouting \$ACK_ONLY ct mark \$CTMARK counter accept"
nft "add rule ip \$TABLE postrouting meta mark and \$FWMARK == 0x00000000 tcp sport \$PORT counter queue num \$QNUM bypass"
nft "add chain ip \$TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }"
nft "add rule ip \$TABLE prerouting tcp dport \$PORT ct state invalid counter drop"
nft "add rule ip \$TABLE prerouting \$ACK_ONLY ct mark \$CTMARK counter accept"
nft "add rule ip \$TABLE prerouting meta mark and \$FWMARK == 0x00000000 tcp dport \$PORT counter queue num \$QNUM bypass"
exec '$ROOT/bin/nfqws2' '@$CONF'
EOF
  chmod 755 "$START"

  cat > "$UNIT" <<EOF
[Unit]
Description=TYXE Zapret2 MTProto client-facing anti-DPI
After=network-online.target haproxy.service nftables.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$START
ExecStop=-/usr/sbin/nft delete table ip $TABLE
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  printf 'net.ipv4.tcp_tw_reuse = 1\n' > "$SYSCTL"
  chmod 644 "$SYSCTL" "$UNIT" "$CONF" "$LUA"
}

save_state(){
  local old_tw
  old_tw=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo 2)
  umask 077
  {
    printf 'QNUM=%q\n' "$QNUM"
    printf 'PORT=%q\n' "$PORT"
    printf 'OLD_TCP_TW_REUSE=%q\n' "$old_tw"
    printf 'ZAPRET2_VER=%q\n' "$ZAPRET2_VER"
  } > "$STATE_FILE"
}

start_service(){
  cyan 'Start'
  sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null
  systemctl daemon-reload
  systemctl enable --now tyxe-zapret2.service
  sleep 2
  systemctl is-active tyxe-zapret2.service >/dev/null
  nft list table ip "$TABLE" >/dev/null
  grep -q "^$QNUM " /proc/net/netfilter/nfnetlink_queue 2>/dev/null || { red "NFQUEUE $QNUM не зарегистрирована."; return 1; }
  green "Zapret2 active на client-facing TCP/$PORT (NFQUEUE $QNUM)."
}

setup(){
  preflight
  yellow 'Будет включён серверный Zapret2 MTProto fix только на ENTER TCP/443.'
  yellow 'AWG, Telemt на EXIT и HAProxy backend не изменяются.'
  yesno 'Включить анти-DPI?' || exit 0
  save_state
  install_deps
  install_zapret2
  write_profile
  if ! start_service; then
    red 'Запуск Zapret2 не прошёл. Выполните: sudo tyxe-antidpi rollback'
    exit 1
  fi
  status
}

status(){
  require_enter
  cyan 'TYXE anti-DPI status'
  printf 'Service: '; systemctl is-active tyxe-zapret2.service 2>/dev/null || true
  printf 'HAProxy: '; systemctl is-active haproxy 2>/dev/null || true
  printf 'tcp_tw_reuse: '; sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || true
  if [[ -r $STATE_FILE ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    printf 'NFQUEUE: %s\n' "$QNUM"
  fi
  printf '\nNFQUEUE kernel state:\n'
  cat /proc/net/netfilter/nfnetlink_queue 2>/dev/null || true
  printf '\nNFT counters:\n'
  nft list table ip "$TABLE" 2>/dev/null || true
  printf '\nRecent log:\n'
  journalctl -u tyxe-zapret2.service -n 20 --no-pager 2>/dev/null || true
}

rollback(){
  require_enter
  [[ -r $STATE_FILE ]] || { red 'State TYXE Zapret2 не найден.'; exit 1; }
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  yesno 'Отключить и удалить TYXE Zapret2 anti-DPI?' || exit 0
  systemctl disable --now tyxe-zapret2.service >/dev/null 2>&1 || true
  nft delete table ip "$TABLE" 2>/dev/null || true
  rm -f "$UNIT" "$START" "$SYSCTL"
  rm -rf "$ROOT" "$CONF_DIR"
  systemctl daemon-reload
  sysctl -w "net.ipv4.tcp_tw_reuse=${OLD_TCP_TW_REUSE:-2}" >/dev/null 2>&1 || true
  rm -f "$STATE_FILE"
  green 'TYXE Zapret2 удалён. AWG, HAProxy и Telemt не затронуты.'
}

case "${1:-status}" in
  setup|install) setup ;;
  status) status ;;
  rollback|remove|uninstall) rollback ;;
  *) echo 'Usage: tyxe-antidpi [setup|status|rollback]' >&2; exit 2 ;;
esac
