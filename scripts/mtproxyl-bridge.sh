#!/usr/bin/env bash
set -Eeuo pipefail

ETC=/etc/proxy-pool
UPSTREAM_INSTALL='https://raw.githubusercontent.com/Liafanx/MTProxyL/main/install.sh'
MTPROXYL_BIN='/usr/local/bin/mtproxyl'
PORT=443

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
cyan(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
read_tty(){ local __name="$1" __prompt="$2" __value=''; read -r -p "$__prompt" __value </dev/tty || true; printf -v "$__name" '%s' "$__value"; }
yesno(){ local p="$1" def="${2:-y}" v=''; while :; do read_tty v "$p [y/n] ($def): "; v="${v:-$def}"; case "$v" in y|Y) return 0;; n|N) return 1;; *) echo 'y/n';; esac; done; }
choice(){ local p="$1" min="$2" max="$3" v=''; while :; do read_tty v "$p"; [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )) && { printf '%s' "$v"; return 0; }; red 'Неверный выбор.'; done; }
getenv_file(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }

[[ $EUID -eq 0 ]] || { red 'Запустите через sudo/root.'; exit 1; }

require_enter(){
  [[ -r $ETC/settings.env ]] || { red 'TYXE Pool не найден.'; return 1; }
  [[ "$(getenv_file "$ETC/settings.env" PROXY_POOL_ROLE)" == controller ]] || { red 'MTProxyL anti-DPI интеграция должна запускаться на ENTER/controller.'; return 1; }
  systemctl is-active haproxy >/dev/null 2>&1 || { red 'HAProxy не active. Сначала настройте dataplane.'; return 1; }
  ss -ltnpH 'sport = :443' 2>/dev/null | grep -q haproxy || { red 'HAProxy не слушает TCP/443 на ENTER.'; return 1; }
}

have_mtproxyl(){ [[ -x $MTPROXYL_BIN ]] || command -v mtproxyl >/dev/null 2>&1; }
mt(){ if [[ -x $MTPROXYL_BIN ]]; then "$MTPROXYL_BIN" "$@"; else mtproxyl "$@"; fi; }

show_context(){
  cyan 'TYXE ↔ MTProxyL'
  echo 'Роль MTProxyL здесь: host-only anti-DPI на ENTER.'
  echo 'TYXE продолжает владеть HAProxy/AWG/EXIT Telemt.'
  echo 'Обязательный режим MTProxyL: Reanimator → Только оптимизация.'
  echo "Client-facing port: TCP/$PORT (HAProxy)"
}

mode_json(){ mt mode --json 2>/dev/null || true; }
assert_tools_only(){
  local j mode tools
  j=$(mode_json)
  if [[ -z $j ]]; then
    red 'Не удалось прочитать режим MTProxyL через: mtproxyl mode --json'
    return 1
  fi
  read -r mode tools < <(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("mode",""), str(bool(d.get("tools_only",False))).lower())' <<<"$j" 2>/dev/null || echo 'invalid false')
  if [[ $mode != reanimator ]]; then
    red "MTProxyL mode=$mode. На TYXE ENTER разрешён только Reanimator."
    red 'Откройте полное меню MTProxyL → Цель / режим → Reanimator.'
    return 1
  fi
  if [[ $tools != true ]]; then
    red 'MTProxyL Reanimator активен, но «Только оптимизация» выключена.'
    red 'Откройте полное меню MTProxyL → Цель / режим → Только оптимизация.'
    return 1
  fi
  green 'MTProxyL mode: reanimator + tools_only=true'
}

install_upstream(){
  require_enter
  show_context
  if have_mtproxyl; then
    green "MTProxyL уже установлен: $(mt version 2>/dev/null | head -n1 || echo installed)"
    update_upstream
    return 0
  fi

  cyan 'Установка актуального MTProxyL upstream'
  yellow 'Сейчас будет запущен официальный интерактивный installer Liafanx/MTProxyL из ветки main.'
  yellow 'На ENTER выбирайте Reanimator → «Только оптимизация».'
  yellow 'НЕ выбирайте Manager: движком и Telemt управляет TYXE на EXIT.'
  yesno 'Скачать и запустить официальный MTProxyL installer?' y || return 0

  local tmp
  tmp=$(mktemp /tmp/tyxe-mtproxyl-install.XXXXXX.sh)
  trap 'rm -f "${tmp:-}"' RETURN
  curl -fL --retry 3 --connect-timeout 15 "$UPSTREAM_INSTALL" -o "$tmp"
  chmod 700 "$tmp"
  echo "Source: $UPSTREAM_INSTALL"
  printf 'SHA256: '; sha256sum "$tmp" | awk '{print $1}'
  bash "$tmp"
  trap - RETURN
  rm -f "$tmp"

  have_mtproxyl || { red 'MTProxyL после installer не найден.'; return 1; }
  cyan 'Проверка режима'
  if ! assert_tools_only; then
    yellow 'Фиксы пока НЕ будут применяться. Нужно один раз включить безопасный host-only режим.'
    if yesno 'Открыть полное меню MTProxyL сейчас?' y; then mt menu; fi
    assert_tools_only || return 1
  fi
  set_port
}

update_upstream(){
  require_enter
  have_mtproxyl || { red 'MTProxyL ещё не установлен.'; return 1; }
  cyan 'MTProxyL update-check'
  mt update-check || true
  if yesno 'Обновить MTProxyL из его upstream перед применением фиксов?' y; then
    mt update --no-restart
    green 'MTProxyL обновлён.'
  fi
  assert_tools_only
  set_port
}

set_port(){
  have_mtproxyl || return 1
  mt nft set ZAPRET2_PORT "$PORT" >/dev/null
  green "MTProxyL Zapret2 port = $PORT"
}

apply_zapret2(){
  require_enter
  have_mtproxyl || install_upstream
  assert_tools_only
  if yesno 'Перед применением проверить обновление MTProxyL?' y; then update_upstream; fi
  assert_tools_only
  set_port
  cyan 'MTProxyL Zapret2 MTProto fix'
  mt nft zapret2
}

apply_smart(){
  require_enter
  have_mtproxyl || install_upstream
  assert_tools_only
  if yesno 'Перед применением проверить обновление MTProxyL?' y; then update_upstream; fi
  assert_tools_only
  cyan 'MTProxyL Smart By-MEKO'
  mt nft smart
}

status(){
  require_enter
  show_context
  if ! have_mtproxyl; then yellow 'MTProxyL не установлен.'; return 0; fi
  printf '\nVersion:\n'; mt version || true
  printf '\nMode:\n'; mt mode --json || mt mode || true
  printf '\nUpdate:\n'; mt update-check || true
  printf '\nNFT/Zapret2:\n'; mt nft status --json || mt nft status || true
  printf '\nHAProxy listener:\n'; ss -ltnpH 'sport = :443' || true
  printf '\nMTProxyL services/tables:\n'
  systemctl is-active mtproxyl-zapret2.service 2>/dev/null || true
  nft list table ip MTProtoL 2>/dev/null || true
}

zapret_wscale(){ require_enter; have_mtproxyl || { red 'MTProxyL не установлен.'; return 1; }; assert_tools_only; set_port; mt nft zapret2-wscale; }
remove_zapret2(){ require_enter; have_mtproxyl || { red 'MTProxyL не установлен.'; return 1; }; mt nft zapret2-rm; }
open_upstream_menu(){ require_enter; have_mtproxyl || install_upstream; mt menu; }

menu(){
  require_enter
  while :; do
    show_context
    cat <<'MENU'
1) Установить / обновить официальный MTProxyL
2) Применить / переустановить актуальный Zapret2 MTProto fix
3) Smart By-MEKO (альтернатива Zapret2)
4) Zapret2 wscale / win ACK диагностика
5) Статус MTProxyL / NFT / Zapret2
6) Открыть полное меню MTProxyL
7) Удалить только Zapret2 fix
8) Проверить / установить обновление MTProxyL
9) Выход
MENU
    local c
    c=$(choice '> ' 1 9)
    case "$c" in
      1) install_upstream;;
      2) apply_zapret2;;
      3) apply_smart;;
      4) zapret_wscale;;
      5) status;;
      6) open_upstream_menu;;
      7) remove_zapret2;;
      8) if have_mtproxyl; then update_upstream; else install_upstream; fi;;
      9) return 0;;
    esac
    echo
    read_tty _ 'Enter для продолжения...'
  done
}

case "${1:-menu}" in
  menu) menu;;
  install|update) install_upstream;;
  zapret2) apply_zapret2;;
  smart) apply_smart;;
  wscale) zapret_wscale;;
  status) status;;
  upstream-menu) open_upstream_menu;;
  zapret2-rm|remove) remove_zapret2;;
  *) echo 'Usage: tyxe-mtproxyl [menu|install|update|zapret2|smart|wscale|status|upstream-menu|zapret2-rm]' >&2; exit 2;;
esac
