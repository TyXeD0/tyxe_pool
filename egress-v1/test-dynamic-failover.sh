#!/usr/bin/env bash
set -Eeuo pipefail

CLI=/usr/local/bin/mtproxyl-egress
TEST_IP=149.154.167.51
PL1_IP=2.26.255.195
PL2_IP=103.68.110.215

fail(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run as root"
systemctl is-active --quiet mtproxyl-egressd.service || fail "mtproxyl-egressd is not active"

show_state(){
  echo
  "$CLI" status | sed -n '1,28p'
  echo
  echo "Route: $(ip route get "$TEST_IP" mark 0x200000 | head -n1)"
  echo -n "NAT:   "
  python3 - <<'PY'
import tomllib
with open('/etc/mtproxyl-egress/config.toml','rb') as f:
    cfg=tomllib.load(f)
p=cfg.get('telemt',{}).get('config','')
with open(p,'rb') as f:
    t=tomllib.load(f)
print(t.get('general',{}).get('middle_proxy_nat_ip',''))
PY
  echo -n "DC:    "
  mtproxyl dc status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"{d.get(chr(97)+chr(108)+chr(105)+chr(118)+chr(101)+chr(95)+chr(119)+chr(114)+chr(105)+chr(116)+chr(101)+chr(114)+chr(115))}/{d.get(chr(114)+chr(101)+chr(113)+chr(117)+chr(105)+chr(114)+chr(101)+chr(100)+chr(95)+chr(119)+chr(114)+chr(105)+chr(116)+chr(101)+chr(114)+chr(115))} coverage={d.get(chr(99)+chr(111)+chr(118)+chr(101)+chr(114)+chr(97)+chr(103)+chr(101)+chr(95)+chr(112)+chr(99)+chr(116))}% verdict={d.get(chr(118)+chr(101)+chr(114)+chr(100)+chr(105)+chr(99)+chr(116))}")'
}

wait_for(){
  local want_id="$1" want_dev="$2" want_nat="$3"
  local i json active route nat coverage
  for i in $(seq 1 30); do
    json="$($CLI status --json 2>/dev/null || true)"
    active="$(python3 - "$json" <<'PY'
import json,sys
try:d=json.loads(sys.argv[1]); print(d.get('active_node',''))
except Exception:print('')
PY
)"
    route="$(ip route get "$TEST_IP" mark 0x200000 2>/dev/null | head -n1 || true)"
    nat="$(python3 - <<'PY'
import tomllib
try:
  with open('/etc/mtproxyl-egress/config.toml','rb') as f: cfg=tomllib.load(f)
  p=cfg.get('telemt',{}).get('config','')
  with open(p,'rb') as f: t=tomllib.load(f)
  print(t.get('general',{}).get('middle_proxy_nat_ip',''))
except Exception: print('')
PY
)"
    coverage="$(mtproxyl dc status --json 2>/dev/null | python3 -c 'import json,sys
try:d=json.load(sys.stdin); print(int(d.get("coverage_pct") or 0))
except Exception: print(0)' || echo 0)"
    printf 'try %02d: active=%s dev=%s nat=%s coverage=%s%%\n' "$i" "${active:-?}" "$(awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$route")" "${nat:-?}" "${coverage:-0}"
    if [[ "$active" == "$want_id" && "$route" == *" dev $want_dev "* && "$nat" == "$want_nat" && "${coverage:-0}" -ge 80 ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

PL1_ID="$($CLI node list --json | python3 -c 'import json,sys; a=json.load(sys.stdin); print(next(n["id"] for n in a if n.get("name","").casefold()=="pl1"))')"
PL2_ID="$($CLI node list --json | python3 -c 'import json,sys; a=json.load(sys.stdin); print(next(n["id"] for n in a if n.get("name","").casefold()=="pl2"))')"

echo "===== BEFORE ====="
show_state

echo
echo "===== SWITCH TO PL2 ====="
$CLI switch "$PL2_ID"
wait_for "$PL2_ID" awg-pl2 "$PL2_IP" || fail "PL2 did not become fully ready"
show_state

echo
echo "===== RETURN TO AUTO ====="
$CLI auto
wait_for "$PL1_ID" awg-pl1 "$PL1_IP" || fail "AUTO did not fail back to PL1"
show_state

echo
echo "DYNAMIC FAILOVER TEST PASSED"
