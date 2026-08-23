#!/usr/bin/env bash
set -Eeuo pipefail

DAEMON="/usr/local/libexec/mtproxyl-egressd"
SERVICE="mtproxyl-egressd.service"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mtproxyl-egressd-nat-reconcile-$STAMP"

fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."
[[ -f "$DAEMON" ]] || fail "Не найден $DAEMON"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"

mkdir -p "$BACKUP"
cp -a "$DAEMON" "$BACKUP/mtproxyl-egressd"

python3 - "$DAEMON" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

if 'VERSION = "1.0.0-dev2"' in s and 'def reconcile_telemt_nat' in s:
    print("NAT reconcile patch already present")
    raise SystemExit(0)

if 'VERSION = "1.0.0-dev1"' not in s:
    raise SystemExit("unexpected daemon version; refusing to patch")

s = s.replace('VERSION = "1.0.0-dev1"', 'VERSION = "1.0.0-dev2"', 1)

needle = '''    def switch(self, target: str, reason: str) -> bool:\n'''
method = '''    def reconcile_telemt_nat(self) -> None:\n        target = self.active\n        if target == "block":\n            return\n\n        telemt = self.config.get("telemt", {})\n        cfg_path = Path(str(telemt.get("config", "")))\n        if not cfg_path.is_file():\n            raise RuntimeError(f"Telemt config missing: {cfg_path}")\n\n        if target == "direct":\n            desired_ip = direct_public_ipv4()\n        else:\n            n = find_node(self.nodes, target)\n            desired_ip = str(n.get("public_ip", ""))\n            ipaddress.IPv4Address(desired_ip)\n\n        current_ip = telemt_nat_ip(cfg_path)\n        if current_ip == desired_ip:\n            return\n\n        self.phase = "reconciling"\n        self.last_error = None\n        self.persist_status()\n        event(\n            f"telemt_nat_reconcile target={target} "\n            f"current={current_ip or '-'} desired={desired_ip}"\n        )\n\n        ok, dc = self.sync_telemt(target)\n        if not ok:\n            self.last_error = (\n                f"Telemt DC coverage not ready after NAT reconcile for {target}: "\n                f"{dc.get('coverage_pct', 0)}%"\n            )\n            self.phase = "degraded"\n            event(f"warning {self.last_error}")\n            return\n\n        self.phase = "running"\n        self.last_error = None\n        event(\n            f"telemt_nat_reconcile_ready target={target} "\n            f"coverage={dc.get('coverage_pct')} "\n            f"writers={dc.get('alive_writers')}/{dc.get('required_writers')}"\n        )\n\n'''

if needle not in s:
    raise SystemExit("switch method anchor not found")
s = s.replace(needle, method + needle, 1)

old = '''                desired = self.desired()\n                reason = self.control.get("mode", "auto")\n                if desired != self.active:\n                    self.switch(desired, reason=str(reason))\n\n                self.collect_agents()\n'''
new = '''                desired = self.desired()\n                reason = self.control.get("mode", "auto")\n                if desired != self.active:\n                    self.switch(desired, reason=str(reason))\n                elif self.active != "block":\n                    self.reconcile_telemt_nat()\n\n                self.collect_agents()\n'''
if old not in s:
    raise SystemExit("manager loop anchor not found")
s = s.replace(old, new, 1)

p.write_text(s, encoding="utf-8")
print("Patched daemon to 1.0.0-dev2")
PY

python3 -m py_compile "$DAEMON"

cat >"$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cp -a "$BACKUP/mtproxyl-egressd" "$DAEMON"
python3 -m py_compile "$DAEMON"
systemctl restart "$SERVICE"
sleep 3
systemctl is-active "$SERVICE"
/usr/local/bin/mtproxyl-egress status | sed -n '1,12p'
EOF
chmod 700 "$BACKUP/rollback.sh"
ln -sfn "$BACKUP/rollback.sh" /root/rollback-mtproxyl-egressd-nat-reconcile.sh

systemctl restart "$SERVICE"
sleep 3
systemctl is-active --quiet "$SERVICE" || {
  cp -a "$BACKUP/mtproxyl-egressd" "$DAEMON"
  systemctl restart "$SERVICE" || true
  fail "Patched daemon failed; previous daemon restored"
}

# Give the manager enough time to notice a missing/wrong NAT, restart Telemt if
# needed and wait for DC writers.
for _ in $(seq 1 45); do
  STATUS="$(/usr/local/bin/mtproxyl-egress status --json 2>/dev/null || true)"
  if [[ -n "$STATUS" ]] && python3 - "$STATUS" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
active=d.get("active_node")
if active in (None,"","block"):
    raise SystemExit(0)
nodes={n.get("id"):n for n in d.get("nodes",[])}
if active == "direct":
    raise SystemExit(0 if d.get("telemt",{}).get("nat_ip") else 1)
want=(nodes.get(active) or {}).get("public_ip")
have=d.get("telemt",{}).get("nat_ip")
cov=int(d.get("telemt",{}).get("dc_coverage_pct") or 0)
raise SystemExit(0 if want and have == want and cov >= 80 else 1)
PY
  then
    break
  fi
  sleep 2
done

echo
echo "===== NAT RECONCILE STATUS ====="
/usr/local/bin/mtproxyl-egress status | sed -n '1,18p'
echo
echo "Production route:"
ip route get 149.154.167.51 mark 0x200000

echo
echo "NAT reconcile hotfix installed."
echo "Rollback: /root/rollback-mtproxyl-egressd-nat-reconcile.sh"
