#!/usr/bin/env bash
set -Eeuo pipefail

CLI="/usr/local/bin/mtproxyl-egress"

fail(){ echo "$*" >&2; exit 1; }

[[ -x "$CLI" ]] || fail "mtproxyl-egress CLI missing"

cmd="${1:-}"

case "$cmd" in
  status)
    exec "$CLI" status --panel-json
    ;;

  mode)
    mode="${2:-}"
    case "$mode" in
      auto)
        exec "$CLI" auto
        ;;
      block)
        exec "$CLI" block
        ;;
      pl1|pl2)
        exec "$CLI" switch "$mode"
        ;;
      *)
        fail "invalid mode"
        ;;
    esac
    ;;

  config-get)
    exec "$CLI" config get
    ;;

  config-set)
    ci="${2:-}"; ft="${3:-}"; fh="${4:-}"; hs="${5:-}"
    for v in "$ci" "$ft" "$fh" "$hs"; do
      [[ "$v" =~ ^[0-9]+$ ]] || fail "configuration values must be integers"
    done
    exec "$CLI" config set "$ci" "$ft" "$fh" "$hs"
    ;;

  events)
    limit="${2:-30}"
    [[ "$limit" =~ ^[0-9]+$ ]] || fail "invalid limit"
    (( limit >= 1 && limit <= 200 )) || fail "invalid limit"
    "$CLI" events "$limit" | python3 -c 'import json,sys; print(json.dumps([x.rstrip("\n") for x in sys.stdin],ensure_ascii=False))'
    ;;

  *)
    fail "usage: $0 status | mode MODE | config-get | config-set CI FT FH HS | events N"
    ;;
esac
