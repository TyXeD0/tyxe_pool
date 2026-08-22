#!/usr/bin/env bash
set -Eeuo pipefail

LANG_CODE="${TYXE_POOL_LANG:-ru}"
TELEMT_REPO="${TYXE_TELEMT_REPO:-telemt/telemt}"
TELEMT_INSTALL_URL="https://raw.githubusercontent.com/${TELEMT_REPO}/main/install.sh"
TELEMT_SERVICE="${PROXY_POOL_TELEMT_SERVICE:-telemt}"
TELEMT_CONFIG="${PROXY_POOL_TELEMT_CONFIG:-/etc/telemt/telemt.toml}"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
read_tty(){ local __var="$1" __prompt="$2" __silent="${3:-0}" value=''; if [[ "$__silent" == 1 ]]; then read -r -s -p "$__prompt" value </dev/tty || true; printf '\n' >/dev/tty; else read -r -p "$__prompt" value </dev/tty || true; fi; printf -v "$__var" '%s' "$value"; }
ask(){ local prompt="$1" def="${2:-}" v=''; read_tty v "$prompt${def:+ [$def]}: "; printf '%s' "${v:-$def}"; }
choice(){ local prompt="$1" min="$2" max="$3" v=''; while :; do read_tty v "$prompt"; if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )); then printf '%s' "$v"; return; fi; echo '1..'$max; done; }

msg(){
  if [[ "$LANG_CODE" == ru ]]; then
    case "$1" in
      root) echo 'Запустите от root или через sudo.';;
      title) echo 'TYXE Pool — Telemt Manager';;
      menu) printf '1) Статус\n2) Установить / обновить Telemt\n3) Запустить\n4) Остановить\n5) Перезапустить\n6) Логи\n7) Выход\n';;
      domain) echo 'TLS/SNI домен Telemt';;
      port) echo 'Порт Telemt';;
      secret) echo 'Секрет пользователя (32 HEX, пусто = сгенерировать Telemt)';;
      installing) echo 'Запускаю официальный установщик Telemt...';;
      installed) echo 'Telemt установлен/обновлён.';;
      absent) echo 'Telemt не найден.';;
    esac
  else
    case "$1" in
      root) echo 'Run as root or with sudo.';;
      title) echo 'TYXE Pool — Telemt Manager';;
      menu) printf '1) Status\n2) Install / update Telemt\n3) Start\n4) Stop\n5) Restart\n6) Logs\n7) Exit\n';;
      domain) echo 'Telemt TLS/SNI domain';;
      port) echo 'Telemt port';;
      secret) echo 'User secret (32 HEX, blank = let Telemt generate it)';;
      installing) echo 'Running the official Telemt installer...';;
      installed) echo 'Telemt installed/updated.';;
      absent) echo 'Telemt not found.';;
    esac
  fi
}

[[ $EUID -eq 0 ]] || { red "$(msg root)"; exit 1; }

status(){
  echo "Service: $TELEMT_SERVICE"
  systemctl status "$TELEMT_SERVICE" --no-pager -l || true
  echo
  if command -v telemt >/dev/null 2>&1; then
    telemt --version 2>/dev/null || telemt -V 2>/dev/null || true
  elif [[ -x /bin/telemt ]]; then
    /bin/telemt --version 2>/dev/null || /bin/telemt -V 2>/dev/null || true
  else
    yellow "$(msg absent)"
  fi
  [[ -f "$TELEMT_CONFIG" ]] && echo "Config: $TELEMT_CONFIG" || true
}

install_or_update(){
  command -v curl >/dev/null 2>&1 || apt-get install -y curl
  local domain port secret args
  domain=$(ask "$(msg domain)" 'petrovich.ru')
  port=$(ask "$(msg port)" '443')
  secret=''
  read_tty secret "$(msg secret): " 1
  [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )) || { red 'Invalid port'; return 1; }
  if [[ -n "$secret" && ! "$secret" =~ ^[0-9a-fA-F]{32}$ ]]; then red 'Secret must be exactly 32 HEX chars'; return 1; fi
  args=(--lang "$LANG_CODE" --domain "$domain" --port "$port")
  [[ -n "$secret" ]] && args+=(--secret "$secret")
  yellow "$(msg installing)"
  curl -fsSL "$TELEMT_INSTALL_URL" | bash -s -- "${args[@]}"
  green "$(msg installed)"
}

case "${1:-menu}" in
  status) status;;
  install|update) install_or_update;;
  start|stop|restart) systemctl "$1" "$TELEMT_SERVICE"; status;;
  logs) journalctl -u "$TELEMT_SERVICE" -n "${2:-150}" --no-pager;;
  menu)
    echo "$(msg title)"
    while :; do
      echo; msg menu
      c=$(choice '> ' 1 7)
      case "$c" in
        1) status;; 2) install_or_update;; 3) systemctl start "$TELEMT_SERVICE";; 4) systemctl stop "$TELEMT_SERVICE";; 5) systemctl restart "$TELEMT_SERVICE";; 6) journalctl -u "$TELEMT_SERVICE" -n 150 --no-pager;; 7) exit 0;;
      esac
    done
    ;;
  *) red 'Unknown action'; exit 2;;
esac
