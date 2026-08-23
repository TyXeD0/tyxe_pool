#!/usr/bin/env bash
set -Eeuo pipefail

CLI="/usr/local/bin/mtproxyl-egress"
PROVISION="/usr/local/libexec/mtproxyl-egress-provision"
JOB="/usr/local/libexec/mtproxyl-egress-panel-job"

fail(){ echo "$*" >&2; exit 1; }

[[ -x "$CLI" ]] || fail "mtproxyl-egress CLI missing"

cmd="${1:-}"

case "$cmd" in
  status)
    exec "$CLI" status --json
    ;;

  mode)
    mode="${2:-}"
    case "$mode" in
      auto) exec "$CLI" auto ;;
      direct) exec "$CLI" direct ;;
      block) exec "$CLI" block ;;
      manual)
        node="${3:-}"
        [[ -n "$node" ]] || fail "manual node required"
        exec "$CLI" switch "$node"
        ;;
      *) fail "invalid mode" ;;
    esac
    ;;

  node-test)
    node="${2:-}"
    [[ -n "$node" ]] || fail "node required"
    exec "$CLI" node test "$node"
    ;;

  node-rename)
    node="${2:-}"; name="${3:-}"
    [[ -n "$node" && -n "$name" ]] || fail "node and name required"
    exec "$CLI" node rename "$node" "$name"
    ;;

  node-enable)
    node="${2:-}"
    [[ -n "$node" ]] || fail "node required"
    exec "$CLI" node enable "$node"
    ;;

  node-disable)
    node="${2:-}"
    [[ -n "$node" ]] || fail "node required"
    exec "$CLI" node disable "$node"
    ;;

  node-priority)
    node="${2:-}"; priority="${3:-}"
    [[ -n "$node" ]] || fail "node required"
    [[ "$priority" =~ ^[0-9]+$ ]] || fail "invalid priority"
    (( priority >= 1 && priority <= 9999 )) || fail "invalid priority"
    exec "$CLI" node priority "$node" "$priority"
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
    "$CLI" events "$limit" |
      python3 -c 'import json,sys; print(json.dumps([x.rstrip("\n") for x in sys.stdin],ensure_ascii=False))'
    ;;

  provision-preflight)
    [[ -x "$PROVISION" ]] || fail "SSH provisioner missing"
    exec "$PROVISION" preflight
    ;;

  job-start)
    [[ -x "$PROVISION" ]] || fail "SSH provisioner missing"
    [[ -x "$JOB" ]] || fail "panel job runner missing"
    exec "$JOB" start
    ;;

  job-status)
    [[ -x "$JOB" ]] || fail "panel job runner missing"
    job="${2:-}"
    [[ "$job" =~ ^j-[0-9a-f]{16}$ ]] || fail "invalid job id"
    exec "$JOB" status "$job"
    ;;

  *)
    fail "usage: $0 status | mode MODE [NODE] | node-test NODE | node-rename NODE NAME | node-enable NODE | node-disable NODE | node-priority NODE PRIORITY | config-get | config-set CI FT FH HS | events N | provision-preflight | job-start | job-status JOB"
    ;;
esac
