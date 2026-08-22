#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='tyxe_pool'
REF="${TYXE_POOL_REF:-main}"
REPO="${TYXE_POOL_REPO:-}"
BOOTSTRAP_HASH=/etc/nginx/conf.d/00-tyxe-server-name-hash.conf
BOOTSTRAP_HASH_CREATED=0

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
read_tty(){ local __var="$1" __prompt="$2" value=''; read -r -p "$__prompt" value </dev/tty || true; printf -v "$__var" '%s' "$value"; }

while (($#)); do
  case "$1" in
    --repo) shift; REPO="${1:-}" ;;
    --ref) shift; REF="${1:-main}" ;;
    *) red "Unknown option / Неизвестный параметр: $1"; exit 2 ;;
  esac
  shift
done

choose_language(){
  if [[ "${TYXE_POOL_LANG:-}" =~ ^(ru|en)$ ]]; then return; fi
  printf '\nTYXE Pool / Выбор языка\n1) Русский\n2) English\n'
  local v=''
  while :; do
    read_tty v '> '
    case "$v" in 1) TYXE_POOL_LANG=ru; break;; 2) TYXE_POOL_LANG=en; break;; *) printf '1 / 2\n';; esac
  done
  export TYXE_POOL_LANG
}
choose_language

msg(){
  if [[ "$TYXE_POOL_LANG" == ru ]]; then
    case "$1" in
      root) echo 'Установщик нужно запускать от root. Для curl используйте sudo bash.';;
      repo) echo 'Введите GitHub-репозиторий в формате OWNER/tyxe_pool: ';;
      badrepo) echo 'Неверный формат репозитория. Пример: TyXeD0/tyxe_pool';;
      missing) echo 'Не найдена обязательная команда:';;
      downloading) echo 'Загружаю публичный репозиторий';;
      badarchive) echo 'В архиве не найден установщик TYXE Pool.';;
      start) echo 'Запускаю интерактивный установщик TYXE Pool...';;
    esac
  else
    case "$1" in
      root) echo 'Installer must run as root. Use sudo bash for curl installs.';;
      repo) echo 'Enter GitHub repository as OWNER/tyxe_pool: ';;
      badrepo) echo 'Invalid repository format. Example: TyXeD0/tyxe_pool';;
      missing) echo 'Required command not found:';;
      downloading) echo 'Downloading public repository';;
      badarchive) echo 'TYXE Pool installer was not found in the archive.';;
      start) echo 'Starting the TYXE Pool interactive installer...';;
    esac
  fi
}

[[ $EUID -eq 0 ]] || { red "$(msg root)"; exit 1; }

pick_installer(){
  local root="$1"
  if [[ -f "$root/scripts/install-v0.3.sh" ]]; then printf '%s' "$root/scripts/install-v0.3.sh"; return 0; fi
  if [[ -f "$root/scripts/install-local.sh" ]]; then printf '%s' "$root/scripts/install-local.sh"; return 0; fi
  return 1
}

prepare_nginx_hash_bootstrap(){
  [[ -e $BOOTSTRAP_HASH ]] && return 0
  install -d -m 755 "$(dirname "$BOOTSTRAP_HASH")"
  printf '%s\n' 'server_names_hash_bucket_size 64;' > "$BOOTSTRAP_HASH"
  chmod 0644 "$BOOTSTRAP_HASH"
  BOOTSTRAP_HASH_CREATED=1
}

cleanup_nginx_hash_bootstrap(){
  if (( BOOTSTRAP_HASH_CREATED )) && [[ -f $BOOTSTRAP_HASH ]] && \
     grep -Fqx 'server_names_hash_bucket_size 64;' "$BOOTSTRAP_HASH"; then
    rm -f "$BOOTSTRAP_HASH"
    rmdir /etc/nginx/conf.d 2>/dev/null || true
    rmdir /etc/nginx 2>/dev/null || true
  fi
}

run_postinstall(){
  local root="$1" post="$1/scripts/postinstall.sh"
  [[ -f "$post" ]] || return 0
  env \
    TYXE_POOL_LANG="$TYXE_POOL_LANG" \
    TYXE_POOL_REPO="${REPO:-}" \
    TYXE_POOL_REF="$REF" \
    TYXE_BOOTSTRAP_HASH_CREATED="$BOOTSTRAP_HASH_CREATED" \
    bash "$post"
}

run_installer(){
  local root="$1" installer="$2" rc=0
  prepare_nginx_hash_bootstrap
  if env TYXE_POOL_LANG="$TYXE_POOL_LANG" TYXE_POOL_REPO="${REPO:-}" TYXE_POOL_REF="$REF" bash "$installer"; then
    :
  else
    rc=$?
    cleanup_nginx_hash_bootstrap
    return "$rc"
  fi
  run_postinstall "$root"
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" ]]; then
  LOCAL_INSTALLER="$(pick_installer "$SCRIPT_DIR" || true)"
  if [[ -n "$LOCAL_INSTALLER" ]]; then
    run_installer "$SCRIPT_DIR" "$LOCAL_INSTALLER"
    exit 0
  fi
fi

if [[ -z "$REPO" ]]; then read_tty REPO "$(msg repo)"; fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/tyxe_pool$ ]] || { red "$(msg badrepo)"; exit 1; }
for cmd in curl tar mktemp; do command -v "$cmd" >/dev/null 2>&1 || { red "$(msg missing) $cmd"; exit 1; }; done

TMP="$(mktemp -d /tmp/tyxe_pool.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/repo.tar.gz"
printf '%s %s@%s...\n' "$(msg downloading)" "$REPO" "$REF"
curl --fail --silent --show-error --location \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/tarball/$REF" \
  -o "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$TMP"
ROOT_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -n1)"
REMOTE_INSTALLER="$(pick_installer "$ROOT_DIR" || true)"
[[ -n "$REMOTE_INSTALLER" ]] || { red "$(msg badarchive)"; exit 1; }
green "$(msg start)"
run_installer "$ROOT_DIR" "$REMOTE_INSTALLER"
