#!/usr/bin/env bash
set -Eeuo pipefail

ETC=/etc/proxy-pool
SETTINGS=$ETC/settings.env

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
cyan(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
read_tty(){ local __name="$1" __prompt="$2" __value=''; read -r -p "$__prompt" __value </dev/tty || true; printf -v "$__name" '%s' "$__value"; }
choice(){ local p="$1" min="$2" max="$3" v=''; while :; do read_tty v "$p"; if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )); then printf '%s' "$v"; return 0; fi; red "${BAD_CHOICE}"; done; }
getenv_file(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
pause(){ local _; read_tty _ "$PRESS_ENTER"; }
run_or_warn(){ local cmd="$1"; shift; if command -v "$cmd" >/dev/null 2>&1; then "$cmd" "$@"; else red "$cmd: $NOT_INSTALLED"; fi; }

[[ $EUID -eq 0 ]] || { red 'Run as root / Запустите через sudo.'; exit 1; }
[[ -r $SETTINGS ]] || { red 'TYXE Pool settings not found / Настройки TYXE Pool не найдены.'; exit 1; }

LANG_CODE=$(getenv_file "$SETTINGS" TYXE_POOL_LANG)
[[ $LANG_CODE =~ ^(ru|en)$ ]] || LANG_CODE=ru
ROLE=$(getenv_file "$SETTINGS" PROXY_POOL_ROLE)

if [[ $LANG_CODE == ru ]]; then
  TITLE='TYXE Pool — главное меню'
  BAD_CHOICE='Неверный выбор.'
  NOT_INSTALLED='компонент ещё не установлен'
  PRESS_ENTER='Enter для продолжения...'
  STATUS='Статус'
  EXIT='Выход'
else
  TITLE='TYXE Pool — main menu'
  BAD_CHOICE='Invalid choice.'
  NOT_INSTALLED='component is not installed yet'
  PRESS_ENTER='Press Enter to continue...'
  STATUS='Status'
  EXIT='Exit'
fi

enter_status(){
  cyan "$STATUS / ENTER"
  printf 'Controller: '; systemctl is-active proxy-pool-controller 2>/dev/null || true
  printf 'HAProxy:    '; systemctl is-active haproxy 2>/dev/null || true
  printf 'TCP/443:   '; ss -ltnpH 'sport = :443' 2>/dev/null || true
  printf '\nAWG:\n'; command -v tyxe-awg >/dev/null 2>&1 && tyxe-awg list || true
  printf '\nNodes:\n'; command -v tyxe-pool-node >/dev/null 2>&1 && tyxe-pool-node list || true
  if command -v tyxe-mtproxyl >/dev/null 2>&1; then
    printf '\nAnti-DPI / MTProxyL:\n'
    if command -v mtproxyl >/dev/null 2>&1; then mtproxyl version 2>/dev/null || true; mtproxyl mode --json 2>/dev/null || true; else echo 'not installed'; fi
  fi
}

agent_status(){
  cyan "$STATUS / EXIT"
  printf 'Agent:  '; systemctl is-active proxy-pool-agent 2>/dev/null || true
  printf 'AWG:    '; systemctl is-active awg-quick@awg0.service 2>/dev/null || true
  printf 'Telemt: '; systemctl is-active telemt 2>/dev/null || true
  ss -ltnp 2>/dev/null | grep -E ':(443|9100|9091)\b' || true
}

enter_menu(){
  while :; do
    clear 2>/dev/null || true
    cyan "$TITLE"
    if [[ $LANG_CODE == ru ]]; then
      cat <<'MENU'
1) Статус ENTER / цепочки
2) EXIT-ноды / Controller
3) AmneziaWG пары
4) Dataplane: HAProxy ↔ Telemt
5) Anti-DPI / официальный MTProxyL
6) Аварийный встроенный Zapret2 fallback
7) Выход
MENU
    else
      cat <<'MENU'
1) ENTER / chain status
2) EXIT nodes / Controller
3) AmneziaWG pairs
4) Dataplane: HAProxy ↔ Telemt
5) Anti-DPI / official MTProxyL
6) Emergency built-in Zapret2 fallback
7) Exit
MENU
    fi
    local c; c=$(choice '> ' 1 7)
    case "$c" in
      1) enter_status; pause;;
      2) run_or_warn tyxe-pool-node menu; pause;;
      3) run_or_warn tyxe-awg; pause;;
      4) run_or_warn tyxe-dataplane status; pause;;
      5) run_or_warn tyxe-mtproxyl menu; pause;;
      6) run_or_warn tyxe-antidpi-fallback status; pause;;
      7) return 0;;
    esac
  done
}

agent_menu(){
  while :; do
    clear 2>/dev/null || true
    cyan "$TITLE"
    if [[ $LANG_CODE == ru ]]; then
      cat <<'MENU'
1) Статус EXIT
2) Управление Telemt
3) Выход
MENU
    else
      cat <<'MENU'
1) EXIT status
2) Manage Telemt
3) Exit
MENU
    fi
    local c; c=$(choice '> ' 1 3)
    case "$c" in
      1) agent_status; pause;;
      2) run_or_warn tyxe-telemt menu; pause;;
      3) return 0;;
    esac
  done
}

case "$ROLE" in
  controller) enter_menu;;
  agent) agent_menu;;
  *) red "Unknown TYXE role: ${ROLE:-empty}"; exit 1;;
esac
