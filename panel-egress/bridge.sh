#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/mtproxyl-egress/manager.env"
MODE_FILE="/var/lib/mtproxyl-egress/mode"
EVENTS_FILE="/var/lib/mtproxyl-egress/events.log"
MANAGER_SERVICE="mtproxyl-egress-manager.service"

fail() {
    echo "$*" >&2
    exit 1
}

[[ -f "$ENV_FILE" ]] || fail "manager.env not found"

cmd="${1:-}"

case "$cmd" in
    status)
        exec /usr/local/bin/mtproxyl-egress status --json
        ;;

    mode)
        mode="${2:-}"
        case "$mode" in
            auto|pl1|pl2|block) ;;
            *) fail "invalid mode" ;;
        esac

        printf '%s\n' "$mode" >"$MODE_FILE"
        chmod 644 "$MODE_FILE"
        systemctl restart "$MANAGER_SERVICE"
        sleep 1
        ;;

    config-get)
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        python3 - \
            "${CHECK_INTERVAL:-5}" \
            "${FAIL_THRESHOLD:-3}" \
            "${FAILBACK_HOLD:-30}" \
            "${HANDSHAKE_MAX_AGE:-180}" <<'PY'
import json
import sys

print(json.dumps({
    "check_interval": int(sys.argv[1]),
    "fail_threshold": int(sys.argv[2]),
    "failback_hold": int(sys.argv[3]),
    "handshake_max_age": int(sys.argv[4]),
}))
PY
        ;;

    config-set)
        ci="${2:-}"
        ft="${3:-}"
        fh="${4:-}"
        hs="${5:-}"

        for v in "$ci" "$ft" "$fh" "$hs"; do
            [[ "$v" =~ ^[0-9]+$ ]] || fail "configuration values must be integers"
        done

        (( ci >= 2 && ci <= 60 )) || fail "check_interval out of range"
        (( ft >= 1 && ft <= 10 )) || fail "fail_threshold out of range"
        (( fh >= 5 && fh <= 600 )) || fail "failback_hold out of range"
        (( hs >= 30 && hs <= 600 )) || fail "handshake_max_age out of range"

        exec 9>/run/mtproxyl-egress-panel-config.lock
        flock -x 9

        python3 - "$ENV_FILE" "$ci" "$ft" "$fh" "$hs" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
values = {
    "CHECK_INTERVAL": sys.argv[2],
    "FAIL_THRESHOLD": sys.argv[3],
    "FAILBACK_HOLD": sys.argv[4],
    "HANDSHAKE_MAX_AGE": sys.argv[5],
}

lines = path.read_text().splitlines()
seen = set()
out = []

for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line else ""
    if key in values:
        out.append(f"{key}={values[key]}")
        seen.add(key)
    else:
        out.append(line)

for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}")

tmp = path.with_name(path.name + ".panel.tmp")
tmp.write_text("\n".join(out) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY

        systemctl restart "$MANAGER_SERVICE"
        sleep 1
        "$0" config-get
        ;;

    events)
        limit="${2:-30}"
        [[ "$limit" =~ ^[0-9]+$ ]] || fail "invalid limit"
        (( limit >= 1 && limit <= 200 )) || fail "invalid limit"

        python3 - "$EVENTS_FILE" "$limit" <<'PY'
import json
from collections import deque
from pathlib import Path
import sys

path = Path(sys.argv[1])
limit = int(sys.argv[2])

if not path.exists():
    print("[]")
    raise SystemExit

with path.open(encoding="utf-8", errors="replace") as f:
    rows = list(deque((line.rstrip("\n") for line in f), maxlen=limit))

print(json.dumps(rows, ensure_ascii=False))
PY
        ;;

    *)
        fail "usage: $0 status | mode MODE | config-get | config-set CI FT FH HS | events N"
        ;;
esac
