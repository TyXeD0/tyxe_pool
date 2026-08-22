#!/usr/bin/env bash
set -Eeuo pipefail

BASE_COMMIT="8e6ef1d598a2d4f3af2b4a81ac028b0f9ae7afe5"
CUSTOM_VERSION="1.0.14-egress1"
UPSTREAM="https://github.com/Liafanx/MTProxyL.git"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="/opt/mtproxyl-panel-egress-build"
SRC="$WORK/MTProxyL"
PANEL_SRC="$SRC/mtproxyl-panel"
PANEL_BIN="/usr/local/bin/mtproxyl-panel"
PANEL_CFG="/etc/mtproxyl-panel/config.toml"
PANEL_SERVICE="mtproxyl-panel.service"
BRIDGE="/usr/local/sbin/mtproxyl-egress-panel-bridge"
SUDOERS="/etc/sudoers.d/mtproxyl-panel-egress"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mtproxyl-panel-egress-backup-$STAMP"

fail() { echo; echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."

for c in git docker python3 sudo visudo systemctl install curl; do
    command -v "$c" >/dev/null 2>&1 || fail "Не найдена команда: $c"
done

[[ -x "$PANEL_BIN" ]] || fail "Не найден $PANEL_BIN"
[[ -f "$PANEL_CFG" ]] || fail "Не найден $PANEL_CFG"
[[ -x /usr/local/bin/mtproxyl-egress ]] || fail "Не найден mtproxyl-egress"
id mtproxyl-panel >/dev/null 2>&1 || fail "Нет пользователя mtproxyl-panel"

CURRENT_PANEL="$($PANEL_BIN version 2>/dev/null || true)"

echo
echo "============================================================"
echo " MTProxyL Panel Egress UI"
echo "============================================================"
echo "Current: $CURRENT_PANEL"
echo "Target:  mtproxyl-panel $CUSTOM_VERSION"
echo

case "$CURRENT_PANEL" in
    *"1.0.14"*|*"-egress"*) ;;
    *) fail "Ожидалась Panel 1.0.14. Сначала обнови официальный baseline." ;;
esac

# Egress pre-flight.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
/usr/local/bin/mtproxyl-egress status --json >"$TMP"
python3 - "$TMP" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
nodes = {n.get("id"): n for n in d.get("nodes", [])}
for name in ("pl1", "pl2"):
    if name not in nodes:
        raise SystemExit(f"missing node: {name}")
print("Egress:", d.get("mode"), "active=", d.get("active_node"))
for name in ("pl1", "pl2"):
    n = nodes[name]
    print(name.upper(), "health=", n.get("health"), "agent=", (n.get("agent") or {}).get("reachable"))
PY
rm -f "$TMP"
trap - EXIT

# Backup panel only. AWG/routing/manager/node-agents are not modified.
echo
echo "===== BACKUP ====="
install -d -m 700 "$BACKUP"
cp -a "$PANEL_BIN" "$BACKUP/mtproxyl-panel"
cp -a "$PANEL_CFG" "$BACKUP/config.toml"
cp -a "/etc/systemd/system/$PANEL_SERVICE" "$BACKUP/" 2>/dev/null || true
cp -a "$BRIDGE" "$BACKUP/" 2>/dev/null || true
cp -a "$SUDOERS" "$BACKUP/" 2>/dev/null || true
printf '%s\n' "$CURRENT_PANEL" >"$BACKUP/version.txt"
echo "Backup: $BACKUP"

# Exact upstream Panel 1.0.14 source.
echo
echo "===== FETCH SOURCE ====="
rm -rf "$WORK"
install -d -m 755 "$WORK"
git clone --filter=blob:none --no-checkout "$UPSTREAM" "$SRC"
git -C "$SRC" checkout "$BASE_COMMIT"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$BASE_COMMIT" ]] || fail "Upstream commit mismatch"

# Apply maintained Egress patch files from this repository.
echo
echo "===== PATCH SOURCE ====="
python3 "$SELF_DIR/patch.py" "$PANEL_SRC" "$SELF_DIR"

# Build upstream frontend + static Go panel.
echo
echo "===== BUILD ====="
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Неподдерживаемая архитектура: $(uname -m)" ;;
esac

IMAGE="mtproxyl-panel-egress:$CUSTOM_VERSION"
OUT="$WORK/mtproxyl-panel-egress"
docker build --build-arg TARGETARCH="$ARCH" --build-arg VERSION="$CUSTOM_VERSION" -t "$IMAGE" "$PANEL_SRC"
CID="$(docker create "$IMAGE")"
cleanup_cid() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup_cid EXIT
docker cp "$CID:/usr/local/bin/mtproxyl-panel" "$OUT"
cleanup_cid
trap - EXIT
chmod 755 "$OUT"
BUILT="$($OUT version)"
echo "Built: $BUILT"
[[ "$BUILT" == *"$CUSTOM_VERSION"* ]] || fail "Неверная версия собранного бинарника"

# Install a single validated privileged bridge. Panel itself stays unprivileged.
echo
echo "===== INSTALL BRIDGE ====="
install -o root -g root -m 755 "$SELF_DIR/bridge.sh" "$BRIDGE"
cat >"$SUDOERS" <<EOF
# MTProxyL Panel -> validated Egress bridge only.
mtproxyl-panel ALL=(root) NOPASSWD: $BRIDGE
EOF
chmod 440 "$SUDOERS"
chown root:root "$SUDOERS"
visudo -cf "$SUDOERS"
sudo -u mtproxyl-panel sudo -n "$BRIDGE" status | python3 -m json.tool >/dev/null
sudo -u mtproxyl-panel sudo -n "$BRIDGE" config-get | python3 -m json.tool >/dev/null
echo "Bridge: OK"

# Rollback restores the official panel only.
cat >/root/rollback-mtproxyl-panel-egress.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP="$BACKUP"
PANEL_BIN="$PANEL_BIN"
PANEL_SERVICE="$PANEL_SERVICE"
BRIDGE="$BRIDGE"
SUDOERS="$SUDOERS"
echo "Restoring official panel from \$BACKUP"
systemctl stop "\$PANEL_SERVICE" || true
install -o root -g root -m 755 "\$BACKUP/mtproxyl-panel" "\$PANEL_BIN"
rm -f "\$BRIDGE" "\$SUDOERS"
systemctl daemon-reload
systemctl start "\$PANEL_SERVICE"
sleep 2
"\$PANEL_BIN" version
systemctl is-active "\$PANEL_SERVICE"
echo "Rollback complete. Egress networking was not changed."
EOF
chmod 700 /root/rollback-mtproxyl-panel-egress.sh

# Swap only after successful build and bridge validation.
echo
echo "===== INSTALL CUSTOM PANEL ====="
install -o root -g root -m 755 "$OUT" "$PANEL_BIN.new"
systemctl stop "$PANEL_SERVICE"
mv "$PANEL_BIN.new" "$PANEL_BIN"
systemctl start "$PANEL_SERVICE"
sleep 3

if ! systemctl is-active --quiet "$PANEL_SERVICE"; then
    echo "Custom panel failed; restoring official binary..." >&2
    systemctl stop "$PANEL_SERVICE" || true
    install -o root -g root -m 755 "$BACKUP/mtproxyl-panel" "$PANEL_BIN"
    rm -f "$BRIDGE" "$SUDOERS"
    systemctl start "$PANEL_SERVICE"
    systemctl status "$PANEL_SERVICE" --no-pager || true
    fail "Panel was automatically rolled back"
fi

echo
echo "===== VERIFY ====="
"$PANEL_BIN" version
printf 'Panel service: '; systemctl is-active "$PANEL_SERVICE"

if curl -kfsS --connect-timeout 3 --max-time 6 https://127.0.0.1:8080/ >/dev/null 2>&1; then
    echo "Panel HTTPS: OK"
elif curl -fsS --connect-timeout 3 --max-time 6 http://127.0.0.1:8080/ >/dev/null 2>&1; then
    echo "Panel HTTP: OK"
else
    echo "WARNING: local HTTP(S) probe failed, but service is active"
fi

printf 'Manager: '; systemctl is-active mtproxyl-egress-manager.service
echo "Production route:"
ip route get 149.154.167.51 mark 0x200000

STATUS_JSON="$(sudo -u mtproxyl-panel sudo -n "$BRIDGE" status)"
python3 - "$STATUS_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print("Bridge mode:", d.get("mode"))
print("Bridge active:", d.get("active_node"))
for n in d.get("nodes", []):
    print(n.get("id"), "health=", n.get("health"), "agent=", (n.get("agent") or {}).get("reachable"))
PY

echo
echo "============================================================"
echo " INSTALL COMPLETE"
echo "============================================================"
echo "Panel:    $CUSTOM_VERSION"
echo "Page:     /egress  (MTProxyL -> Выходные ноды)"
echo "Rollback: /root/rollback-mtproxyl-panel-egress.sh"
echo
echo "Upstream update checks remain available, but applying an"
echo "upstream Panel binary is blocked in this custom build."
echo "============================================================"
