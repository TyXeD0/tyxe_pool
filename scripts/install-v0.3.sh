#!/usr/bin/env bash
set -Eeuo pipefail

VERSION='0.3.0'
ROOT='/opt/proxy-pool'
ETC='/etc/proxy-pool'
STATE='/var/lib/proxy-pool'
MANIFEST="$STATE/install-manifest"
BACKUP="$STATE/backups"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LANG_CODE="${TYXE_POOL_LANG:-}"
TX_START_LINE=0
CERT_STORE='/var/lib/tyxe-pool-persistent/letsencrypt'
CERT_WORK='/var/lib/tyxe-pool-persistent/acme-work'
CERT_LOGS='/var/lib/tyxe-pool-persistent/acme-logs'

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
section(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
read_tty(){ local __var="$1" __prompt="$2" __silent="${3:-0}" value=''; if [[ "$__silent" == 1 ]]; then read -r -s -p "$__prompt" value </dev/tty || true; printf '\n' >/dev/tty; else read -r -p "$__prompt" value </dev/tty || true; fi; printf -v "$__var" '%s' "$value"; }
ask(){ local prompt="$1" def="${2:-}" v=''; read_tty v "$prompt${def:+ [$def]}: "; printf '%s' "${v:-$def}"; }
yesno(){ local prompt="$1" def="${2:-y}" v=''; while :; do read_tty v "$prompt [y/n] (${def}): "; v="${v:-$def}"; case "$v" in y|Y) return 0;; n|N) return 1;; *) echo 'y/n';; esac; done; }
choice(){ local prompt="$1" min="$2" max="$3" v=''; while :; do read_tty v "$prompt"; if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )); then printf '%s' "$v"; return; fi; red "$(m bad_choice)"; done; }
random_hex(){ head -c "${1:-32}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

choose_language(){
  [[ "$LANG_CODE" =~ ^(ru|en)$ ]] && return
  printf '\nTYXE Pool / Выбор языка\n1) Русский\n2) English\n'
  local v=''
  while :; do read_tty v '> '; case "$v" in 1) LANG_CODE=ru; break;; 2) LANG_CODE=en; break;; *) echo '1 / 2';; esac; done
}

m(){
  local k="$1"
  if [[ "$LANG_CODE" == ru ]]; then
    case "$k" in
      root) echo 'Запустите установщик от root или через sudo.';; title) echo "TYXE Pool Installer v$VERSION";;
      intro) echo 'Мастер настраивает TYXE Pool пошагово. Все управляемые изменения фиксируются для отката; TLS-сертификаты сохраняются между переустановками.';;
      role) echo 'Выберите роль VPS:';; role1) echo '1) ENTER / Controller — входная нода и главная панель';; role2) echo '2) EXIT / Agent — выходная нода с Telemt';;
      proxy_domain) echo 'Домен proxy/selfsteal';; panel_mode) echo 'Доступ к панели:';; panel1) echo '1) Только localhost + SSH-туннель';; panel2) echo '2) Публичная HTTPS-панель с логином и паролем';; panel_domain) echo 'Домен панели';;
      admin_user) echo 'Логин администратора';; admin_pass) echo 'Пароль администратора: ';; admin_pass2) echo 'Повторите пароль: ';; pass_short) echo 'Минимальная длина пароля — 12 символов.';; pass_mismatch) echo 'Пароли не совпадают.';;
      idn) echo 'Обнаружен IDN/Unicode-домен. Для DNS/TLS будет использована ASCII/Punycode форма:';; idn_confirm) echo 'Продолжить с этим именем?';; bad_domain) echo 'Некорректное доменное имя.';;
      node_name) echo 'Имя EXIT-ноды';; agent_bind) echo 'Bind-адрес агента';; agent_port) echo 'Порт агента';; token) echo 'API token агента';;
      telemt_setup) echo 'Настройка Telemt на EXIT:';; telemt1) echo '1) Установить/обновить Telemt сейчас';; telemt2) echo '2) Использовать уже установленный Telemt';; telemt3) echo '3) Пропустить и настроить позже';; telemt_domain) echo 'TLS/SNI домен Telemt';; telemt_port) echo 'Порт Telemt';; telemt_secret) echo 'Секрет первого пользователя (32 HEX; пусто = сгенерировать)';;
      cert) echo 'Сертификат';; cert_found) echo 'Найден существующий сертификат';; cert1) echo '1) Использовать существующий';; cert2) echo '2) Выпустить новый';; cert3) echo '3) Пропустить';; cert_none1) echo '1) Выпустить сертификат Let’s Encrypt';; cert_none2) echo '2) Пока пропустить';; email) echo 'Email Let’s Encrypt (можно оставить пустым)';; issuing) echo 'Запрашиваю сертификат...';; cert_fail) echo 'Не удалось получить сертификат.';;
      add_now) echo 'Добавить EXIT-ноду в controller сейчас?';; done) echo 'Установка завершена.';; bad_choice) echo 'Неверный выбор.';;
    esac
  else
    case "$k" in
      root) echo 'Run the installer as root or with sudo.';; title) echo "TYXE Pool Installer v$VERSION";;
      intro) echo 'This wizard configures TYXE Pool step by step. Managed changes are tracked for rollback; TLS certificates persist across reinstalls.';;
      role) echo 'Choose VPS role:';; role1) echo '1) ENTER / Controller — entry node and central panel';; role2) echo '2) EXIT / Agent — exit node with Telemt';;
      proxy_domain) echo 'Proxy/selfsteal domain';; panel_mode) echo 'Panel access:';; panel1) echo '1) Localhost only + SSH tunnel';; panel2) echo '2) Public HTTPS panel with username/password';; panel_domain) echo 'Panel domain';;
      admin_user) echo 'Administrator username';; admin_pass) echo 'Administrator password: ';; admin_pass2) echo 'Repeat password: ';; pass_short) echo 'Password must be at least 12 characters.';; pass_mismatch) echo 'Passwords do not match.';;
      idn) echo 'IDN/Unicode hostname detected. DNS/TLS will use this ASCII/Punycode form:';; idn_confirm) echo 'Continue with this hostname?';; bad_domain) echo 'Invalid hostname.';;
      node_name) echo 'EXIT node name';; agent_bind) echo 'Agent bind address';; agent_port) echo 'Agent port';; token) echo 'Agent API token';;
      telemt_setup) echo 'Telemt setup on EXIT:';; telemt1) echo '1) Install/update Telemt now';; telemt2) echo '2) Use an existing Telemt installation';; telemt3) echo '3) Skip and configure later';; telemt_domain) echo 'Telemt TLS/SNI domain';; telemt_port) echo 'Telemt port';; telemt_secret) echo 'First user secret (32 HEX; blank = generate)';;
      cert) echo 'Certificate';; cert_found) echo 'Existing certificate found';; cert1) echo '1) Reuse existing certificate';; cert2) echo '2) Issue a new certificate';; cert3) echo '3) Skip';; cert_none1) echo '1) Issue Let’s Encrypt certificate';; cert_none2) echo '2) Skip for now';; email) echo 'Let’s Encrypt email (optional)';; issuing) echo 'Requesting certificate...';; cert_fail) echo 'Certificate issuance failed.';;
      add_now) echo 'Add an EXIT node to controller now?';; done) echo 'Installation complete.';; bad_choice) echo 'Invalid choice.';;
    esac
  fi
}

root_check(){ [[ $EUID -eq 0 ]] || { red "$(m root)"; exit 1; }; }
make_password_hash(){ python3 - "$1" <<'PY'
import hashlib,os,sys
p=sys.argv[1].encode(); s=os.urandom(16); r=600000; d=hashlib.pbkdf2_hmac('sha256',p,s,r)
print(f'pbkdf2_sha256:{r}:{s.hex()}:{d.hex()}')
PY
}

domain_ascii(){
  python3 - "$1" <<'PY'
import sys
s=sys.argv[1].strip().rstrip('.').lower()
try:
    out=s.encode('idna').decode('ascii')
except Exception:
    raise SystemExit(2)
if not out or len(out)>253 or any(len(x)>63 or not x for x in out.split('.')):
    raise SystemExit(2)
print(out)
PY
}
normalize_domain(){
  local raw="$1" out
  out="$(domain_ascii "$raw")" || { red "$(m bad_domain)"; return 1; }
  if [[ "$out" != "$raw" ]]; then yellow "$(m idn) $out"; yesno "$(m idn_confirm)" y || return 1; fi
  printf '%s' "$out"
}

backup_path(){ local p="$1" id b=''; mkdir -p "$BACKUP"; if [[ -e "$p" || -L "$p" ]]; then id=$(printf '%s' "$p"|sed 's#^/##;s#[^A-Za-z0-9._-]#_#g'); b="$BACKUP/$id.$(date +%s%N)"; cp -a "$p" "$b"; printf '%s' "$b"; fi; }
record_path(){ local typ="$1" path="$2" b=''; b=$(backup_path "$path"); printf 'PATH %s|%s|%s\n' "$typ" "$path" "$b" >> "$MANIFEST"; }
record_pkg(){ printf 'PACKAGE %s\n' "$1" >> "$MANIFEST"; }
record_service(){ local s="$1" en ac; en=$(systemctl is-enabled "$s" 2>/dev/null||true); ac=$(systemctl is-active "$s" 2>/dev/null||true); printf 'SERVICE %s|%s|%s\n' "$s" "$en" "$ac" >> "$MANIFEST"; }
ensure_dir(){ [[ -d "$1" ]] || { record_path DIR "$1"; mkdir -p "$1"; }; }
install_file(){ record_path FILE "$2"; install -Dm "${3:-0644}" "$1" "$2"; }
write_file(){ local dst="$1" mode="$2"; shift 2; record_path FILE "$dst"; install -d "$(dirname "$dst")"; printf '%s\n' "$*" > "$dst"; chmod "$mode" "$dst"; }
init_txn(){ mkdir -p "$STATE" "$BACKUP"; touch "$MANIFEST"; TX_START_LINE=$(wc -l < "$MANIFEST"); printf 'BEGIN %s|%s|%s\n' "$VERSION" "$(date -u +%FT%TZ)" "$LANG_CODE" >> "$MANIFEST"; }
on_error(){ local rc=$?; trap - ERR; red "Installer failed / Ошибка установщика ($rc)"; if [[ -x /usr/local/sbin/proxy-pool-rollback ]]; then TYXE_POOL_LANG="$LANG_CODE" /usr/local/sbin/proxy-pool-rollback --since-line "$TX_START_LINE" --lang "$LANG_CODE" || true; fi; exit "$rc"; }
trap on_error ERR

ensure_command(){ local cmd="$1" pkg="$2"; if ! command -v "$cmd" >/dev/null 2>&1; then apt-get install -y "$pkg"; record_pkg "$pkg"; hash -r; fi; command -v "$cmd" >/dev/null 2>&1 || { red "$cmd command not found"; return 1; }; }

detect_cert_source(){ local d="$1"; [[ -s "$CERT_STORE/live/$d/fullchain.pem" ]] && { printf '%s' "$CERT_STORE"; return; }; [[ -s "/etc/letsencrypt/live/$d/fullchain.pem" ]] && printf '/etc/letsencrypt'; }
cert_exists(){ local s; s=$(detect_cert_source "$1"); [[ -n "$s" && -s "$s/live/$1/fullchain.pem" && -s "$s/live/$1/privkey.pem" ]]; }
issue_cert(){ local d="$1" email="$2"; mkdir -p "$CERT_STORE" "$CERT_WORK" "$CERT_LOGS"; local a=(certonly --webroot -w /var/www/proxy-pool-selfsteal -d "$d" --cert-name "$d" --agree-tos --non-interactive --no-eff-email --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS"); [[ -n "$email" ]] && a+=(--email "$email") || a+=(--register-unsafely-without-email); certbot "${a[@]}"; }
CERT_RESULT='skip'
choose_cert(){
  local d="$1" mode='skip' c email=''
  section "$(m cert): $d"
  if cert_exists "$d"; then
    green "$(m cert_found): $d"; printf '%s\n%s\n%s\n' "$(m cert1)" "$(m cert2)" "$(m cert3)"; c=$(choice '> ' 1 3); case "$c" in 1) mode=existing;;2) mode=new;;3) mode=skip;;esac
  else
    printf '%s\n%s\n' "$(m cert_none1)" "$(m cert_none2)"; c=$(choice '> ' 1 2); [[ "$c" == 1 ]] && mode=new
  fi
  if [[ "$mode" == new ]]; then email=$(ask "$(m email)" ''); yellow "$(m issuing)"; if issue_cert "$d" "$email"; then mode=existing; else red "$(m cert_fail)"; mode=skip; fi; fi
  CERT_RESULT="$mode"
}

choose_language; export TYXE_POOL_LANG="$LANG_CODE"; root_check
section "$(m title)"; echo "$(m intro)"
. /etc/os-release || true
case "${ID:-}" in ubuntu|debian) ;; *) red 'Ubuntu/Debian only'; exit 1;; esac

printf '%s\n%s\n%s\n' "$(m role)" "$(m role1)" "$(m role2)"
rc=$(choice '> ' 1 2); [[ "$rc" == 1 ]] && ROLE=controller || ROLE=agent

PROXY_DOMAIN=''; PANEL_DOMAIN=''; PANEL_MODE=local; PANEL_PORT=9101; ADMIN_USER=admin; ADMIN_HASH=''; SESSION_SECRET=''; LOCAL_API_TOKEN=''; COOKIE_SECURE=0
NODE_NAME="$(hostname -s)"; AGENT_BIND='0.0.0.0'; AGENT_PORT=9100; AGENT_TOKEN="$(random_hex 24)"; TELEMT_SERVICE=telemt; TELEMT_CONFIG='/etc/telemt/telemt.toml'; TELEMT_SETUP=skip; TELEMT_DOMAIN='petrovich.ru'; TELEMT_PORT=443; TELEMT_SECRET=''

if [[ "$ROLE" == controller ]]; then
  while :; do raw=$(ask "$(m proxy_domain)" 'example.com'); PROXY_DOMAIN=$(normalize_domain "$raw") && break; done
  printf '%s\n%s\n%s\n' "$(m panel_mode)" "$(m panel1)" "$(m panel2)"; pm=$(choice '> ' 1 2); [[ "$pm" == 2 ]] && PANEL_MODE=public
  if [[ "$PANEL_MODE" == public ]]; then while :; do raw=$(ask "$(m panel_domain)" "panel.$PROXY_DOMAIN"); PANEL_DOMAIN=$(normalize_domain "$raw") && break; done; COOKIE_SECURE=1; fi
  ADMIN_USER=$(ask "$(m admin_user)" 'admin')
  [[ "$ADMIN_USER" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || { red 'Invalid admin username'; exit 1; }
  while :; do read_tty p1 "$(m admin_pass)" 1; (( ${#p1} >= 12 )) || { red "$(m pass_short)"; continue; }; read_tty p2 "$(m admin_pass2)" 1; [[ "$p1" == "$p2" ]] || { red "$(m pass_mismatch)"; continue; }; break; done
  ADMIN_HASH=$(make_password_hash "$p1"); unset p1 p2; SESSION_SECRET=$(random_hex 32); LOCAL_API_TOKEN=$(random_hex 32)
else
  NODE_NAME=$(ask "$(m node_name)" "$NODE_NAME"); AGENT_BIND=$(ask "$(m agent_bind)" '0.0.0.0'); AGENT_PORT=$(ask "$(m agent_port)" '9100')
  printf '%s\n%s\n%s\n%s\n' "$(m telemt_setup)" "$(m telemt1)" "$(m telemt2)" "$(m telemt3)"; ts=$(choice '> ' 1 3)
  case "$ts" in 1) TELEMT_SETUP=install;;2) TELEMT_SETUP=existing;;3) TELEMT_SETUP=skip;;esac
  if [[ "$TELEMT_SETUP" == install ]]; then
    TELEMT_DOMAIN=$(ask "$(m telemt_domain)" 'petrovich.ru'); TELEMT_PORT=$(ask "$(m telemt_port)" '443'); read_tty TELEMT_SECRET "$(m telemt_secret): " 1
    [[ "$TELEMT_PORT" =~ ^[0-9]+$ ]] && (( TELEMT_PORT>=1 && TELEMT_PORT<=65535 )) || { red 'Invalid Telemt port'; exit 1; }
    [[ -z "$TELEMT_SECRET" || "$TELEMT_SECRET" =~ ^[0-9a-fA-F]{32}$ ]] || { red 'Telemt secret must be 32 HEX chars'; exit 1; }
  fi
fi

init_txn
record_path FILE /usr/local/sbin/proxy-pool-rollback; install -m 0755 "$SCRIPT_DIR/../rollback.sh" /usr/local/sbin/proxy-pool-rollback
apt-get update -y
for pair in 'curl curl' 'python3 python3' 'openssl openssl' 'nginx nginx'; do set -- $pair; ensure_command "$1" "$2"; done
if [[ "$ROLE" == controller ]]; then ensure_command certbot certbot; ensure_command haproxy haproxy; fi
ensure_dir "$ETC"; ensure_dir "$ROOT"

if [[ "$ROLE" == controller ]]; then
  ensure_dir "$ROOT/controller"; install_file "$SCRIPT_DIR/../controller/controller.py" "$ROOT/controller/controller.py" 0755; install_file "$SCRIPT_DIR/node-manager.sh" /usr/local/sbin/tyxe-pool-node 0755
  ensure_dir /var/www/proxy-pool-selfsteal; ensure_dir "$ETC/selfsteal"
  [[ "$LANG_CODE" == ru ]] && html='<html lang="ru"><head><meta charset="utf-8"><title>Добро пожаловать</title></head><body><h1>Добро пожаловать</h1><p>Сайт находится в разработке.</p></body></html>' || html='<html lang="en"><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>Welcome</h1><p>This website is under construction.</p></body></html>'
  write_file /var/www/proxy-pool-selfsteal/index.html 0644 "$html"
  SETTINGS="TYXE_POOL_LANG=$LANG_CODE
PROXY_POOL_LANG=$LANG_CODE
PROXY_POOL_ROLE=controller
PROXY_POOL_HOME=$ETC
PROXY_POOL_BIND=127.0.0.1
PROXY_POOL_PORT=$PANEL_PORT
PROXY_POOL_PROXY_DOMAIN=$PROXY_DOMAIN
PROXY_POOL_PANEL_DOMAIN=$PANEL_DOMAIN
PROXY_POOL_PANEL_MODE=$PANEL_MODE
PROXY_POOL_ADMIN_USER=$ADMIN_USER
PROXY_POOL_ADMIN_HASH=$ADMIN_HASH
PROXY_POOL_SESSION_SECRET=$SESSION_SECRET
PROXY_POOL_LOCAL_API_TOKEN=$LOCAL_API_TOKEN
PROXY_POOL_COOKIE_SECURE=$COOKIE_SECURE
PROXY_POOL_SESSION_TTL=43200
PROXY_POOL_POLL_INTERVAL=5"
  write_file "$ETC/settings.env" 0600 "$SETTINGS"
  install_file "$SCRIPT_DIR/../systemd/proxy-pool-controller.service" /etc/systemd/system/proxy-pool-controller.service 0644; record_service proxy-pool-controller
  NGINX_BASE="server { listen 80; listen [::]:80; server_name $PROXY_DOMAIN; root /var/www/proxy-pool-selfsteal; location /.well-known/acme-challenge/ { allow all; } location / { try_files \$uri /index.html; } }"
  NGINX="$NGINX_BASE"
  [[ "$PANEL_MODE" == public ]] && NGINX+="\nserver { listen 80; listen [::]:80; server_name $PANEL_DOMAIN; root /var/www/proxy-pool-selfsteal; location /.well-known/acme-challenge/ { allow all; } location / { return 404; } }"
  write_file "$ETC/selfsteal/nginx.conf" 0644 "$NGINX"; record_path FILE /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf; ln -sfn "$ETC/selfsteal/nginx.conf" /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf; nginx -t; systemctl reload nginx
  systemctl daemon-reload; systemctl enable --now proxy-pool-controller
  choose_cert "$PROXY_DOMAIN"; cm="$CERT_RESULT"
  if [[ "$PANEL_MODE" == public ]]; then
    choose_cert "$PANEL_DOMAIN"; pcm="$CERT_RESULT"
    if [[ "$pcm" == existing ]]; then
      src=$(detect_cert_source "$PANEL_DOMAIN"); cert="$src/live/$PANEL_DOMAIN/fullchain.pem"; key="$src/live/$PANEL_DOMAIN/privkey.pem"
      NGINX="$NGINX_BASE\nserver { listen 443 ssl; listen [::]:443 ssl; server_name $PANEL_DOMAIN; ssl_certificate $cert; ssl_certificate_key $key; ssl_protocols TLSv1.2 TLSv1.3; add_header X-Content-Type-Options nosniff always; add_header X-Frame-Options DENY always; location / { proxy_pass http://127.0.0.1:$PANEL_PORT; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-Proto https; } }
server { listen 80; listen [::]:80; server_name $PANEL_DOMAIN; location /.well-known/acme-challenge/ { root /var/www/proxy-pool-selfsteal; } location / { return 301 https://\$host\$request_uri; } }"
      write_file "$ETC/selfsteal/nginx.conf" 0644 "$NGINX"; nginx -t; systemctl reload nginx
    else
      yellow 'Panel TLS unavailable; keeping controller on localhost.'; printf '\nPROXY_POOL_PANEL_MODE=local\nPROXY_POOL_COOKIE_SECURE=0\n' >> "$ETC/settings.env"; PANEL_MODE=local; systemctl restart proxy-pool-controller
    fi
  fi
else
  ensure_dir "$ROOT/agent"; install_file "$SCRIPT_DIR/../agent/agent.py" "$ROOT/agent/agent.py" 0755; install_file "$SCRIPT_DIR/telemt-manager.sh" /usr/local/sbin/tyxe-telemt 0755
  SETTINGS="TYXE_POOL_LANG=$LANG_CODE
PROXY_POOL_LANG=$LANG_CODE
PROXY_POOL_ROLE=agent
PROXY_POOL_AGENT_BIND=$AGENT_BIND
PROXY_POOL_AGENT_PORT=$AGENT_PORT
PROXY_POOL_TELEMT_SERVICE=$TELEMT_SERVICE
PROXY_POOL_TELEMT_CONFIG=$TELEMT_CONFIG
PROXY_POOL_TELEMT_BIN=/bin/telemt
PROXY_POOL_NODE_NAME=$NODE_NAME
PROXY_POOL_AGENT_TOKEN=$AGENT_TOKEN"
  write_file "$ETC/settings.env" 0600 "$SETTINGS"; install_file "$SCRIPT_DIR/../systemd/proxy-pool-agent.service" /etc/systemd/system/proxy-pool-agent.service 0644; record_service proxy-pool-agent
  if [[ "$TELEMT_SETUP" == install ]]; then
    record_path DIR /etc/telemt; record_path DIR /opt/telemt; record_path FILE /etc/systemd/system/telemt.service; record_path FILE /lib/systemd/system/telemt.service; record_path FILE /bin/telemt; record_path FILE /usr/bin/telemt
    args=(--lang "$LANG_CODE" --domain "$TELEMT_DOMAIN" --port "$TELEMT_PORT"); [[ -n "$TELEMT_SECRET" ]] && args+=(--secret "$TELEMT_SECRET")
    curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | bash -s -- "${args[@]}"
  fi
  systemctl daemon-reload; systemctl enable --now proxy-pool-agent
fi

section 'Final checks'
if [[ "$ROLE" == controller ]]; then
  systemctl is-active --quiet proxy-pool-controller; curl -fsS "http://127.0.0.1:$PANEL_PORT/healthz" >/dev/null; green "$(m done)"
  [[ "$PANEL_MODE" == public ]] && echo "Panel: https://$PANEL_DOMAIN/" || echo "Panel: http://127.0.0.1:$PANEL_PORT/"
  if yesno "$(m add_now)" n; then /usr/local/sbin/tyxe-pool-node add || true; fi
else
  systemctl is-active --quiet proxy-pool-agent; curl -fsS "http://127.0.0.1:$AGENT_PORT/healthz" >/dev/null; green "$(m done)"; echo "$(m token): $AGENT_TOKEN"; echo 'Telemt manager: sudo tyxe-telemt'
fi
printf 'Rollback preview: sudo /usr/local/sbin/proxy-pool-rollback --dry-run\nFull rollback: sudo /usr/local/sbin/proxy-pool-rollback --purge-state\n'
