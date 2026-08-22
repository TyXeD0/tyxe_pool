#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/proxy-pool"
MANIFEST="$STATE_DIR/install-manifest"
BACKUP="$STATE_DIR/backups"
DRY=0
PURGE_STATE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --purge-state) PURGE_STATE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say(){ printf '[rollback] %s\n' "$*"; }
run(){ if (( DRY )); then printf '+ %q' "$@"; printf '\n'; else "$@"; fi; }

if [[ ! -f "$MANIFEST" ]]; then
  say "No install manifest found: $MANIFEST"
  exit 1
fi

# Stop services first.
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  say "Stopping/removing service: $svc"
  run systemctl disable --now "$svc" || true
  run rm -f "/etc/systemd/system/$svc.service"
done < <(sed -n 's/^SERVICE //p' "$MANIFEST")
run systemctl daemon-reload

# Remove created paths; restore backups where available.
while IFS='|' read -r typ path backup; do
  [[ -z "$typ" ]] && continue
  case "$typ" in
    FILE|DIR)
      if [[ -n "$backup" && -e "$backup" ]]; then
        say "Restoring $path from $backup"
        run rm -rf "$path"
        run mkdir -p "$(dirname "$path")"
        run cp -a "$backup" "$path"
      else
        say "Removing $path"
        run rm -rf "$path"
      fi
      ;;
  esac
done < <(sed -n 's/^PATH //p' "$MANIFEST")

# Remove packages only if this installer recorded them.
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  say "Removing package installed by installer: $pkg"
  run apt-get remove -y "$pkg" || true
done < <(sed -n 's/^PACKAGE //p' "$MANIFEST")

if (( PURGE_STATE )); then
  say "Removing tyxe_pool state directory: $STATE_DIR"
  run rm -rf "$STATE_DIR"
  say "Rollback complete; installation state purged."
else
  say "Rollback complete. Manifest retained at $MANIFEST for audit."
fi
