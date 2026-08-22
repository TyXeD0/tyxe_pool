#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='tyxe_pool'
REF="${TYXE_POOL_REF:-main}"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
read_tty(){ local __var="$1" __prompt="$2" __silent="${3:-0}" value=''; if [[ "$__silent" == 1 ]]; then read -r -s -p "$__prompt" value </dev/tty || true; printf '\n' >/dev/tty; else read -r -p "$__prompt" value </dev/tty || true; fi; printf -v "$__var" '%s' "$value"; }

choose_language(){
  if [[ "${TYXE_POOL_LANG:-}" =~ ^(ru|en)$ ]]; then return; fi
  printf '\nTYXE Pool / Выбор языка\n'
  printf '1) Русский\n2) English\n'
  local v=''
  while :; do
    read_tty v '> '
    case "$v" in 1) TYXE_POOL_LANG=ru; break;; 2) TYXE_POOL_LANG=en; break;; *) printf '1 / 2\n';; esac
  done
  export TYXE_POOL_LANG
}

choose_language

msg(){
  local key="$1"
  if [[ "$TYXE_POOL_LANG" == ru ]]; then
    case "$key" in
      root) echo 'Удалённый bootstrap нужно запускать от root или через sudo с сохранением переменных окружения.';;
      repo) echo 'GitHub-репозиторий [owner/tyxe_pool]: ';;
      badrepo) echo 'Укажите TYXE_POOL_REPO в формате owner/tyxe_pool.';;
      token) echo 'GitHub token с правом чтения tyxe_pool: ';;
      auth) echo 'Для приватного репозитория нужна авторизация. Укажите GITHUB_TOKEN или выполните gh auth login.';;
      missing) echo 'Не найдена обязательная команда:';;
      downloading) echo 'Загрузка приватного репозитория';;
      badarchive) echo 'В загруженном репозитории отсутствует scripts/install-local.sh.';;
      start) echo 'Запускаю интерактивный установщик tyxe_pool из приватного GitHub...';;
    esac
  else
    case "$key" in
      root) echo 'Remote bootstrap must be run as root or through sudo while preserving environment variables.';;
      repo) echo 'GitHub repository [owner/tyxe_pool]: ';;
      badrepo) echo 'Set TYXE_POOL_REPO in owner/tyxe_pool format.';;
      token) echo 'GitHub token with read access to tyxe_pool: ';;
      auth) echo 'Private repository authentication is required. Set GITHUB_TOKEN or run gh auth login.';;
      missing) echo 'Required command not found:';;
      downloading) echo 'Downloading private repository';;
      badarchive) echo 'Downloaded repository does not contain scripts/install-local.sh.';;
      start) echo 'Starting the interactive tyxe_pool installer from private GitHub...';;
    esac
  fi
}

# Normal path: repository was cloned/downloaded first.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/scripts/install-local.sh" ]]; then
  exec env TYXE_POOL_LANG="$TYXE_POOL_LANG" bash "$SCRIPT_DIR/scripts/install-local.sh" "$@"
fi

[[ $EUID -eq 0 ]] || { red "$(msg root)"; exit 1; }

REPO="${TYXE_POOL_REPO:-}"
if [[ -z "$REPO" ]]; then
  read_tty REPO "$(msg repo)"
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/tyxe_pool$ ]] || { red "$(msg badrepo)"; exit 1; }

TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  read_tty TOKEN "$(msg token)" 1
fi
[[ -n "$TOKEN" ]] || { red "$(msg auth)"; exit 1; }

for cmd in curl tar mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { red "$(msg missing) $cmd"; exit 1; }
done

TMP="$(mktemp -d /tmp/tyxe_pool.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/repo.tar.gz"
printf '%s %s@%s...\n' "$(msg downloading)" "$REPO" "$REF"
curl --fail --silent --show-error --location \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/tarball/$REF" \
  -o "$ARCHIVE"

tar -xzf "$ARCHIVE" -C "$TMP"
ROOT_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$ROOT_DIR/scripts/install-local.sh" ]] || { red "$(msg badarchive)"; exit 1; }

green "$(msg start)"
exec env TYXE_POOL_LANG="$TYXE_POOL_LANG" bash "$ROOT_DIR/scripts/install-local.sh" "$@"
