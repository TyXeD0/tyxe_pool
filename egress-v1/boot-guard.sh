#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/mtproxyl-egress/config.toml"
[[ -f "$CONFIG" ]] || { echo "ERROR: missing $CONFIG" >&2; exit 1; }

read -r MARK RULE_PRIORITY BLOCK_TABLE <<<"$(python3 - "$CONFIG" <<'PY'
import sys,tomllib
with open(sys.argv[1],"rb") as f:
    d=tomllib.load(f)
r=d.get("routing",{})
print(r.get("mark","0x200000"), int(r.get("rule_priority",11000)), int(r.get("block_table",51839)))
PY
)"

# This runs before Docker. Until egressd reconstructs the persisted active
# EXIT route, every Telegram destination must be marked and blackholed.
ip route replace blackhole default table "$BLOCK_TABLE"

while ip rule del priority 10999 2>/dev/null; do :; done
while ip rule del priority "$RULE_PRIORITY" 2>/dev/null; do :; done
ip rule add priority "$RULE_PRIORITY" fwmark "$MARK/$MARK" lookup "$BLOCK_TABLE"

# A reboot normally starts with no dynamic nft state. Recreate the minimal
# fail-closed table before Docker can restore the host-network Telemt container.
nft delete table inet mtproxyl_egress 2>/dev/null || true
nft -f - <<NFT
table inet mtproxyl_egress {
    set tg4 {
        type ipv4_addr
        flags interval
        elements = { 91.108.56.0/22, 91.108.4.0/22, 91.108.8.0/22, 91.108.16.0/22, 91.108.12.0/22, 149.154.160.0/20, 91.105.192.0/23, 91.108.20.0/22, 185.76.151.0/24 }
    }

    chain output {
        type route hook output priority -150; policy accept;
        ip daddr @tg4 counter meta mark set meta mark | $MARK
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
NFT

# Hard assertions. If any fails, the unit fails; Docker Requires= this unit and
# therefore cannot start Telemt in a potentially leaking state.
ip rule show | grep -Eq "^${RULE_PRIORITY}:.*fwmark .*lookup ${BLOCK_TABLE}$"
ip route show table "$BLOCK_TABLE" | grep -q '^blackhole default'
nft list chain inet mtproxyl_egress output | grep -q 'meta mark set'

echo "MTProxyL boot guard: Telegram fwmark $MARK -> BLOCK table $BLOCK_TABLE"
