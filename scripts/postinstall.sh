#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ETC=/etc/proxy-pool
SETTINGS=$ETC/settings.env
STATE=/var/lib/proxy-pool
MANIFEST=$STATE/install-manifest
BACKUP=$STATE/backups

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
getenv_file(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }

[[ $EUID -eq 0 ]] || { red 'Run as root / Запустите через sudo.'; exit 1; }
[[ -r $SETTINGS ]] || { red 'TYXE settings not found / Настройки TYXE не найдены.'; exit 1; }

ROLE=$(getenv_file "$SETTINGS" PROXY_POOL_ROLE)
LANG_CODE=$(getenv_file "$SETTINGS" TYXE_POOL_LANG)
[[ $LANG_CODE =~ ^(ru|en)$ ]] || LANG_CODE=ru
mkdir -p "$STATE" "$BACKUP"
touch "$MANIFEST"

managed_install(){
  local src="$1" dst="$2" mode="${3:-0755}" backup='' id
  [[ -f $src ]] || { red "Missing component: $src"; return 1; }
  if [[ -e $dst || -L $dst ]]; then
    id=$(printf '%s' "$dst" | sed 's#^/##;s#[^A-Za-z0-9._-]#_#g')
    backup="$BACKUP/$id.post.$(date +%s%N)"
    cp -a "$dst" "$backup"
  fi
  printf 'PATH FILE|%s|%s\n' "$dst" "$backup" >> "$MANIFEST"
  install -Dm "$mode" "$src" "$dst"
}

managed_install "$SCRIPT_DIR/tyxe-menu.sh" /usr/local/sbin/tyxe 0755

case "$ROLE" in
  controller)
    managed_install "$SCRIPT_DIR/node-manager.sh" /usr/local/sbin/tyxe-pool-node 0755
    managed_install "$SCRIPT_DIR/awg-pair.sh" /usr/local/sbin/tyxe-awg 0755
    managed_install "$SCRIPT_DIR/dataplane-pair.sh" /usr/local/sbin/tyxe-dataplane 0755
    managed_install "$SCRIPT_DIR/mtproxyl-bridge.sh" /usr/local/sbin/tyxe-mtproxyl 0755
    managed_install "$SCRIPT_DIR/shared443-classifier.sh" /usr/local/sbin/tyxe-shared443 0755
    managed_install "$SCRIPT_DIR/cert-manager.sh" /usr/local/sbin/tyxe-cert 0755
    managed_install "$SCRIPT_DIR/antidpi-zapret2.sh" /usr/local/sbin/tyxe-antidpi-fallback 0755

    # The base installer deliberately starts controller.py first so its own
    # final check remains self-contained. Post-install then switches the same
    # application/UI to the race-safe runtime wrapper.
    managed_install "$SCRIPT_DIR/../controller/runtime.py" /opt/proxy-pool/controller/runtime.py 0755
    managed_install "$SCRIPT_DIR/../systemd/proxy-pool-controller-runtime.conf" /etc/systemd/system/proxy-pool-controller.service.d/10-tyxe-runtime.conf 0644
    systemctl daemon-reload
    systemctl restart proxy-pool-controller
    for _ in $(seq 1 20); do
      curl -fsS --max-time 2 http://127.0.0.1:$(getenv_file "$SETTINGS" PROXY_POOL_PORT)/healthz >/dev/null 2>&1 && break
      sleep 0.25
    done
    systemctl is-active --quiet proxy-pool-controller || { red 'Controller failed after runtime switch.'; exit 1; }
    ;;
  agent)
    managed_install "$SCRIPT_DIR/telemt-manager.sh" /usr/local/sbin/tyxe-telemt 0755
    ;;
  *) red "Unknown role: ${ROLE:-empty}"; exit 1;;
esac

if [[ $LANG_CODE == ru ]]; then
  green 'Компоненты управления TYXE установлены.'
  echo 'Главное меню: sudo tyxe'
  if [[ $ROLE == controller ]]; then
    echo 'Anti-DPI: sudo tyxe -> 5) Anti-DPI / официальный MTProxyL'
    echo 'Selfsteal: sudo tyxe -> 6) Shared TCP/443 / selfsteal classifier'
    echo 'Сертификаты: sudo tyxe-cert status / ensure proxy / ensure panel'
    yellow 'MTProxyL специально НЕ устанавливается автоматически: актуальный upstream скачивается только при выборе пункта Anti-DPI.'
  fi
else
  green 'TYXE management components installed.'
  echo 'Main menu: sudo tyxe'
  if [[ $ROLE == controller ]]; then
    echo 'Anti-DPI: sudo tyxe -> 5) Anti-DPI / official MTProxyL'
    echo 'Selfsteal: sudo tyxe -> 6) Shared TCP/443 / selfsteal classifier'
    echo 'Certificates: sudo tyxe-cert status / ensure proxy / ensure panel'
    yellow 'MTProxyL is intentionally NOT installed automatically: the current upstream is downloaded only when Anti-DPI is selected.'
  fi
fi
