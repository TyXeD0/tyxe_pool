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
  TITLE='TYXE Pool — главное меню'; BAD_CHOICE='Неверный выбор.'; NOT_INSTALLED='компонент ещё не установлен'; PRESS_ENTER='Enter для продолжения...'; STATUS='Статус'
else
  TITLE='TYXE Pool — main menu'; BAD_CHOICE='Invalid choice.'; NOT_INSTALLED='component is not installed yet'; PRESS_ENTER='Press Enter to continue...'; STATUS='Status'
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
  if command -v tyxe-shared443 >/dev/null 2>&1; then printf '\nShared 443:\n'; tyxe-shared443 status || true; fi
}

agent_status(){
  cyan "$STATUS / EXIT"
  printf 'Agent:  '; systemctl is-active proxy-pool-agent 2>/dev/null || true
  printf 'AWG:    '; systemctl is-active awg-quick@awg0.service 2>/dev/null || true
  printf 'Telemt: '; systemctl is-active telemt 2>/dev/null || true
  ss -ltnp 2>/dev/null | grep -E ':(443|9100|9091)\b' || true
}

awg_menu(){
  while :; do
    cyan 'AmneziaWG'
    if [[ $LANG_CODE == ru ]]; then
      printf '%s\n' '1) Список пар' '2) Статус пары' '3) Добавить EXIT / создать пару' '4) Откатить пару' '5) Назад'
    else
      printf '%s\n' '1) List pairs' '2) Pair status' '3) Add EXIT / create pair' '4) Roll back pair' '5) Back'
    fi
    local c; c=$(choice '> ' 1 5)
    case "$c" in 1) run_or_warn tyxe-awg list; pause;; 2) run_or_warn tyxe-awg status; pause;; 3) run_or_warn tyxe-awg setup; pause;; 4) run_or_warn tyxe-awg rollback; pause;; 5) return 0;; esac
  done
}

dataplane_menu(){
  while :; do
    cyan 'Dataplane'
    if [[ $LANG_CODE == ru ]]; then printf '%s\n' '1) Статус' '2) Настроить HAProxy ↔ Telemt' '3) Откатить dataplane' '4) Назад'; else printf '%s\n' '1) Status' '2) Configure HAProxy ↔ Telemt' '3) Roll back dataplane' '4) Back'; fi
    local c; c=$(choice '> ' 1 4)
    case "$c" in 1) run_or_warn tyxe-dataplane status; pause;; 2) run_or_warn tyxe-dataplane setup; pause;; 3) run_or_warn tyxe-dataplane rollback; pause;; 4) return 0;; esac
  done
}

shared443_menu(){
  while :; do
    cyan 'Shared TCP/443 / selfsteal'
    if [[ $LANG_CODE == ru ]]; then
      printf '%s\n' '1) Статус classifier' '2) Включить SNI classifier + HTTPS-заглушку' '3) Откатить classifier' '4) Назад'
    else
      printf '%s\n' '1) Classifier status' '2) Enable SNI classifier + HTTPS decoy' '3) Roll back classifier' '4) Back'
    fi
    local c; c=$(choice '> ' 1 4)
    case "$c" in 1) run_or_warn tyxe-shared443 status; pause;; 2) run_or_warn tyxe-shared443 setup; pause;; 3) run_or_warn tyxe-shared443 rollback; pause;; 4) return 0;; esac
  done
}

enter_menu(){
  while :; do
    clear 2>/dev/null || true
    cyan "$TITLE"
    if [[ $LANG_CODE == ru ]]; then
      printf '%s\n' \
        '1) Статус ENTER / цепочки' \
        '2) EXIT-ноды / Controller' \
        '3) AmneziaWG пары' \
        '4) Dataplane: HAProxy ↔ Telemt' \
        '5) Anti-DPI / официальный MTProxyL' \
        '6) Shared TCP/443 / selfsteal classifier' \
        '7) Аварийный встроенный Zapret2 fallback' \
        '8) Выход'
    else
      printf '%s\n' \
        '1) ENTER / chain status' \
        '2) EXIT nodes / Controller' \
        '3) AmneziaWG pairs' \
        '4) Dataplane: HAProxy ↔ Telemt' \
        '5) Anti-DPI / official MTProxyL' \
        '6) Shared TCP/443 / selfsteal classifier' \
        '7) Emergency built-in Zapret2 fallback' \
        '8) Exit'
    fi
    local c; c=$(choice '> ' 1 8)
    case "$c" in
      1) enter_status; pause;;
      2) run_or_warn tyxe-pool-node menu; pause;;
      3) awg_menu;;
      4) dataplane_menu;;
      5) run_or_warn tyxe-mtproxyl menu; pause;;
      6) shared443_menu;;
      7) run_or_warn tyxe-antidpi-fallback status; pause;;
      8) return 0;;
    esac
  done
}

agent_menu(){
  while :; do
    clear 2>/dev/null || true
    cyan "$TITLE"
    if [[ $LANG_CODE == ru ]]; then printf '%s\n' '1) Статус EXIT' '2) Управление Telemt' '3) Выход'; else printf '%s\n' '1) EXIT status' '2) Manage Telemt' '3) Exit'; fi
    local c; c=$(choice '> ' 1 3)
    case "$c" in 1) agent_status; pause;; 2) run_or_warn tyxe-telemt menu; pause;; 3) return 0;; esac
  done
}

case "$ROLE" in
  controller) enter_menu;;
  agent) agent_menu;;
  *) red "Unknown TYXE role: ${ROLE:-empty}"; exit 1;;
esac
