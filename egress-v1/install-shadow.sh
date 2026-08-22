#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/shadow.py"; DST=/usr/local/libexec/mtproxyl-egress-shadow
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ -f /etc/mtproxyl-egress/config.toml ]] || { echo 'Registry migration required first' >&2; exit 1; }
[[ -x /usr/local/libexec/mtproxyl-egress-registry ]] || { echo 'Registry tool missing' >&2; exit 1; }
/usr/local/libexec/mtproxyl-egress-registry validate
install -o root -g root -m 755 "$SRC" "$DST"
python3 -m py_compile "$DST"
echo
echo '===== DYNAMIC SHADOW ====='
set +e
"$DST"
RC=$?
set -e
echo
echo '===== LEGACY PRODUCTION ====='
/usr/local/bin/mtproxyl-egress status | sed -n '1,38p'
echo
echo '===== PRODUCTION ROUTE ====='
ip route get 149.154.167.51 mark 0x200000
echo
if [[ $RC -eq 0 ]]; then
  echo 'SHADOW TEST PASSED'
else
  echo 'SHADOW TEST FAILED — production was not changed.' >&2
fi
exit "$RC"
