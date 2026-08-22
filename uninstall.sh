#!/usr/bin/env bash
set -Eeuo pipefail

ROLLBACK='/usr/local/sbin/proxy-pool-rollback'
if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

if [[ ! -x "$ROLLBACK" ]]; then
  echo "tyxe_pool rollback engine not found: $ROLLBACK" >&2
  echo 'Nothing was removed.' >&2
  exit 1
fi

case "${1:-}" in
  --dry-run)
    exec "$ROLLBACK" --dry-run --purge-state
    ;;
  '')
    exec "$ROLLBACK" --purge-state
    ;;
  *)
    echo 'Usage: ./uninstall.sh [--dry-run]' >&2
    exit 2
    ;;
esac
