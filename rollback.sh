#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/proxy-pool"
MANIFEST="$STATE_DIR/install-manifest"
DRY=0
PURGE_STATE=0
SINCE_LINE=0
LANG_CODE="${TYXE_POOL_LANG:-en}"

while (($#)); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --purge-state) PURGE_STATE=1 ;;
    --since-line) shift; SINCE_LINE="${1:-0}"; [[ "$SINCE_LINE" =~ ^[0-9]+$ ]] || { echo 'Invalid --since-line value' >&2; exit 2; } ;;
    --lang) shift; LANG_CODE="${1:-en}" ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -r /etc/proxy-pool/settings.env ]]; then
  # shellcheck disable=SC1091
  . /etc/proxy-pool/settings.env || true
  LANG_CODE="${TYXE_POOL_LANG:-$LANG_CODE}"
fi

trm(){
  local k="$1"
  if [[ "$LANG_CODE" == ru ]]; then
    case "$k" in
      no_manifest) echo 'Manifest установки не найден';; svc) echo 'Остановка/восстановление сервиса';;
      restore) echo 'Восстановление';; remove) echo 'Удаление';; pkg) echo 'Удаление пакета, установленного tyxe_pool';;
      user) echo 'Удаление системного пользователя, созданного tyxe_pool';; group) echo 'Удаление системной группы, созданной tyxe_pool';;
      keep_cert) echo 'Сертификаты Let’s Encrypt намеренно не удаляются.';; purge) echo 'Удаление служебного состояния tyxe_pool';;
      done) echo 'Откат завершён.';; audit) echo 'Manifest сохранён для аудита';;
    esac
  else
    case "$k" in
      no_manifest) echo 'Install manifest not found';; svc) echo 'Stopping/restoring service';;
      restore) echo 'Restoring';; remove) echo 'Removing';; pkg) echo 'Removing package installed by tyxe_pool';;
      user) echo 'Removing system user created by tyxe_pool';; group) echo 'Removing system group created by tyxe_pool';;
      keep_cert) echo 'Let’s Encrypt certificates are intentionally preserved.';; purge) echo 'Removing tyxe_pool runtime state';;
      done) echo 'Rollback complete.';; audit) echo 'Manifest retained for audit';;
    esac
  fi
}

say(){ printf '[tyxe rollback] %s\n' "$*"; }
run(){ if (( DRY )); then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }

[[ -f "$MANIFEST" ]] || { say "$(trm no_manifest): $MANIFEST"; exit 1; }
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
if (( SINCE_LINE > 0 )); then tail -n "+$((SINCE_LINE + 1))" "$MANIFEST" > "$TMP"; else cat "$MANIFEST" > "$TMP"; fi

# Stop services first so files can be restored safely.
while IFS= read -r line; do
  [[ "$line" == SERVICE\ * ]] || continue
  payload="${line#SERVICE }"; IFS='|' read -r svc was_enabled was_active <<< "$payload"; [[ -n "$svc" ]] || continue
  say "$(trm svc): $svc"; run systemctl disable --now "$svc" || true
done < <(tac "$TMP")
run systemctl daemon-reload || true

# Restore/remove files and directories in exact reverse order.
while IFS= read -r line; do
  [[ "$line" == PATH\ * ]] || continue
  payload="${line#PATH }"; IFS='|' read -r typ path backup <<< "$payload"; [[ -n "$path" ]] || continue
  case "$typ" in
    FILE|DIR)
      if [[ -n "${backup:-}" && ( -e "$backup" || -L "$backup" ) ]]; then
        say "$(trm restore) $path <- $backup"; run rm -rf "$path"; run mkdir -p "$(dirname "$path")"; run cp -a "$backup" "$path"
      else
        say "$(trm remove) $path"; run rm -rf "$path"
      fi
      ;;
  esac
done < <(tac "$TMP")

# Remove OS identities only when the installer explicitly recorded that it created them.
# USER is processed before GROUP so the group is not still referenced by that account.
while IFS= read -r line; do
  [[ "$line" == USER\ * ]] || continue
  u="${line#USER }"; [[ -n "$u" ]] || continue
  if getent passwd "$u" >/dev/null 2>&1; then say "$(trm user): $u"; run userdel "$u" || true; fi
done < <(tac "$TMP")
while IFS= read -r line; do
  [[ "$line" == GROUP\ * ]] || continue
  g="${line#GROUP }"; [[ -n "$g" ]] || continue
  if getent group "$g" >/dev/null 2>&1; then say "$(trm group): $g"; run groupdel "$g" || true; fi
done < <(tac "$TMP")

# Restore prior service enabled/active state after unit/config files are restored.
while IFS= read -r line; do
  [[ "$line" == SERVICE\ * ]] || continue
  payload="${line#SERVICE }"; IFS='|' read -r svc was_enabled was_active <<< "$payload"; [[ -n "$svc" ]] || continue
  case "${was_enabled:-disabled}" in enabled|enabled-runtime|static|indirect|generated) run systemctl enable "$svc" >/dev/null 2>&1 || true;; *) run systemctl disable "$svc" >/dev/null 2>&1 || true;; esac
  [[ "${was_active:-inactive}" == active ]] && run systemctl start "$svc" || run systemctl stop "$svc" || true
done < <(tac "$TMP")

while IFS= read -r line; do
  [[ "$line" == PACKAGE\ * ]] || continue
  pkg="${line#PACKAGE }"; [[ -n "$pkg" ]] || continue
  say "$(trm pkg): $pkg"; run apt-get remove -y "$pkg" || true
done < <(tac "$TMP")

command -v nginx >/dev/null 2>&1 && { run nginx -t >/dev/null 2>&1 && run systemctl reload nginx || true; }
run systemctl daemon-reload || true
say "$(trm keep_cert)"

if (( SINCE_LINE > 0 )); then
  if (( ! DRY )); then head -n "$SINCE_LINE" "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST"; fi
  say "$(trm done)"; exit 0
fi
if (( PURGE_STATE )); then say "$(trm purge): $STATE_DIR"; run rm -rf "$STATE_DIR"; else say "$(trm audit): $MANIFEST"; fi
say "$(trm done)"
