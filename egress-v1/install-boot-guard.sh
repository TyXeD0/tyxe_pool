#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/boot-guard.sh"
DST="/usr/local/libexec/mtproxyl-egress-boot-guard"
UNIT="/etc/systemd/system/mtproxyl-egress-boot-guard.service"
DROPIN_DIR="/etc/systemd/system/docker.service.d"
DROPIN="$DROPIN_DIR/10-mtproxyl-egress-boot-guard.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mtproxyl-egress-boot-guard-backup-$STAMP"

fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."
[[ -f "$SRC" ]] || fail "Missing $SRC"
[[ -f /etc/mtproxyl-egress/config.toml ]] || fail "Missing egress config"
[[ -x /usr/local/libexec/mtproxyl-egressd ]] || fail "Missing egress daemon"

for c in bash systemctl install ip nft python3; do
  command -v "$c" >/dev/null 2>&1 || fail "Missing command: $c"
done

bash -n "$SRC"
python3 -m py_compile /usr/local/libexec/mtproxyl-egressd

mkdir -p "$BACKUP"
cp -a "$DST" "$BACKUP/" 2>/dev/null || true
cp -a "$UNIT" "$BACKUP/" 2>/dev/null || true
cp -a "$DROPIN" "$BACKUP/" 2>/dev/null || true

install -d -m 755 /usr/local/libexec
install -o root -g root -m 755 "$SRC" "$DST"

cat >"$UNIT" <<'UNIT'
[Unit]
Description=MTProxyL Egress pre-Docker fail-closed boot guard
Documentation=https://github.com/TyXeD0/tyxe_pool
After=local-fs.target
Before=docker.service mtproxyl-egressd.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/mtproxyl-egress-boot-guard
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

install -d -m 755 "$DROPIN_DIR"
cat >"$DROPIN" <<'DROPIN'
[Unit]
Requires=mtproxyl-egress-boot-guard.service
After=mtproxyl-egress-boot-guard.service
DROPIN

systemctl daemon-reload
systemctl enable mtproxyl-egress-boot-guard.service >/dev/null

# Do NOT start the guard now: its job is to force BLOCK during boot before
# Docker, and starting it on a live host would intentionally interrupt Telegram.
[[ "$(systemctl is-enabled mtproxyl-egress-boot-guard.service)" == "enabled" ]] || fail "guard not enabled"

cat >"$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl disable mtproxyl-egress-boot-guard.service >/dev/null 2>&1 || true
rm -f "$UNIT" "$DROPIN"
if [[ -f "$BACKUP/$(basename "$DST")" ]]; then
  install -m 755 "$BACKUP/$(basename "$DST")" "$DST"
else
  rm -f "$DST"
fi
if [[ -f "$BACKUP/$(basename "$UNIT")" ]]; then
  cp -a "$BACKUP/$(basename "$UNIT")" "$UNIT"
fi
if [[ -f "$BACKUP/$(basename "$DROPIN")" ]]; then
  install -d -m 755 "$DROPIN_DIR"
  cp -a "$BACKUP/$(basename "$DROPIN")" "$DROPIN"
fi
systemctl daemon-reload
echo "Boot guard rollback complete. No live routing rule was changed."
EOF
chmod 700 "$BACKUP/rollback.sh"
ln -sfn "$BACKUP/rollback.sh" /root/rollback-mtproxyl-egress-boot-guard.sh

echo
echo "===== BOOT GUARD INSTALLED ====="
echo "Guard:   $(systemctl is-enabled mtproxyl-egress-boot-guard.service)"
echo "Docker requires guard:"
systemctl cat docker.service | grep -A3 -B1 'mtproxyl-egress-boot-guard' || true
echo
echo "Current production route was NOT changed:"
ip route get 149.154.167.51 mark 0x200000 || true
echo
echo "Rollback: /root/rollback-mtproxyl-egress-boot-guard.sh"
