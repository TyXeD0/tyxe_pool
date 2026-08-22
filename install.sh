#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='tyxe_pool'
REF="${TYXE_POOL_REF:-main}"
REPO="${TYXE_POOL_REPO:-}"

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
      root) echo 'Установщик нужно запускать от root. Для curl используйте: curl ... | sudo bash -s -- --repo OWNER/tyxe_pool';;
      repo) echo 'Введите GitHub-репозиторий в формате OWNER/tyxe_pool: ';;
      badrepo) echo 'Неверный формат репозитория. Пример: k-real/tyxe_pool';;
      missing) echo 'Не найдена обязательная команда:';;
      downloading) echo 'Загружаю публичный репозиторий';;
      badarchive) echo 'В архиве не найден scripts/install-local.sh.';;
      start) echo 'Запускаю интерактивный установщик TYXE Pool...';;
    esac
  else
    case "$1" in
      root) echo 'Installer must run as root. For curl use: curl ... | sudo bash -s -- --repo OWNER/tyxe_pool';;
      repo) echo 'Enter GitHub repository as OWNER/tyxe_pool: ';;
      badrepo) echo 'Invalid repository format. Example: k-real/tyxe_pool';;
      missing) echo 'Required command not found:';;
      downloading) echo 'Downloading public repository';;
      badarchive) echo 'scripts/install-local.sh was not found in the archive.';;
      start) echo 'Starting the TYXE Pool interactive installer...';;
    esac
  fi
}

# Running from a downloaded/cloned source tree: no bootstrap is needed.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/scripts/install-local.sh" ]]; then
  exec env TYXE_POOL_LANG="$TYXE_POOL_LANG" bash "$SCRIPT_DIR/scripts/install-local.sh" "$@"
fi

[[ $EUID -eq 0 ]] || { red "$(msg root)"; exit 1; }
if [[ -z "$REPO" ]]; then read_tty REPO "$(msg repo)"; fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/tyxe_pool$ ]] || { red "$(msg badrepo)"; exit 1; }
for cmd in curl tar mktemp; do command -v "$cmd" >/dev/null 2>&1 || { red "$(msg missing) $cmd"; exit 1; }; done

TMP="$(mktemp -d /tmp/tyxe_pool.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/repo.tar.gz"
printf '%s %s@%s...\n' "$(msg downloading)" "$REPO" "$REF"
# Public repositories can use the GitHub tarball endpoint anonymously.
curl --fail --silent --show-error --location \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/tarball/$REF" \
  -o "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$TMP"
ROOT_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$ROOT_DIR/scripts/install-local.sh" ]] || { red "$(msg badarchive)"; exit 1; }
green "$(msg start)"
exec env TYXE_POOL_LANG="$TYXE_POOL_LANG" TYXE_POOL_REPO="$REPO" TYXE_POOL_REF="$REF" bash "$ROOT_DIR/scripts/install-local.sh"
