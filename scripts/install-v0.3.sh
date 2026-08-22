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
# stderr is intentional: warnings must never contaminate values captured with $(...).
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
section(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
read_tty(){ local __var="$1" __prompt="$2" __silent="${3:-0}" value=''; if [[ "$__silent" == 1 ]]; then read -r -s -p "$__prompt" value </dev/tty || true; printf '\n' >/dev/tty; else read -r -p "$__prompt" value </dev/tty || true; fi; printf -v "$__var" '%s' "$value"; }
ask(){ local prompt="$1" def="${2:-}" v=''; read_tty v "$prompt${def:+ [$def]}: "; printf '%s' "${v:-$def}"; }
yesno(){ local prompt="$1" def="${2:-y}" v=''; while :; do read_tty v "$prompt [y/n] (${def}): "; v="${v:-$def}"; case "$v" in y|Y) return 0;; n|N) return 1;; *) printf 'y/n\n' >/dev/tty;; esac; done; }
choice(){ local prompt="$1" min="$2" max="$3" v=''; while :; do read_tty v "$prompt"; if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )); then printf '%s' "$v"; return; fi; red "$(m bad_choice)"; done; }
random_hex(){ head -c "${1:-32}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

choose_language(){
  [[ "$LANG_CODE" =~ ^(ru|en)$ ]] && return
  printf '\nTYXE Pool / Выбор языка\n1) Русский\n2) English\n'
  local v=''
  while :; do read_tty v '> '; case "$v" in 1) LANG_CODE=ru; break;; 2) LANG_CODE=en; break;; *) printf '1 / 2\n' >/dev/tty;; esac; done
}

m(){
  local k="$1"
  if [[ "$LANG_CODE" == ru ]]; then
    case "$k" in
      root) echo 'Запустите установщик от root или через sudo.';;
      title) echo "TYXE Pool Installer v$VERSION";;
      intro) cat <<'TXT'
Мастер настраивает TYXE Pool пошагово. Перед изменениями будет показано, что именно настраивается.
Файлы, сервисы и пакеты, которыми управляет TYXE Pool, записываются в manifest для отката.
Сертификаты Let’s Encrypt намеренно хранятся отдельно и переживают rollback/uninstall, чтобы не расходовать лимиты повторной выдачей.
Текущий этап разработки использует одну ENTER-ноду и одну EXIT-ноду.
TXT
      ;;
      existing) echo 'Обнаружена существующая установка TYXE Pool.';;
      ex1) echo '1) Повторно запустить мастер / обновить компоненты';; ex2) echo '2) Управление нодами (ENTER)';; ex3) echo '3) Управление Telemt (EXIT)';; ex4) echo '4) Выйти';;
      role) echo 'Выберите роль этого VPS:';; role1) echo '1) ENTER / Controller — входная нода, selfsteal и главная веб-панель';; role2) echo '2) EXIT / Agent — выходная нода, агент и Telemt';;
      proxy_desc) echo 'Домен proxy/selfsteal должен указывать на ENTER VPS. Постороннему HTTPS-клиенту этот hostname показывает обычный сайт-заглушку.';; proxy_domain) echo 'Домен proxy/selfsteal';;
      panel_desc) echo 'Панель можно оставить только на localhost или опубликовать через отдельный HTTPS hostname с обязательной авторизацией.';; panel_mode) echo 'Доступ к панели:';; panel1) echo '1) Только localhost + SSH-туннель';; panel2) echo '2) Публичная HTTPS-панель с логином и паролем';; panel_domain) echo 'Домен панели';; panel_same) echo 'Домен панели должен отличаться от домена proxy/selfsteal.';;
      admin_desc) echo 'Создайте администратора панели. Пароль на диск не записывается: сохраняется только PBKDF2-SHA256 hash.';; admin_user) echo 'Логин администратора';; admin_pass) echo 'Пароль администратора: ';; admin_pass2) echo 'Повторите пароль: ';; pass_short) echo 'Минимальная длина пароля — 12 символов.';; pass_mismatch) echo 'Пароли не совпадают.';; bad_user) echo 'Логин: 3–32 символа, латинские буквы, цифры, точка, _ или -.';;
      idn) echo 'Имя содержит Unicode/IDN или требует нормализации. Для DNS/nginx/Certbot будет использована ASCII/Punycode форма:';; idn_confirm) echo 'Использовать эту форму?';; bad_domain) echo 'Некорректное доменное имя.';;
      node_desc) echo 'Agent API пока может слушать публичный адрес, но защищён bearer-token. После AWG перенесём его на туннельный адрес.';; node_name) echo 'Имя EXIT-ноды';; agent_bind) echo 'Bind-адрес агента';; agent_port) echo 'Порт агента';; token) echo 'API token агента';;
      telemt_setup) echo 'Что сделать с Telemt на EXIT?';; telemt1) echo '1) Установить/обновить Telemt сейчас официальным installer telemt';; telemt2) echo '2) Использовать уже установленный Telemt';; telemt3) echo '3) Пропустить и настроить позже через tyxe-telemt';; telemt_domain) echo 'TLS/SNI домен Telemt';; telemt_port) echo 'Порт Telemt';; telemt_secret) echo 'Секрет первого пользователя (32 HEX; пусто = Telemt сгенерирует)';; telemt_existing_missing) echo 'Выбрано «использовать существующий», но сервис/binary Telemt не обнаружен. Продолжить всё равно?';;
      deps) echo 'Проверка зависимостей';; app) echo 'Установка компонентов TYXE Pool';; cert) echo 'Сертификат';; cert_found) echo 'Найден существующий сертификат';; cert1) echo '1) Использовать существующий (рекомендуется)';; cert2) echo '2) Выпустить новый';; cert3) echo '3) Пропустить';; cert_none1) echo '1) Выпустить сертификат Let’s Encrypt';; cert_none2) echo '2) Пока пропустить';; email) echo 'Email Let’s Encrypt (можно оставить пустым)';; issuing) echo 'Запрашиваю сертификат...';; cert_fail) echo 'Не удалось получить сертификат.';; cert_dns) echo 'Для HTTP-01 DNS должен указывать на этот VPS, а TCP/80 должен быть доступен из Интернета.';;
      add_now) echo 'Добавить EXIT-ноду в controller сейчас?';; done) echo 'Установка завершена.';; bad_choice) echo 'Неверный выбор.';;
    esac
  else
    case "$k" in
      root) echo 'Run the installer as root or with sudo.';; title) echo "TYXE Pool Installer v$VERSION";;
      intro) cat <<'TXT'
This wizard configures TYXE Pool step by step and explains each major change.
Files, services and packages managed by TYXE Pool are tracked in a rollback manifest.
Let’s Encrypt certificates intentionally live outside rollback/uninstall so repeated tests do not waste issuance limits.
The current stabilization milestone uses one ENTER node and one EXIT node.
TXT
      ;;
      existing) echo 'An existing TYXE Pool installation was detected.';; ex1) echo '1) Run setup again / update components';; ex2) echo '2) Manage nodes (ENTER)';; ex3) echo '3) Manage Telemt (EXIT)';; ex4) echo '4) Exit';;
      role) echo 'Choose the role of this VPS:';; role1) echo '1) ENTER / Controller — entry node, selfsteal and central web panel';; role2) echo '2) EXIT / Agent — exit node, agent and Telemt';;
      proxy_desc) echo 'The proxy/selfsteal hostname must resolve to the ENTER VPS. Ordinary HTTPS visitors see only a normal decoy website.';; proxy_domain) echo 'Proxy/selfsteal domain';;
      panel_desc) echo 'The panel can remain localhost-only or be published on a separate HTTPS hostname with mandatory authentication.';; panel_mode) echo 'Panel access:';; panel1) echo '1) Localhost only + SSH tunnel';; panel2) echo '2) Public HTTPS panel with username/password';; panel_domain) echo 'Panel domain';; panel_same) echo 'Panel domain must differ from proxy/selfsteal domain.';;
      admin_desc) echo 'Create the panel administrator. The plaintext password is never stored; only a PBKDF2-SHA256 hash is saved.';; admin_user) echo 'Administrator username';; admin_pass) echo 'Administrator password: ';; admin_pass2) echo 'Repeat password: ';; pass_short) echo 'Password must be at least 12 characters.';; pass_mismatch) echo 'Passwords do not match.';; bad_user) echo 'Username: 3–32 characters, letters, digits, dot, _ or -.';;
      idn) echo 'The hostname contains Unicode/IDN or needs normalization. DNS/nginx/Certbot will use this ASCII/Punycode form:';; idn_confirm) echo 'Use this form?';; bad_domain) echo 'Invalid hostname.';;
      node_desc) echo 'The agent API may temporarily bind publicly, protected by a bearer token. After AWG it will move to the tunnel address.';; node_name) echo 'EXIT node name';; agent_bind) echo 'Agent bind address';; agent_port) echo 'Agent port';; token) echo 'Agent API token';;
      telemt_setup) echo 'What should be done with Telemt on EXIT?';; telemt1) echo '1) Install/update Telemt now using the official telemt installer';; telemt2) echo '2) Use an existing Telemt installation';; telemt3) echo '3) Skip and configure later with tyxe-telemt';; telemt_domain) echo 'Telemt TLS/SNI domain';; telemt_port) echo 'Telemt port';; telemt_secret) echo 'First user secret (32 HEX; blank = let Telemt generate)';; telemt_existing_missing) echo 'Existing Telemt was selected but no service/binary was detected. Continue anyway?';;
      deps) echo 'Dependency checks';; app) echo 'Installing TYXE Pool components';; cert) echo 'Certificate';; cert_found) echo 'Existing certificate found';; cert1) echo '1) Reuse existing (recommended)';; cert2) echo '2) Issue a new certificate';; cert3) echo '3) Skip';; cert_none1) echo '1) Issue a Let’s Encrypt certificate';; cert_none2) echo '2) Skip for now';; email) echo 'Let’s Encrypt email (optional)';; issuing) echo 'Requesting certificate...';; cert_fail) echo 'Certificate issuance failed.';; cert_dns) echo 'For HTTP-01, DNS must resolve to this VPS and TCP/80 must be reachable from the Internet.';;
      add_now) echo 'Add the EXIT node to controller now?';; done) echo 'Installation complete.';; bad_choice) echo 'Invalid choice.';;
    esac
  fi
}

root_check(){ [[ $EUID -eq 0 ]] || { red "$(m root)"; exit 1; }; }
make_password_hash(){ python3 - "$1" <<'PY'
import hashlib,os,sys
pw=sys.argv[1].encode(); salt=os.urandom(16); rounds=600000
d=hashlib.pbkdf2_hmac('sha256',pw,salt,rounds)
print(f'pbkdf2_sha256:{rounds}:{salt.hex()}:{d.hex()}')
PY
}

domain_ascii(){
  python3 - "$1" <<'PY'
import re,sys
raw=sys.argv[1].strip().rstrip('.')
try: out=raw.lower().encode('idna').decode('ascii')
except Exception: raise SystemExit(2)
if not out or len(out)>253: raise SystemExit(2)
for label in out.split('.'):
    if not label or len(label)>63 or label.startswith('-') or label.endswith('-') or not re.fullmatch(r'[a-z0-9-]+',label): raise SystemExit(2)
if '.' not in out: raise SystemExit(2)
print(out)
PY
}
normalize_domain(){
  local raw="$1" out clean
  clean="${raw%.}"
  out="$(domain_ascii "$clean")" || { red "$(m bad_domain)"; return 1; }
  if [[ "$out" != "${clean,,}" ]]; then yellow "$(m idn) $out"; yesno "$(m idn_confirm)" y || return 1; fi
  printf '%s' "$out"
}

backup_path(){ local p="$1" id b=''; mkdir -p "$BACKUP"; if [[ -e "$p" || -L "$p" ]]; then id=$(printf '%s' "$p"|sed 's#^/##;s#[^A-Za-z0-9._-]#_#g'); b="$BACKUP/$id.$(date +%s%N)"; cp -a "$p" "$b"; printf '%s' "$b"; fi; }
record_path(){ local typ="$1" path="$2" b=''; b=$(backup_path "$path"); printf 'PATH %s|%s|%s\n' "$typ" "$path" "$b" >> "$MANIFEST"; }
record_pkg(){ printf 'PACKAGE %s\n' "$1" >> "$MANIFEST"; }
record_service(){ local s="$1" en ac; en=$(systemctl is-enabled "$s" 2>/dev/null||true); ac=$(systemctl is-active "$s" 2>/dev/null||true); printf 'SERVICE %s|%s|%s\n' "$s" "$en" "$ac" >> "$MANIFEST"; }
record_entity_if_absent(){ local type="$1" name="$2"; case "$type" in USER) getent passwd "$name" >/dev/null 2>&1 || printf 'USER %s\n' "$name" >> "$MANIFEST";; GROUP) getent group "$name" >/dev/null 2>&1 || printf 'GROUP %s\n' "$name" >> "$MANIFEST";; esac; }
ensure_dir(){ [[ -d "$1" ]] || { record_path DIR "$1"; mkdir -p "$1"; }; }
install_file(){ record_path FILE "$2"; install -Dm "${3:-0644}" "$1" "$2"; }
write_file(){ local dst="$1" mode="$2" content="$3"; record_path FILE "$dst"; install -d "$(dirname "$dst")"; printf '%s\n' "$content" > "$dst"; chmod "$mode" "$dst"; }
init_txn(){ mkdir -p "$STATE" "$BACKUP"; touch "$MANIFEST"; TX_START_LINE=$(wc -l < "$MANIFEST"); printf 'BEGIN %s|%s|%s\n' "$VERSION" "$(date -u +%FT%TZ)" "$LANG_CODE" >> "$MANIFEST"; }
on_error(){ local rc=$?; trap - ERR; red "Installer failed / Ошибка установщика ($rc)"; if [[ -x /usr/local/sbin/proxy-pool-rollback ]]; then TYXE_POOL_LANG="$LANG_CODE" /usr/local/sbin/proxy-pool-rollback --since-line "$TX_START_LINE" --lang "$LANG_CODE" || true; fi; exit "$rc"; }
trap on_error ERR

ensure_command(){ local cmd="$1" pkg="$2" was=0; command -v "$cmd" >/dev/null 2>&1 && return 0; dpkg -s "$pkg" >/dev/null 2>&1 && was=1 || true; apt-get install -y ${was:+--reinstall} "$pkg"; (( was == 0 )) && record_pkg "$pkg"; hash -r; command -v "$cmd" >/dev/null 2>&1 || { red "$cmd command not found"; return 1; }; }

detect_cert_source(){ local d="$1"; [[ -s "$CERT_STORE/live/$d/fullchain.pem" ]] && { printf '%s' "$CERT_STORE"; return; }; [[ -s "/etc/letsencrypt/live/$d/fullchain.pem" ]] && printf '/etc/letsencrypt'; }
cert_exists(){ local s; s=$(detect_cert_source "$1"); [[ -n "$s" && -s "$s/live/$1/fullchain.pem" && -s "$s/live/$1/privkey.pem" ]]; }
issue_cert(){ local d="$1" email="$2"; mkdir -p "$CERT_STORE" "$CERT_WORK" "$CERT_LOGS"; local a=(certonly --webroot -w /var/www/proxy-pool-selfsteal -d "$d" --cert-name "$d" --agree-tos --non-interactive --no-eff-email --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS"); [[ -n "$email" ]] && a+=(--email "$email") || a+=(--register-unsafely-without-email); certbot "${a[@]}"; }
CERT_RESULT='skip'
choose_cert(){
  local d="$1" mode='skip' c email=''
  section "$(m cert): $d"; yellow "$(m cert_dns)"
  if cert_exists "$d"; then green "$(m cert_found): $d"; printf '%s\n%s\n%s\n' "$(m cert1)" "$(m cert2)" "$(m cert3)"; c=$(choice '> ' 1 3); case "$c" in 1) mode=existing;;2) mode=new;;3) mode=skip;;esac
  else printf '%s\n%s\n' "$(m cert_none1)" "$(m cert_none2)"; c=$(choice '> ' 1 2); [[ "$c" == 1 ]] && mode=new; fi
  if [[ "$mode" == new ]]; then email=$(ask "$(m email)" ''); yellow "$(m issuing)"; if issue_cert "$d" "$email"; then mode=existing; else red "$(m cert_fail)"; mode=skip; fi; fi
  CERT_RESULT="$mode"
}

choose_language; export TYXE_POOL_LANG="$LANG_CODE"; root_check
section "$(m title)"; m intro

if [[ -f "$ETC/settings.env" ]]; then
  yellow "$(m existing)"; printf '%s\n%s\n%s\n%s\n' "$(m ex1)" "$(m ex2)" "$(m ex3)" "$(m ex4)"; ec=$(choice '> ' 1 4)
  case "$ec" in
    2) [[ -x /usr/local/sbin/tyxe-pool-node ]] && exec /usr/local/sbin/tyxe-pool-node menu || { red 'Node manager not installed'; exit 1; };;
    3) [[ -x /usr/local/sbin/tyxe-telemt ]] && exec /usr/local/sbin/tyxe-telemt menu || { red 'Telemt manager not installed'; exit 1; };;
    4) exit 0;;
  esac
fi

. /etc/os-release || true
case "${ID:-}" in ubuntu|debian) ;; *) red 'Ubuntu/Debian only'; exit 1;; esac

printf '%s\n%s\n%s\n' "$(m role)" "$(m role1)" "$(m role2)"; rc=$(choice '> ' 1 2); [[ "$rc" == 1 ]] && ROLE=controller || ROLE=agent
PROXY_DOMAIN=''; PANEL_DOMAIN=''; PANEL_MODE=local; PANEL_PORT=9101; ADMIN_USER=admin; ADMIN_HASH=''; SESSION_SECRET=''; LOCAL_API_TOKEN=''; COOKIE_SECURE=0
NODE_NAME="$(hostname -s)"; AGENT_BIND='0.0.0.0'; AGENT_PORT=9100; AGENT_TOKEN="$(random_hex 24)"; TELEMT_SERVICE=telemt; TELEMT_CONFIG='/etc/telemt/telemt.toml'; TELEMT_SETUP=skip; TELEMT_DOMAIN='petrovich.ru'; TELEMT_PORT=443; TELEMT_SECRET=''

if [[ "$ROLE" == controller ]]; then
  echo "$(m proxy_desc)"
  while :; do raw=$(ask "$(m proxy_domain)" 'example.com'); PROXY_DOMAIN=$(normalize_domain "$raw") && break; done
  echo "$(m panel_desc)"; printf '%s\n%s\n%s\n' "$(m panel_mode)" "$(m panel1)" "$(m panel2)"; pm=$(choice '> ' 1 2); [[ "$pm" == 2 ]] && PANEL_MODE=public
  if [[ "$PANEL_MODE" == public ]]; then
    while :; do raw=$(ask "$(m panel_domain)" "panel.$PROXY_DOMAIN"); PANEL_DOMAIN=$(normalize_domain "$raw") || continue; [[ "$PANEL_DOMAIN" != "$PROXY_DOMAIN" ]] || { red "$(m panel_same)"; continue; }; break; done; COOKIE_SECURE=1
  fi
  echo "$(m admin_desc)"
  while :; do ADMIN_USER=$(ask "$(m admin_user)" 'admin'); [[ "$ADMIN_USER" =~ ^[A-Za-z0-9._-]{3,32}$ ]] && break; red "$(m bad_user)"; done
  while :; do read_tty p1 "$(m admin_pass)" 1; (( ${#p1} >= 12 )) || { red "$(m pass_short)"; continue; }; read_tty p2 "$(m admin_pass2)" 1; [[ "$p1" == "$p2" ]] || { red "$(m pass_mismatch)"; continue; }; break; done
  ADMIN_HASH=$(make_password_hash "$p1"); unset p1 p2; SESSION_SECRET=$(random_hex 32); LOCAL_API_TOKEN=$(random_hex 32)
else
  echo "$(m node_desc)"; NODE_NAME=$(ask "$(m node_name)" "$NODE_NAME"); AGENT_BIND=$(ask "$(m agent_bind)" '0.0.0.0'); AGENT_PORT=$(ask "$(m agent_port)" '9100')
  [[ "$AGENT_PORT" =~ ^[0-9]+$ ]] && (( AGENT_PORT>=1 && AGENT_PORT<=65535 )) || { red 'Invalid agent port'; exit 1; }
  printf '%s\n%s\n%s\n%s\n' "$(m telemt_setup)" "$(m telemt1)" "$(m telemt2)" "$(m telemt3)"; ts=$(choice '> ' 1 3); case "$ts" in 1) TELEMT_SETUP=install;;2) TELEMT_SETUP=existing;;3) TELEMT_SETUP=skip;;esac
  if [[ "$TELEMT_SETUP" == install ]]; then
    while :; do raw=$(ask "$(m telemt_domain)" 'petrovich.ru'); TELEMT_DOMAIN=$(normalize_domain "$raw") && break; done
    TELEMT_PORT=$(ask "$(m telemt_port)" '443'); read_tty TELEMT_SECRET "$(m telemt_secret): " 1
    [[ "$TELEMT_PORT" =~ ^[0-9]+$ ]] && (( TELEMT_PORT>=1 && TELEMT_PORT<=65535 )) || { red 'Invalid Telemt port'; exit 1; }
    [[ -z "$TELEMT_SECRET" || "$TELEMT_SECRET" =~ ^[0-9a-fA-F]{32}$ ]] || { red 'Telemt secret must be exactly 32 HEX chars'; exit 1; }
  elif [[ "$TELEMT_SETUP" == existing ]]; then
    if ! command -v telemt >/dev/null 2>&1 && [[ ! -x /bin/telemt ]] && ! systemctl cat telemt >/dev/null 2>&1; then yesno "$(m telemt_existing_missing)" n || exit 1; fi
  fi
fi

init_txn
record_path FILE /usr/local/sbin/proxy-pool-rollback; install -m 0755 "$SCRIPT_DIR/../rollback.sh" /usr/local/sbin/proxy-pool-rollback
section "$(m deps)"; apt-get update -y
ensure_command curl curl; ensure_command python3 python3
if [[ "$ROLE" == controller ]]; then ensure_command openssl openssl; ensure_command nginx nginx; ensure_command certbot certbot; ensure_command haproxy haproxy; fi
ensure_dir "$ETC"; ensure_dir "$ROOT"

section "$(m app)"
if [[ "$ROLE" == controller ]]; then
  ensure_dir "$ROOT/controller"; install_file "$SCRIPT_DIR/../controller/controller.py" "$ROOT/controller/controller.py" 0755; install_file "$SCRIPT_DIR/node-manager.sh" /usr/local/sbin/tyxe-pool-node 0755
  ensure_dir /var/www/proxy-pool-selfsteal; ensure_dir "$ETC/selfsteal"
  if [[ "$LANG_CODE" == ru ]]; then SITE_HTML='<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Добро пожаловать</title><style>body{font-family:system-ui,-apple-system,sans-serif;max-width:760px;margin:12vh auto;padding:24px;color:#222;background:#fafafa}main{background:#fff;padding:32px;border-radius:16px;border:1px solid #e5e7eb}</style></head><body><main><h1>Добро пожаловать</h1><p>Сайт находится в разработке.</p></main></body></html>'; else SITE_HTML='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title><style>body{font-family:system-ui,-apple-system,sans-serif;max-width:760px;margin:12vh auto;padding:24px;color:#222;background:#fafafa}main{background:#fff;padding:32px;border-radius:16px;border:1px solid #e5e7eb}</style></head><body><main><h1>Welcome</h1><p>This website is currently under construction.</p></main></body></html>'; fi
  write_file /var/www/proxy-pool-selfsteal/index.html 0644 "$SITE_HTML"
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
PROXY_POOL_POLL_INTERVAL=5
PROXY_POOL_MAX_NODES=1"
  write_file "$ETC/settings.env" 0600 "$SETTINGS"; install_file "$SCRIPT_DIR/../systemd/proxy-pool-controller.service" /etc/systemd/system/proxy-pool-controller.service 0644; record_service proxy-pool-controller

  NGINX_HTTP="server { listen 80; listen [::]:80; server_name $PROXY_DOMAIN; root /var/www/proxy-pool-selfsteal; index index.html; location /.well-known/acme-challenge/ { allow all; } location / { try_files \$uri \$uri/ /index.html; } }"
  [[ "$PANEL_MODE" == public ]] && NGINX_HTTP+=$'\n'"server { listen 80; listen [::]:80; server_name $PANEL_DOMAIN; root /var/www/proxy-pool-selfsteal; location /.well-known/acme-challenge/ { allow all; } location / { return 404; } }"
  write_file "$ETC/selfsteal/nginx.conf" 0644 "$NGINX_HTTP"; record_path FILE /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf; ln -sfn "$ETC/selfsteal/nginx.conf" /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf; nginx -t; systemctl reload nginx
  systemctl daemon-reload; systemctl enable --now proxy-pool-controller

  choose_cert "$PROXY_DOMAIN"; PROXY_CERT_MODE="$CERT_RESULT"
  if [[ "$PANEL_MODE" == public ]]; then choose_cert "$PANEL_DOMAIN"; PANEL_CERT_MODE="$CERT_RESULT"; else PANEL_CERT_MODE=skip; fi

  NGINX_FINAL="$NGINX_HTTP"
  if [[ "$PROXY_CERT_MODE" == existing ]] && cert_exists "$PROXY_DOMAIN"; then src=$(detect_cert_source "$PROXY_DOMAIN"); NGINX_FINAL+=$'\n'"server { listen 443 ssl; listen [::]:443 ssl; server_name $PROXY_DOMAIN; ssl_certificate $src/live/$PROXY_DOMAIN/fullchain.pem; ssl_certificate_key $src/live/$PROXY_DOMAIN/privkey.pem; ssl_protocols TLSv1.2 TLSv1.3; root /var/www/proxy-pool-selfsteal; index index.html; add_header X-Content-Type-Options nosniff always; add_header X-Frame-Options DENY always; location / { try_files \$uri \$uri/ /index.html; } }"; fi
  if [[ "$PANEL_MODE" == public && "$PANEL_CERT_MODE" == existing ]] && cert_exists "$PANEL_DOMAIN"; then
    src=$(detect_cert_source "$PANEL_DOMAIN"); write_file /etc/nginx/conf.d/tyxe-pool-limit.conf 0644 'limit_req_zone $binary_remote_addr zone=tyxe_login:10m rate=5r/m;'
    NGINX_FINAL+=$'\n'"server { listen 443 ssl; listen [::]:443 ssl; server_name $PANEL_DOMAIN; ssl_certificate $src/live/$PANEL_DOMAIN/fullchain.pem; ssl_certificate_key $src/live/$PANEL_DOMAIN/privkey.pem; ssl_protocols TLSv1.2 TLSv1.3; add_header X-Content-Type-Options nosniff always; add_header X-Frame-Options DENY always; add_header Referrer-Policy no-referrer always; location = /login { limit_req zone=tyxe_login burst=5 nodelay; proxy_pass http://127.0.0.1:$PANEL_PORT; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-Proto https; } location / { proxy_pass http://127.0.0.1:$PANEL_PORT; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-Proto https; } }"
  elif [[ "$PANEL_MODE" == public ]]; then yellow 'Panel certificate unavailable: public panel disabled, localhost remains available.'; PANEL_MODE=local; printf '\nPROXY_POOL_PANEL_MODE=local\nPROXY_POOL_COOKIE_SECURE=0\n' >> "$ETC/settings.env"; fi
  write_file "$ETC/selfsteal/nginx.conf" 0644 "$NGINX_FINAL"; nginx -t; systemctl reload nginx; systemctl restart proxy-pool-controller
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
    record_service telemt; record_entity_if_absent GROUP telemt; record_entity_if_absent USER telemt
    record_path DIR /etc/telemt; record_path DIR /opt/telemt; record_path FILE /etc/systemd/system/telemt.service; record_path FILE /lib/systemd/system/telemt.service; record_path FILE /bin/telemt; record_path FILE /usr/bin/telemt
    args=(--lang "$LANG_CODE" --domain "$TELEMT_DOMAIN" --port "$TELEMT_PORT"); [[ -n "$TELEMT_SECRET" ]] && args+=(--secret "$TELEMT_SECRET")
    curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh | bash -s -- "${args[@]}"
  fi
  systemctl daemon-reload; systemctl enable --now proxy-pool-agent
fi

section 'Final checks / Финальная проверка'
if [[ "$ROLE" == controller ]]; then
  systemctl is-active --quiet proxy-pool-controller; curl -fsS "http://127.0.0.1:$PANEL_PORT/healthz" >/dev/null; green "$(m done)"
  [[ "$PANEL_MODE" == public ]] && echo "Panel: https://$PANEL_DOMAIN/" || echo "Panel: http://127.0.0.1:$PANEL_PORT/"
  if yesno "$(m add_now)" n; then /usr/local/sbin/tyxe-pool-node add || true; fi
else
  systemctl is-active --quiet proxy-pool-agent; curl -fsS "http://127.0.0.1:$AGENT_PORT/healthz" >/dev/null; green "$(m done)"; echo "$(m token): $AGENT_TOKEN"; echo 'Telemt manager: sudo tyxe-telemt'
fi
printf 'Rollback preview: sudo /usr/local/sbin/proxy-pool-rollback --dry-run\nFull rollback: sudo /usr/local/sbin/proxy-pool-rollback --purge-state\n'
