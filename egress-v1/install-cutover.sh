#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DAEMON_SRC="$ROOT/egressd.py"
CLI_SRC="$ROOT/cli.py"
BRIDGE_SRC="$ROOT/bridge-dynamic.sh"

DAEMON_DST="/usr/local/libexec/mtproxyl-egressd"
CLI_DST="/usr/local/bin/mtproxyl-egress"
BRIDGE_DST="/usr/local/sbin/mtproxyl-egress-panel-bridge"
UNIT_DST="/etc/systemd/system/mtproxyl-egressd.service"

LEGACY_MANAGER="mtproxyl-egress-manager.service"
LEGACY_ROUTE="mtproxyl-egress-route.service"
LEGACY_SYNC_TIMER="mtproxyl-egress-telemt-sync.timer"
LEGACY_SYNC_SERVICE="mtproxyl-egress-telemt-sync.service"
PANEL_SERVICE="mtproxyl-panel.service"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mtproxyl-egressd-cutover-$STAMP"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
fail(){ red "ERROR: $*"; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."

for cmd in python3 systemctl ip nft awg docker mtproxyl curl sudo; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Не найдена команда: $cmd"
done

for f in "$DAEMON_SRC" "$CLI_SRC" "$BRIDGE_SRC"; do
    [[ -f "$f" ]] || fail "Не найден файл: $f"
done

[[ -f /etc/mtproxyl-egress/config.toml ]] || fail "Сначала нужна registry migration."
[[ -x /usr/local/libexec/mtproxyl-egress-registry ]] || fail "Registry tool missing."

echo
echo "============================================================"
echo " MTProxyL Dynamic Egress v1 — production cutover"
echo "============================================================"
echo

echo "===== PRE-FLIGHT ====="

/usr/local/libexec/mtproxyl-egress-registry validate
mtproxyl version
/usr/local/bin/mtproxyl-panel version || true

# Idempotent re-run: a successful earlier cutover intentionally leaves all
# legacy control services disabled. Treat that as success after validating
# the live dynamic daemon instead of demanding the legacy manager again.
if systemctl is-active --quiet mtproxyl-egressd.service; then
    echo "Dynamic egressd: already active"
    systemctl is-enabled --quiet mtproxyl-egressd.service \
        || fail "Dynamic egressd is active but not enabled."

    [[ -x "$CLI_DST" ]] || fail "Dynamic CLI is missing: $CLI_DST"
    "$CLI_DST" status --json | python3 -m json.tool >/dev/null \
        || fail "Dynamic egress status is not valid JSON."

    LIVE_ROUTE="$(ip route get 149.154.167.51 mark 0x200000)"
    LIVE_DEV="$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$LIVE_ROUTE")"
    [[ -n "$LIVE_DEV" ]] || fail "Cannot determine current dynamic egress device."

    if systemctl is-active --quiet "$LEGACY_MANAGER" || \
       systemctl is-active --quiet "$LEGACY_ROUTE" || \
       systemctl is-active --quiet "$LEGACY_SYNC_TIMER"; then
        fail "Dynamic egressd and a legacy control service are active at the same time."
    fi

    printf "Panel: "
    systemctl is-active "$PANEL_SERVICE" || true
    echo "Current route: $LIVE_ROUTE"
    echo
    "$CLI_DST" status | sed -n '1,35p'
    echo
    green "DYNAMIC CUTOVER ALREADY COMPLETE"
    exit 0
fi

systemctl is-active --quiet "$LEGACY_MANAGER" \
    || fail "Neither dynamic egressd nor the legacy manager is active. Restore the legacy manager or use the rollback script before cutover."

OLD_ROUTE="$(ip route get 149.154.167.51 mark 0x200000)"
OLD_DEV="$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$OLD_ROUTE")"

[[ -n "$OLD_DEV" ]] || fail "Cannot determine current egress device."

echo "Legacy manager: active"
echo "Current route: $OLD_ROUTE"

echo
echo "===== BACKUP ====="

install -d -m 700 "$BACKUP"

cp -a /etc/mtproxyl-egress "$BACKUP/etc-mtproxyl-egress"
cp -a /var/lib/mtproxyl-egress "$BACKUP/var-lib-mtproxyl-egress"

cp -a "$CLI_DST" "$BACKUP/mtproxyl-egress" 2>/dev/null || true
cp -a "$BRIDGE_DST" "$BACKUP/mtproxyl-egress-panel-bridge" 2>/dev/null || true
cp -a "$DAEMON_DST" "$BACKUP/mtproxyl-egressd" 2>/dev/null || true
cp -a "$UNIT_DST" "$BACKUP/mtproxyl-egressd.service" 2>/dev/null || true

for unit in \
    "$LEGACY_MANAGER" \
    "$LEGACY_ROUTE" \
    "$LEGACY_SYNC_TIMER" \
    "$LEGACY_SYNC_SERVICE" \
    "$PANEL_SERVICE"
do
    {
        echo "active=$(systemctl is-active "$unit" 2>/dev/null || true)"
        echo "enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    } >"$BACKUP/$unit.state"
    cp -a "/etc/systemd/system/$unit" "$BACKUP/" 2>/dev/null || true
done

TELEMT_CONFIG="$(
python3 - <<'PY'
import tomllib
with open("/etc/mtproxyl-egress/config.toml","rb") as f:
    d=tomllib.load(f)
print(d.get("telemt",{}).get("config",""))
PY
)"

[[ -f "$TELEMT_CONFIG" ]] || fail "Telemt config not found: $TELEMT_CONFIG"
cp -a "$TELEMT_CONFIG" "$BACKUP/telemt-config.toml"

echo "Backup:"
echo "  $BACKUP"

echo
echo "===== INSTALL FILES (NOT ACTIVE YET) ====="

install -d -m 755 /usr/local/libexec
install -m 755 "$DAEMON_SRC" "$DAEMON_DST"
install -m 755 "$CLI_SRC" "$CLI_DST.new"
install -m 755 "$BRIDGE_SRC" "$BRIDGE_DST.new"

python3 -m py_compile "$DAEMON_DST"
python3 -m py_compile "$CLI_DST.new"

echo
echo "===== CUTOVER PROBE ====="

"$DAEMON_DST" --probe-only

echo
echo "===== SYSTEMD UNIT ====="

cat >"$UNIT_DST" <<'UNIT'
[Unit]
Description=MTProxyL Dynamic Egress Manager
Documentation=https://github.com/TyXeD0/tyxe_pool
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
ExecStartPre=/usr/local/libexec/mtproxyl-egress-registry validate
ExecStart=/usr/local/libexec/mtproxyl-egressd
Restart=always
RestartSec=2
TimeoutStopSec=20
KillSignal=SIGTERM
UMask=0077
LimitNOFILE=65536
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

CUTOVER_ACTIVE=0

rollback_now(){
    local original_rc="${1:-1}"
    CUTOVER_ACTIVE=0
    set +e
    red "Cutover failed. Restoring legacy production manager..."

    systemctl disable --now mtproxyl-egressd.service >/dev/null 2>&1 || true

    if [[ -f "$BACKUP/mtproxyl-egress" ]]; then
        install -m 755 "$BACKUP/mtproxyl-egress" "$CLI_DST"
    fi

    if [[ -f "$BACKUP/mtproxyl-egress-panel-bridge" ]]; then
        install -m 755 "$BACKUP/mtproxyl-egress-panel-bridge" "$BRIDGE_DST"
    fi

    rm -f "$CLI_DST.new" "$BRIDGE_DST.new"

    rm -rf /etc/mtproxyl-egress
    cp -a "$BACKUP/etc-mtproxyl-egress" /etc/mtproxyl-egress

    rm -rf /var/lib/mtproxyl-egress
    cp -a "$BACKUP/var-lib-mtproxyl-egress" /var/lib/mtproxyl-egress

    cp -a "$BACKUP/telemt-config.toml" "$TELEMT_CONFIG"

    systemctl daemon-reload

    systemctl enable "$LEGACY_ROUTE" >/dev/null 2>&1 || true
    systemctl start "$LEGACY_ROUTE" >/dev/null 2>&1 || true
    systemctl enable "$LEGACY_MANAGER" >/dev/null 2>&1 || true
    systemctl restart "$LEGACY_MANAGER" >/dev/null 2>&1 || true

    if grep -q '^active=active$' "$BACKUP/$LEGACY_SYNC_TIMER.state" 2>/dev/null; then
        systemctl enable --now "$LEGACY_SYNC_TIMER" >/dev/null 2>&1 || true
    fi

    if grep -q '^active=active$' "$BACKUP/$PANEL_SERVICE.state" 2>/dev/null; then
        systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
    fi

    sleep 3
    /usr/local/bin/mtproxyl-egress status 2>/dev/null || true
    exit "$original_rc"
}

on_exit(){
    local rc=$?
    if (( rc != 0 && CUTOVER_ACTIVE == 1 )); then
        rollback_now "$rc"
    fi
    exit "$rc"
}
trap on_exit EXIT

CUTOVER_ACTIVE=1

echo
echo "===== STOP PANEL CONTROL PATH ====="
systemctl stop "$PANEL_SERVICE" 2>/dev/null || true

echo
echo "===== STOP LEGACY CONTROL SERVICES ====="

systemctl disable --now "$LEGACY_SYNC_TIMER" 2>/dev/null || true
systemctl stop "$LEGACY_SYNC_SERVICE" 2>/dev/null || true
systemctl disable --now "$LEGACY_MANAGER"
systemctl disable --now "$LEGACY_ROUTE" 2>/dev/null || true

mv -f "$CLI_DST.new" "$CLI_DST"
mv -f "$BRIDGE_DST.new" "$BRIDGE_DST"
chmod 755 "$CLI_DST" "$BRIDGE_DST"

systemctl enable --now mtproxyl-egressd.service

for _ in $(seq 1 20); do
    systemctl is-active --quiet mtproxyl-egressd.service && break
    sleep 1
done
systemctl is-active --quiet mtproxyl-egressd.service || fail "Dynamic egressd failed to start."

# Wait for a fully populated live status.
for _ in $(seq 1 30); do
    if "$CLI_DST" status --json 2>/dev/null | python3 -c '
import json,sys
try:d=json.load(sys.stdin)
except Exception:raise SystemExit(1)
raise SystemExit(0 if d.get("phase")=="running" and d.get("nodes") else 1)
'; then
        break
    fi
    sleep 1
done

"$CLI_DST" status --json | python3 -m json.tool >/dev/null \
    || fail "Dynamic status JSON validation failed."

systemctl restart "$PANEL_SERVICE" 2>/dev/null || true

sleep 2

echo
echo "===== POST-CUTOVER VERIFY ====="

NEW_ROUTE="$(ip route get 149.154.167.51 mark 0x200000)"
NEW_DEV="$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$NEW_ROUTE")"
[[ -n "$NEW_DEV" ]] || fail "Cannot determine dynamic egress device."

"$CLI_DST" status

echo
echo "Old dev: $OLD_DEV"
echo "New dev: $NEW_DEV"
echo "Route:   $NEW_ROUTE"

systemctl is-active --quiet "$PANEL_SERVICE" \
    || fail "Panel did not recover after cutover."

# Validate Telemt DC health; the daemon may briefly be warming writers.
DC_OK=0
for _ in $(seq 1 20); do
    if mtproxyl dc status --json 2>/dev/null | python3 -c '
import json,sys
try:d=json.load(sys.stdin)
except Exception:raise SystemExit(1)
coverage=int(d.get("coverage_pct") or 0)
alive=int(d.get("alive_writers") or 0)
raise SystemExit(0 if coverage >= 80 and alive > 0 else 1)
'; then
        DC_OK=1
        break
    fi
    sleep 3
done
(( DC_OK == 1 )) || fail "Telemt DC writers did not become healthy after cutover."

if systemctl is-active --quiet "$LEGACY_MANAGER" || \
   systemctl is-active --quiet "$LEGACY_ROUTE" || \
   systemctl is-active --quiet "$LEGACY_SYNC_TIMER"; then
    fail "A legacy control service is still active after dynamic cutover."
fi

cat >/root/rollback-mtproxyl-egressd-cutover.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP="$BACKUP"
TELEMT_CONFIG="$TELEMT_CONFIG"

systemctl disable --now mtproxyl-egressd.service 2>/dev/null || true

if [[ -f "\$BACKUP/mtproxyl-egress" ]]; then
    install -m 755 "\$BACKUP/mtproxyl-egress" "$CLI_DST"
fi
if [[ -f "\$BACKUP/mtproxyl-egress-panel-bridge" ]]; then
    install -m 755 "\$BACKUP/mtproxyl-egress-panel-bridge" "$BRIDGE_DST"
fi

rm -rf /etc/mtproxyl-egress
cp -a "\$BACKUP/etc-mtproxyl-egress" /etc/mtproxyl-egress
rm -rf /var/lib/mtproxyl-egress
cp -a "\$BACKUP/var-lib-mtproxyl-egress" /var/lib/mtproxyl-egress
cp -a "\$BACKUP/telemt-config.toml" "\$TELEMT_CONFIG"

systemctl daemon-reload
systemctl enable "$LEGACY_ROUTE" >/dev/null 2>&1 || true
systemctl start "$LEGACY_ROUTE" >/dev/null 2>&1 || true
systemctl enable "$LEGACY_MANAGER" >/dev/null 2>&1 || true
systemctl restart "$LEGACY_MANAGER"

if grep -q '^active=active$' "\$BACKUP/$LEGACY_SYNC_TIMER.state" 2>/dev/null; then
    systemctl enable --now "$LEGACY_SYNC_TIMER" >/dev/null 2>&1 || true
fi

systemctl restart "$PANEL_SERVICE" 2>/dev/null || true
sleep 3
/usr/local/bin/mtproxyl-egress status
EOF
chmod 700 /root/rollback-mtproxyl-egressd-cutover.sh

CUTOVER_ACTIVE=0
trap - EXIT

echo
echo "============================================================"
green " DYNAMIC CUTOVER COMPLETE"
echo "============================================================"
printf "Daemon:         "; systemctl is-active mtproxyl-egressd.service
printf "Legacy manager: "; systemctl is-active "$LEGACY_MANAGER" || true
printf "Legacy route:   "; systemctl is-active "$LEGACY_ROUTE" || true
printf "Panel:          "; systemctl is-active "$PANEL_SERVICE" || true
echo
echo "Rollback:"
echo "  /root/rollback-mtproxyl-egressd-cutover.sh"
echo "============================================================"
