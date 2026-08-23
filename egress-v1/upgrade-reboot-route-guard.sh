#!/usr/bin/env bash
set -Eeuo pipefail

DAEMON="/usr/local/libexec/mtproxyl-egressd"
SERVICE="mtproxyl-egressd.service"
CONFIG="/etc/mtproxyl-egress/config.toml"
CLI="/usr/local/bin/mtproxyl-egress"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mtproxyl-egressd-reboot-guard-$STAMP"

fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Запусти от root."
[[ -f "$DAEMON" ]] || fail "Не найден $DAEMON"
[[ -f "$CONFIG" ]] || fail "Не найден $CONFIG"
[[ -x "$CLI" ]] || fail "Не найден $CLI"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"

mkdir -p "$BACKUP"
cp -a "$DAEMON" "$BACKUP/mtproxyl-egressd"
cp -a "/etc/systemd/system/$SERVICE" "$BACKUP/" 2>/dev/null || true

read -r MARK RULE_PRIORITY BLOCK_TABLE <<<"$(python3 - "$CONFIG" <<'PY'
import sys,tomllib
with open(sys.argv[1],"rb") as f:
    d=tomllib.load(f)
r=d.get("routing",{})
print(r.get("mark","0x200000"), int(r.get("rule_priority",11000)), int(r.get("block_table",51839)))
PY
)"

# Immediate safety guard: from this point Telegram can only be blackholed until
# the patched daemon has reconstructed the active route. Never leave a rebooted
# host falling through to the ENTER main routing table.
while ip rule del priority 10999 2>/dev/null; do :; done
ip rule add priority 10999 fwmark "$MARK/$MARK" lookup "$BLOCK_TABLE"
while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
ip rule add priority "$RULE_PRIORITY" fwmark "$MARK/$MARK" lookup "$BLOCK_TABLE"
while ip rule del priority 10999 2>/dev/null; do :; done
ip route replace blackhole default table "$BLOCK_TABLE"

echo "Emergency fail-closed route installed: fwmark $MARK -> table $BLOCK_TABLE"

python3 - "$DAEMON" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

if 'VERSION = "1.0.0-dev3"' in s and 'def reconcile_active_route' in s:
    print("Reboot route guard already present")
    raise SystemExit(0)

if 'VERSION = "1.0.0-dev2"' not in s:
    raise SystemExit("unexpected live daemon version; expected 1.0.0-dev2")

s=s.replace('VERSION = "1.0.0-dev2"','VERSION = "1.0.0-dev3"',1)

# reload() must construct route tables, then restore the persisted active
# production fwmark rule, and only then expose/reconcile nft marking.
old='''            ensure_routes(self.nodes, self.config)\n            ensure_nft(self.nodes)\n'''
new='''            ensure_routes(self.nodes, self.config)\n            self.reconcile_active_route()\n            ensure_nft(self.nodes)\n'''
if old not in s:
    raise SystemExit("reload route/nft anchor not found")
s=s.replace(old,new,1)

needle='''    def reconcile_telemt_nat(self) -> None:\n'''
methods='''    def active_route_table(self) -> str:\n        if self.active == "block":\n            return str(int(self.config["routing"].get("block_table", 51839)))\n        if self.active == "direct":\n            return "main"\n        try:\n            n = find_node(self.nodes, self.active)\n            return str(int(n["routing_table"]))\n        except Exception:\n            return str(int(self.config["routing"].get("block_table", 51839)))\n\n    def reconcile_active_route(self) -> None:\n        mark = str(self.config["routing"].get("mark", "0x200000"))\n        priority = int(self.config["routing"].get("rule_priority", 11000))\n        table = self.active_route_table()\n        mark_int = int(mark, 0)\n        mark_token = f"fwmark 0x{mark_int:x}/0x{mark_int:x}"\n        lookup_token = f"lookup {table}"\n\n        lines = run(["ip", "rule", "show"]).stdout.splitlines()\n        matches = [line.strip() for line in lines if line.strip().startswith(f"{priority}:")]\n        if len(matches) == 1 and mark_token in matches[0] and lookup_token in matches[0]:\n            return\n\n        # replace_mark_rule uses a transient higher-priority rule, so there is\n        # no mark-routing gap while repairing the production rule.\n        replace_mark_rule(table, mark, priority)\n        event(f"route_reconcile active={self.active} table={table}")\n\n    def telemt_container_running(self) -> bool:\n        container = str(self.config.get("telemt", {}).get("container", "mtproxyl"))\n        p = run(["docker", "inspect", "-f", "{{.State.Running}}", container], timeout=5)\n        return p.returncode == 0 and p.stdout.strip().casefold() == "true"\n\n'''
if needle not in s:
    raise SystemExit("reconcile_telemt_nat anchor not found")
s=s.replace(needle,methods+needle,1)

# Do not mutate/restart Telemt until Docker has actually restored the container.
old='''        current_ip = telemt_nat_ip(cfg_path)\n        if current_ip == desired_ip:\n            return\n'''
new='''        if not self.telemt_container_running():\n            self.phase = "waiting_telemt"\n            self.last_error = None\n            return\n\n        current_ip = telemt_nat_ip(cfg_path)\n        if current_ip == desired_ip:\n            return\n'''
if old not in s:
    raise SystemExit("Telemt current-IP anchor not found")
s=s.replace(old,new,1)

# A persisted node may be the active ID before its AWG interface/handshake is
# ready after boot. Never restart Telemt through a route which is not healthy.
old='''                elif self.active != "block":\n                    self.reconcile_telemt_nat()\n\n                self.collect_agents()\n'''
new='''                elif self.active != "block":\n                    active_ready = (\n                        self.active == "direct"\n                        or bool(self.rows.get(self.active, {}).get("health"))\n                    )\n                    if active_ready:\n                        self.reconcile_telemt_nat()\n                    else:\n                        self.phase = "waiting_route"\n                        self.last_error = None\n\n                self.collect_agents()\n'''
if old not in s:
    raise SystemExit("manager Telemt reconcile anchor not found")
s=s.replace(old,new,1)

p.write_text(s,encoding="utf-8")
print("Patched daemon to 1.0.0-dev3")
PY

python3 -m py_compile "$DAEMON"

cat >"$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
# WARNING: this rollback restores the previous daemon but deliberately leaves
# Telegram fail-closed in the BLOCK table; it does not reintroduce direct leak.
cp -a "$BACKUP/mtproxyl-egressd" "$DAEMON"
python3 -m py_compile "$DAEMON"
systemctl restart "$SERVICE"
sleep 3
while ip rule del priority 10999 2>/dev/null; do :; done
while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
ip rule add priority "$RULE_PRIORITY" fwmark "$MARK/$MARK" lookup "$BLOCK_TABLE"
ip route replace blackhole default table "$BLOCK_TABLE"
echo "Previous daemon restored; routing intentionally left FAIL-CLOSED/BLOCK."
EOF
chmod 700 "$BACKUP/rollback.sh"
ln -sfn "$BACKUP/rollback.sh" /root/rollback-mtproxyl-egressd-reboot-guard.sh

systemctl restart "$SERVICE"
sleep 3
if ! systemctl is-active --quiet "$SERVICE"; then
  cp -a "$BACKUP/mtproxyl-egressd" "$DAEMON"
  systemctl restart "$SERVICE" || true
  while ip rule del priority 10999 2>/dev/null; do :; done
  while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
  ip rule add priority "$RULE_PRIORITY" fwmark "$MARK/$MARK" lookup "$BLOCK_TABLE"
  fail "Patched daemon failed; previous daemon restored and routing left BLOCK"
fi

# Wait for egressd to rebuild the persisted active mark route. It may keep the
# table blackholed until the AWG interface itself is healthy, which is safe.
ROUTE_OK=0
for _ in $(seq 1 60); do
  STATUS="$($CLI status --json 2>/dev/null || true)"
  if [[ -n "$STATUS" ]]; then
    read -r ACTIVE EXPECTED_IF <<<"$(python3 - "$STATUS" <<'PY'
import json,sys
try:d=json.loads(sys.argv[1])
except Exception:
    print("",""); raise SystemExit
active=d.get("active_node") or ""
if active in {"block","direct",""}:
    print(active,"")
else:
    n=next((x for x in d.get("nodes",[]) if x.get("id")==active),{})
    print(active,(n.get("awg") or {}).get("interface", ""))
PY
)"
    if [[ "$ACTIVE" == "block" ]]; then
      ROUTE_OK=1; break
    elif [[ "$ACTIVE" == "direct" ]]; then
      ROUTE_OK=1; break
    elif [[ -n "$EXPECTED_IF" ]]; then
      R="$(ip route get 149.154.167.51 mark "$MARK" 2>&1 || true)"
      if grep -q "dev $EXPECTED_IF" <<<"$R"; then
        ROUTE_OK=1; break
      fi
    fi
  fi
  sleep 2
done

if [[ "$ROUTE_OK" != "1" ]]; then
  while ip rule del priority 10999 2>/dev/null; do :; done
  while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
  ip rule add priority "$RULE_PRIORITY" fwmark "$MARK/$MARK" lookup "$BLOCK_TABLE"
  fail "Active route was not reconstructed; Telegram left FAIL-CLOSED/BLOCK"
fi

echo
echo "===== ROUTE RECONCILED ====="
ip rule show | grep -E "^${RULE_PRIORITY}:" || true
ip route get 149.154.167.51 mark "$MARK" || true

# Current boot may already have a Telemt process stuck in warmup because it
# spent several minutes on the leaked main route. Restart it once, now that the
# marked production route is known-good.
ACTIVE="$($CLI status --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("active_node", ""))')"
if [[ "$ACTIVE" != "block" ]]; then
  docker restart mtproxyl >/dev/null
fi

READY=0
for _ in $(seq 1 75); do
  DC="$(mtproxyl dc status --json 2>/dev/null || true)"
  if [[ -n "$DC" ]] && python3 - "$DC" <<'PY'
import json,sys
try:d=json.loads(sys.argv[1])
except Exception: raise SystemExit(1)
ok=(d.get("available") is True and int(d.get("coverage_pct") or 0)>=80 and int(d.get("alive_writers") or 0)>0)
raise SystemExit(0 if ok else 1)
PY
  then READY=1; break; fi
  sleep 2
done

# Give daemon one extra cycle to clear DEGRADED after DC becomes ready.
sleep 6

echo
echo "===== REBOOT GUARD STATUS ====="
$CLI status | sed -n '1,35p'
echo
echo "Marked production route:"
ip route get 149.154.167.51 mark "$MARK" || true
echo
echo "DC status:"
mtproxyl dc status --json || true

echo
if [[ "$READY" == "1" ]]; then
  echo "REBOOT ROUTE GUARD INSTALLED AND TELEMT RECOVERED"
else
  echo "WARNING: route guard is installed, but Telemt DC is not ready yet"
fi
echo "Rollback (leaves traffic BLOCKED): /root/rollback-mtproxyl-egressd-reboot-guard.sh"
