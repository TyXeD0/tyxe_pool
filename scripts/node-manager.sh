#!/usr/bin/env bash
set -Eeuo pipefail

ETC='/etc/proxy-pool'
SETTINGS="$ETC/settings.env"
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
if [[ -r "$SETTINGS" ]]; then
  # shellcheck disable=SC1090
  . "$SETTINGS"
fi
LANG_CODE="${TYXE_POOL_LANG:-en}"
PORT="${PROXY_POOL_PORT:-9101}"
API="http://127.0.0.1:$PORT/api/nodes"
LOCAL_API_TOKEN="${PROXY_POOL_LOCAL_API_TOKEN:-}"
AUTH_ARGS=()
[[ -n "$LOCAL_API_TOKEN" ]] && AUTH_ARGS=(-H "Authorization: Bearer $LOCAL_API_TOKEN")

read_tty(){ local __var="$1" __prompt="$2" __silent="${3:-0}" value=''; if [[ "$__silent" == 1 ]]; then read -r -s -p "$__prompt" value </dev/tty || true; printf '\n' >/dev/tty; else read -r -p "$__prompt" value </dev/tty || true; fi; printf -v "$__var" '%s' "$value"; }
msg(){
  local k="$1"
  if [[ "$LANG_CODE" == ru ]]; then
    case "$k" in
      title) echo 'TYXE Pool — управление нодами';;
      menu1) echo '1) Показать ноды';; menu2) echo '2) Добавить ноду';; menu3) echo '3) Удалить ноду';; menu4) echo '4) Выход';;
      choice) echo 'Выберите пункт: ';; name) echo 'Имя ноды (например PL1): ';; addr) echo 'IP/адрес агента или tunnel IP: ';; port) echo 'Порт агента [9100]: ';; token) echo 'API token агента (можно оставить пустым): ';; added) echo 'Нода добавлена.';;
      id) echo 'ID ноды для удаления: ';; removed) echo 'Нода удалена.';; bad) echo 'Ошибка запроса к controller.';;
    esac
  else
    case "$k" in
      title) echo 'TYXE Pool — node management';;
      menu1) echo '1) List nodes';; menu2) echo '2) Add node';; menu3) echo '3) Remove node';; menu4) echo '4) Exit';;
      choice) echo 'Choose an item: ';; name) echo 'Node name (for example PL1): ';; addr) echo 'Agent IP/address or tunnel IP: ';; port) echo 'Agent port [9100]: ';; token) echo 'Agent API token (may be blank): ';; added) echo 'Node added.';;
      id) echo 'Node ID to remove: ';; removed) echo 'Node removed.';; bad) echo 'Controller request failed.';;
    esac
  fi
}

list_nodes(){
  curl -fsS "${AUTH_ARGS[@]}" "$API" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ID           NAME             ADDRESS                 STATUS"); [print(f"{n.get(chr(105)+chr(100),chr(45)):<12} {n.get(chr(110)+chr(97)+chr(109)+chr(101),chr(45)):<16} {n.get(chr(97)+chr(100)+chr(100)+chr(114)+chr(101)+chr(115)+chr(115),chr(45))}:{n.get(chr(97)+chr(103)+chr(101)+chr(110)+chr(116)+chr(95)+chr(112)+chr(111)+chr(114)+chr(116),9100):<7} {n.get(chr(115)+chr(116)+chr(97)+chr(116)+chr(117)+chr(115),chr(45))}") for n in d.get(chr(110)+chr(111)+chr(100)+chr(101)+chr(115),[])]' || { echo "$(msg bad)"; return 1; }
}
add_node(){
  local name='' addr='' port='9100' token=''
  read_tty name "$(msg name)"; [[ -n "$name" ]] || return 1
  read_tty addr "$(msg addr)"; [[ -n "$addr" ]] || return 1
  read_tty port "$(msg port)"; port="${port:-9100}"
  read_tty token "$(msg token)" 1
  PAYLOAD="$(python3 - "$name" "$addr" "$port" "$token" <<'PY'
import json,sys
print(json.dumps({'name':sys.argv[1],'address':sys.argv[2],'agent_port':int(sys.argv[3]),'token':sys.argv[4]}))
PY
)"
  curl -fsS "${AUTH_ARGS[@]}" -H 'Content-Type: application/json' -d "$PAYLOAD" "$API" >/dev/null || { echo "$(msg bad)"; return 1; }
  echo "$(msg added)"
}
remove_node(){
  list_nodes || return 1
  local id=''; read_tty id "$(msg id)"; [[ -n "$id" ]] || return 1
  curl -fsS "${AUTH_ARGS[@]}" -X DELETE "$API/$id" >/dev/null || { echo "$(msg bad)"; return 1; }
  echo "$(msg removed)"
}

case "${1:-menu}" in
  list) list_nodes; exit;;
  add) add_node; exit;;
  remove) remove_node; exit;;
  menu) ;;
  *) echo 'Usage: tyxe-pool-node [menu|list|add|remove]' >&2; exit 2;;
esac

while :; do
  printf '\n%s\n%s\n%s\n%s\n%s\n' "$(msg title)" "$(msg menu1)" "$(msg menu2)" "$(msg menu3)" "$(msg menu4)"
  c=''; read_tty c "$(msg choice)"
  case "$c" in 1) list_nodes;; 2) add_node;; 3) remove_node;; 4) exit 0;; *) :;; esac
done
