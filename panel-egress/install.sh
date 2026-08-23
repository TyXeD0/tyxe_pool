#!/usr/bin/env bash
set -Eeuo pipefail

BASE_COMMIT="8e6ef1d598a2d4f3af2b4a81ac028b0f9ae7afe5"
CUSTOM_VERSION="1.0.14-egress2"
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

fail(){ echo; echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."

for c in git docker python3 sudo visudo systemctl install curl ip; do
    command -v "$c" >/dev/null 2>&1 || fail "Не найдена команда: $c"
done

[[ -x "$PANEL_BIN" ]] || fail "Не найден $PANEL_BIN"
[[ -f "$PANEL_CFG" ]] || fail "Не найден $PANEL_CFG"
[[ -x /usr/local/bin/mtproxyl-egress ]] || fail "Не найден mtproxyl-egress"
[[ -x /usr/local/libexec/mtproxyl-egress-registry ]] || fail "Не найден dynamic egress registry"
id mtproxyl-panel >/dev/null 2>&1 || fail "Нет пользователя mtproxyl-panel"

systemctl is-active --quiet mtproxyl-egressd.service \
    || fail "Dynamic Egress daemon не active."

/usr/local/libexec/mtproxyl-egress-registry validate

CURRENT_PANEL="$($PANEL_BIN version 2>/dev/null || true)"

echo
echo "============================================================"
echo " MTProxyL Panel Dynamic Egress UI"
echo "============================================================"
echo "Current: $CURRENT_PANEL"
echo "Target:  mtproxyl-panel $CUSTOM_VERSION"
echo

case "$CURRENT_PANEL" in
    *"1.0.14"*|*"-egress"*) ;;
    *) fail "Ожидалась Panel 1.0.14 / custom egress build." ;;
esac

echo "===== EGRESS PRE-FLIGHT ====="

STATUS_JSON="$(/usr/local/bin/mtproxyl-egress status --json)"
python3 - "$STATUS_JSON" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
nodes=d.get("nodes") or []
if not nodes:
    raise SystemExit("dynamic registry contains no nodes")
print("Egress:", d.get("mode"), "phase=", d.get("phase"), "active=", d.get("active_node"))
print("Nodes:", len(nodes))
for n in sorted(nodes, key=lambda x:(int(x.get("priority",999999)), str(x.get("name","")))):
    print(
        f"  {n.get('priority'):>3} {n.get('name')} [{n.get('id')}] "
        f"enabled={n.get('enabled')} health={n.get('health')} "
        f"agent={(n.get('agent') or {}).get('reachable')}"
    )
PY

echo
echo "===== BACKUP ====="

install -d -m 700 "$BACKUP"
cp -a "$PANEL_BIN" "$BACKUP/mtproxyl-panel"
cp -a "$PANEL_CFG" "$BACKUP/config.toml"
cp -a "/etc/systemd/system/$PANEL_SERVICE" "$BACKUP/" 2>/dev/null || true
cp -a "$BRIDGE" "$BACKUP/mtproxyl-egress-panel-bridge" 2>/dev/null || true
cp -a "$SUDOERS" "$BACKUP/mtproxyl-panel-egress.sudoers" 2>/dev/null || true
printf '%s\n' "$CURRENT_PANEL" >"$BACKUP/version.txt"

echo "Backup: $BACKUP"

echo
echo "===== FETCH SOURCE ====="

rm -rf "$WORK"
install -d -m 755 "$WORK"
git clone --filter=blob:none --no-checkout "$UPSTREAM" "$SRC"
git -C "$SRC" checkout "$BASE_COMMIT"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$BASE_COMMIT" ]] || fail "Upstream commit mismatch"

echo
echo "===== PATCH SOURCE ====="

python3 "$SELF_DIR/patch.py" "$PANEL_SRC" "$SELF_DIR"

echo
echo "===== BUILD ====="

case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Неподдерживаемая архитектура: $(uname -m)" ;;
esac

IMAGE="mtproxyl-panel-egress:$CUSTOM_VERSION"
OUT="$WORK/mtproxyl-panel-egress"

docker build \
    --build-arg TARGETARCH="$ARCH" \
    --build-arg VERSION="$CUSTOM_VERSION" \
    -t "$IMAGE" \
    "$PANEL_SRC"

CID="$(docker create "$IMAGE")"
cleanup_cid(){ docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup_cid EXIT
docker cp "$CID:/usr/local/bin/mtproxyl-panel" "$OUT"
cleanup_cid
trap - EXIT

chmod 755 "$OUT"
BUILT="$($OUT version)"
echo "Built: $BUILT"
[[ "$BUILT" == *"$CUSTOM_VERSION"* ]] || fail "Неверная версия собранного бинарника"

echo
echo "===== INSTALL DYNAMIC BRIDGE ====="

install -o root -g root -m 755 "$SELF_DIR/bridge.sh" "$BRIDGE"

cat >"$SUDOERS" <<EOF
# MTProxyL Panel -> validated Dynamic Egress bridge only.
mtproxyl-panel ALL=(root) NOPASSWD: $BRIDGE
EOF

chmod 440 "$SUDOERS"
chown root:root "$SUDOERS"
visudo -cf "$SUDOERS"

sudo -u mtproxyl-panel sudo -n "$BRIDGE" status | python3 -m json.tool >/dev/null
sudo -u mtproxyl-panel sudo -n "$BRIDGE" config-get | python3 -m json.tool >/dev/null

echo "Bridge: OK"

restore_panel(){
    set +e
    systemctl stop "$PANEL_SERVICE" >/dev/null 2>&1 || true
    install -o root -g root -m 755 "$BACKUP/mtproxyl-panel" "$PANEL_BIN"

    if [[ -f "$BACKUP/mtproxyl-egress-panel-bridge" ]]; then
        install -o root -g root -m 755 \
            "$BACKUP/mtproxyl-egress-panel-bridge" "$BRIDGE"
    else
        rm -f "$BRIDGE"
    fi

    if [[ -f "$BACKUP/mtproxyl-panel-egress.sudoers" ]]; then
        install -o root -g root -m 440 \
            "$BACKUP/mtproxyl-panel-egress.sudoers" "$SUDOERS"
    else
        rm -f "$SUDOERS"
    fi

    systemctl daemon-reload
    systemctl start "$PANEL_SERVICE" >/dev/null 2>&1 || true
    set -e
}

cat >/root/rollback-mtproxyl-panel-egress.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP="$BACKUP"
PANEL_BIN="$PANEL_BIN"
PANEL_SERVICE="$PANEL_SERVICE"
BRIDGE="$BRIDGE"
SUDOERS="$SUDOERS"

echo "Restoring previous panel from \$BACKUP"

systemctl stop "\$PANEL_SERVICE" || true
install -o root -g root -m 755 "\$BACKUP/mtproxyl-panel" "\$PANEL_BIN"

if [[ -f "\$BACKUP/mtproxyl-egress-panel-bridge" ]]; then
    install -o root -g root -m 755 \
        "\$BACKUP/mtproxyl-egress-panel-bridge" "\$BRIDGE"
else
    rm -f "\$BRIDGE"
fi

if [[ -f "\$BACKUP/mtproxyl-panel-egress.sudoers" ]]; then
    install -o root -g root -m 440 \
        "\$BACKUP/mtproxyl-panel-egress.sudoers" "\$SUDOERS"
else
    rm -f "\$SUDOERS"
fi

systemctl daemon-reload
systemctl start "\$PANEL_SERVICE"
sleep 2

"\$PANEL_BIN" version
systemctl is-active "\$PANEL_SERVICE"
systemctl is-active mtproxyl-egressd.service

echo "Rollback complete. Dynamic Egress networking was not changed."
EOF

chmod 700 /root/rollback-mtproxyl-panel-egress.sh

echo
echo "===== INSTALL CUSTOM PANEL ====="

install -o root -g root -m 755 "$OUT" "$PANEL_BIN.new"

systemctl stop "$PANEL_SERVICE"
mv "$PANEL_BIN.new" "$PANEL_BIN"
systemctl start "$PANEL_SERVICE"
sleep 3

if ! systemctl is-active --quiet "$PANEL_SERVICE"; then
    echo "Custom panel failed; restoring previous panel..." >&2
    restore_panel
    systemctl status "$PANEL_SERVICE" --no-pager || true
    fail "Panel was automatically rolled back"
fi

echo
echo "===== VERIFY ====="

"$PANEL_BIN" version

printf 'Panel service:  '
systemctl is-active "$PANEL_SERVICE"

printf 'Egress daemon:  '
systemctl is-active mtproxyl-egressd.service

if curl -kfsS --connect-timeout 3 --max-time 6 https://127.0.0.1:8080/ >/dev/null 2>&1; then
    echo "Panel HTTPS: OK"
elif curl -fsS --connect-timeout 3 --max-time 6 http://127.0.0.1:8080/ >/dev/null 2>&1; then
    echo "Panel HTTP: OK"
else
    echo "WARNING: local HTTP(S) probe failed, but service is active"
fi

echo "Production route:"
ip route get 149.154.167.51 mark 0x200000

STATUS_JSON="$(sudo -u mtproxyl-panel sudo -n "$BRIDGE" status)"
python3 - "$STATUS_JSON" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
print("Bridge phase:", d.get("phase"))
print("Bridge mode:", d.get("mode"))
print("Bridge active:", d.get("active_node"))
print("Nodes:", len(d.get("nodes") or []))
for n in d.get("nodes") or []:
    print(
        n.get("name"), f"[{n.get('id')}]",
        "priority=", n.get("priority"),
        "health=", n.get("health"),
        "agent=", (n.get("agent") or {}).get("reachable"),
    )
PY

echo
echo "============================================================"
echo " INSTALL COMPLETE"
echo "============================================================"
echo "Panel:    $CUSTOM_VERSION"
echo "Page:     /egress  (MTProxyL -> Выходные ноды)"
echo "Rollback: /root/rollback-mtproxyl-panel-egress.sh"
echo
echo "Dynamic node actions:"
echo "  switch / test / rename / enable / disable / priority"
echo
echo "SSH provisioner for add/remove nodes is the next milestone."
echo "============================================================"
