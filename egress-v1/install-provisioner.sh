#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROV_SRC="$ROOT/provision.py"
AGENT_SRC="$ROOT/node-agent.py"
PROV_DST="/usr/local/libexec/mtproxyl-egress-provision"
AGENT_DST="/usr/local/libexec/mtproxyl-node-agent-source"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mtproxyl-egress-provisioner-backup-$STAMP"

fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."

for c in python3 systemctl install ssh apt-get; do
  command -v "$c" >/dev/null 2>&1 || fail "Не найдена команда: $c"
done
[[ -f "$PROV_SRC" && -f "$AGENT_SRC" ]] || fail "Provisioner assets missing"
[[ -x /usr/local/bin/mtproxyl-egress ]] || fail "Dynamic Egress CLI missing"
systemctl is-active --quiet mtproxyl-egressd.service || fail "mtproxyl-egressd is not active"

echo
echo "============================================================"
echo " MTProxyL Dynamic Egress — SSH provisioner"
echo "============================================================"

echo
echo "===== PRE-FLIGHT ====="
/usr/local/bin/mtproxyl-egress status --json | python3 -m json.tool >/dev/null
printf "Dynamic daemon: "; systemctl is-active mtproxyl-egressd.service
python3 -m py_compile "$PROV_SRC" "$AGENT_SRC"
echo "Source syntax: OK"

if ! command -v sshpass >/dev/null 2>&1; then
  echo
  echo "===== INSTALL SSHPASS ====="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y sshpass openssh-client
fi

echo
echo "===== BACKUP ====="
install -d -m 700 "$BACKUP"
PREVIOUS_PROVISIONER_VALID=0
if [[ -x "$PROV_DST" ]] && "$PROV_DST" --version >/dev/null 2>&1; then
  cp -a "$PROV_DST" "$BACKUP/"
  PREVIOUS_PROVISIONER_VALID=1
elif [[ -e "$PROV_DST" ]]; then
  cp -a "$PROV_DST" "$BACKUP/broken-mtproxyl-egress-provision" || true
  echo "Previous provisioner is broken; saved for diagnostics only."
fi
cp -a "$AGENT_DST" "$BACKUP/" 2>/dev/null || true
cp -a /etc/mtproxyl-egress/ssh "$BACKUP/ssh" 2>/dev/null || true
printf '%s\n' "$PREVIOUS_PROVISIONER_VALID" >"$BACKUP/previous-valid"
echo "Backup: $BACKUP"

echo
echo "===== INSTALL ====="
install -d -m 755 /usr/local/libexec
install -o root -g root -m 755 "$PROV_SRC" "$PROV_DST"
install -o root -g root -m 755 "$AGENT_SRC" "$AGENT_DST"
install -d -o root -g root -m 700 /etc/mtproxyl-egress/ssh
install -d -o root -g root -m 700 /var/lib/mtproxyl-egress/jobs
install -d -o root -g root -m 700 /run/mtproxyl-egress

python3 -m py_compile "$PROV_DST" "$AGENT_DST"
"$PROV_DST" --version
"$PROV_DST" --help >/dev/null
"$PROV_DST" preflight | python3 -m json.tool

cat >/root/rollback-mtproxyl-egress-provisioner.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP="$BACKUP"
PROV="$PROV_DST"
AGENT="$AGENT_DST"
if [[ "\$(cat "\$BACKUP/previous-valid" 2>/dev/null || echo 0)" == "1" && -f "\$BACKUP/$(basename "$PROV_DST")" ]]; then
  install -m 755 "\$BACKUP/$(basename "$PROV_DST")" "\$PROV"
else
  rm -f "\$PROV"
fi
if [[ -f "\$BACKUP/$(basename "$AGENT_DST")" ]]; then
  install -m 755 "\$BACKUP/$(basename "$AGENT_DST")" "\$AGENT"
else
  rm -f "\$AGENT"
fi
echo "Provisioner rollback complete. Existing AWG nodes were not changed."
EOF
chmod 700 /root/rollback-mtproxyl-egress-provisioner.sh

echo
echo "===== VERIFY PRODUCTION UNCHANGED ====="
printf "Daemon: "; systemctl is-active mtproxyl-egressd.service
/usr/local/bin/mtproxyl-egress status | sed -n '1,18p'

echo
echo "============================================================"
echo " PROVISIONER INSTALLED"
echo "============================================================"
echo "No EXIT node was changed by this installation."
echo "Rollback: /root/rollback-mtproxyl-egress-provisioner.sh"
