#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH_DEFAULT="feature/dynamic-egress-nodes"
REPO_DEFAULT="TyXeD0/tyxe_pool"

REPO="${TYXE_POOL_REPO:-$REPO_DEFAULT}"
REF="${TYXE_POOL_REF:-$BRANCH_DEFAULT}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_SRC="$ROOT_DIR/registry.py"

REGISTRY_DST="/usr/local/libexec/mtproxyl-egress-registry"
CLI_DST="/usr/local/bin/mtproxyl-egress-node"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mtproxyl-egress-registry-backup-$STAMP"

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

fail(){ red "ERROR: $*"; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."

for cmd in python3 ip awg docker mtproxyl systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Не найдена команда: $cmd"
done

[[ -f "$REGISTRY_SRC" ]] || fail "Не найден $REGISTRY_SRC"
[[ -x /usr/local/bin/mtproxyl-egress ]] || fail "Не найден рабочий /usr/local/bin/mtproxyl-egress"

echo
echo "============================================================"
echo " MTProxyL Egress v1 — registry migration"
echo "============================================================"
echo
echo "Этот этап НЕ меняет маршруты, AWG, Telemt или failover."
echo "Он только переносит текущие ноды в новый динамический registry."
echo

echo "===== PRE-FLIGHT ====="

mtproxyl version || fail "MTProxyL не работает."
/usr/local/bin/mtproxyl-egress status --json \
    | python3 -m json.tool >/dev/null \
    || fail "Текущий egress status --json не работает."

systemctl is-active --quiet mtproxyl-egress-manager.service \
    || fail "Текущий failover manager не active."

echo "MTProxyL: OK"
echo "Legacy egress manager: OK"

echo
echo "===== BACKUP ====="

install -d -m 700 "$BACKUP"

cp -a /etc/mtproxyl-egress "$BACKUP/" 2>/dev/null || true
cp -a /usr/local/bin/mtproxyl-egress "$BACKUP/" 2>/dev/null || true
cp -a "$REGISTRY_DST" "$BACKUP/" 2>/dev/null || true
cp -a "$CLI_DST" "$BACKUP/" 2>/dev/null || true

echo "Backup:"
echo "  $BACKUP"

echo
echo "===== INSTALL REGISTRY TOOL ====="

install -d -m 755 /usr/local/libexec
install -m 755 "$REGISTRY_SRC" "$REGISTRY_DST"

cat >"$CLI_DST" <<'CLI'
#!/usr/bin/env bash
set -Eeuo pipefail

exec /usr/local/libexec/mtproxyl-egress-registry "$@"
CLI

chmod 755 "$CLI_DST"

echo
echo "===== MIGRATE PL1/PL2 ====="

REGISTRY_PREEXISTED=0

if [[ -f /etc/mtproxyl-egress/config.toml ]]; then
    REGISTRY_PREEXISTED=1
    yellow "Registry уже существует. Не перезаписываю его автоматически."
    "$CLI_DST" validate
else
    "$CLI_DST" migrate-legacy
fi

echo
echo "===== VALIDATE ====="

"$CLI_DST" validate

echo
echo "===== CURRENT NETWORK MUST STAY UNCHANGED ====="

printf "Manager: "
systemctl is-active mtproxyl-egress-manager.service

echo
ip route get 149.154.167.51 mark 0x200000

echo
echo "Current legacy status:"
/usr/local/bin/mtproxyl-egress status | sed -n '1,35p'

echo
echo "===== NEW REGISTRY ====="

"$CLI_DST" list

cat >/root/rollback-mtproxyl-egress-registry.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

rm -f "$REGISTRY_DST" "$CLI_DST"

if [[ "$REGISTRY_PREEXISTED" == "0" ]]; then
    rm -f /etc/mtproxyl-egress/config.toml
    rm -rf /etc/mtproxyl-egress/nodes.d
    rm -f /etc/mtproxyl-egress/migration-map.json
fi

echo "Registry tooling removed."
echo "Legacy egress networking was never changed."
EOF

chmod 700 /root/rollback-mtproxyl-egress-registry.sh

echo
echo "============================================================"
green " REGISTRY MIGRATION COMPLETE"
echo "============================================================"
echo
echo "Commands:"
echo "  mtproxyl-egress-node list"
echo "  mtproxyl-egress-node show <ID-or-name>"
echo "  mtproxyl-egress-node rename <ID-or-name> 'New name'"
echo "  mtproxyl-egress-node validate"
echo
echo "Rollback:"
echo "  /root/rollback-mtproxyl-egress-registry.sh"
echo
echo "IMPORTANT:"
echo "  Current PL1/PL2 manager remains production-active."
echo "  Rename changes registry display name only; AWG interface/ID stay unchanged."
echo "============================================================"
