#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT='tyxe_pool'
REF="${TYXE_POOL_REF:-main}"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

# Normal path: repository was cloned/downloaded first.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/scripts/install-local.sh" ]]; then
  exec bash "$SCRIPT_DIR/scripts/install-local.sh" "$@"
fi

# Bootstrap path: install.sh itself was fetched from a private GitHub repo.
[[ $EUID -eq 0 ]] || {
  red 'Remote bootstrap must be run as root (or through sudo preserving GITHUB_TOKEN).'
  exit 1
}

REPO="${TYXE_POOL_REPO:-}"
if [[ -z "$REPO" ]]; then
  if [[ -r /dev/tty ]]; then
    read -r -p 'GitHub repository [owner/tyxe_pool]: ' REPO </dev/tty
  fi
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/tyxe_pool$ ]] || {
  red 'Set TYXE_POOL_REPO to owner/tyxe_pool.'
  exit 1
}

TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$TOKEN" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" && -r /dev/tty ]]; then
  read -r -s -p 'GitHub token with read access to tyxe_pool: ' TOKEN </dev/tty
  printf '\n' >/dev/tty
fi
[[ -n "$TOKEN" ]] || {
  red 'Private repository authentication is required. Set GITHUB_TOKEN or authenticate with gh.'
  exit 1
}

for cmd in curl tar mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Required command not found: $cmd"; exit 1; }
done

TMP="$(mktemp -d /tmp/tyxe_pool.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/repo.tar.gz"

printf 'Downloading %s@%s...\n' "$REPO" "$REF"
curl --fail --silent --show-error --location \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/tarball/$REF" \
  -o "$ARCHIVE"

tar -xzf "$ARCHIVE" -C "$TMP"
ROOT_DIR="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$ROOT_DIR/scripts/install-local.sh" ]] || {
  red 'Downloaded repository does not contain scripts/install-local.sh.'
  exit 1
}

green "Starting $PROJECT installer from private GitHub repository..."
exec bash "$ROOT_DIR/scripts/install-local.sh" "$@"
