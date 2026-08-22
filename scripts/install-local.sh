#!/usr/bin/env bash
set -Eeuo pipefail

VERSION='0.2.0'
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
CERT_SOURCE=''

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
section(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
read_tty(){ local __var="$1" __prompt="$2" __silent="${3:-0}" value=''; if [[ "$__silent" == 1 ]]; then read -r -s -p "$__prompt" value </dev/tty || true; printf '\n' >/dev/tty; else read -r -p "$__prompt" value </dev/tty || true; fi; printf -v "$__var" '%s' "$value"; }

choose_language(){
  [[ "$LANG_CODE" =~ ^(ru|en)$ ]] && return
  printf '\nTYXE Pool / Выбор языка\n1) Русский\n2) English\n'
  local v=''
  while :; do
    read_tty v '> '
    case "$v" in 1) LANG_CODE=ru; break;; 2) LANG_CODE=en; break;; *) printf '1 / 2\n';; esac
  done
}

m(){
  local k="$1"
  if [[ "$LANG_CODE" == ru ]]; then
    case "$k" in
      root) echo 'Запустите установщик от root или через sudo.';;
      title) echo "TYXE Pool Installer v$VERSION";;
      intro) cat <<'TXT'
Этот мастер настраивает компоненты TYXE Pool пошагово. Перед каждым важным действием будет пояснение.
Изменения файлов и сервисов записываются в manifest. При ошибке текущая попытка автоматически откатывается.
Уже выпущенные сертификаты Let’s Encrypt НЕ удаляются при rollback/uninstall и могут быть использованы повторно.
TXT
      ;;
      existing) echo 'Обнаружена существующая установка TYXE Pool.';;
      existing1) echo '1) Обновить / переустановить компоненты';; existing2) echo '2) Управление нодами';; existing3) echo '3) Выйти без изменений';;
      choose) echo 'Выберите пункт: ';;
      os) echo 'Поддерживаются Ubuntu и Debian. Обнаружено';;
      role_title) echo 'Роль этого VPS';;
      role_desc) cat <<'TXT'
ENTER / Controller — входная нода: центральная веб-панель, будущий балансировщик, selfsteal и управление EXIT-нодами.
EXIT / Agent — выходная нода: агент мониторинга; на следующих этапах он будет устанавливать/настраивать Telemt и синхронизировать пользователей.
TXT
      ;;
      role1) echo '1) ENTER / Controller';; role2) echo '2) EXIT / Node Agent';;
      basic) echo 'Основные параметры';;
      proxy_domain_desc) echo 'Домен прокси/selfsteal должен указывать A/AAAA-записью на этот ENTER VPS. Он будет использоваться для сайта-заглушки и сертификата.';;
      proxy_domain) echo 'Домен прокси/selfsteal';;
      panel_domain_desc) echo 'Домен панели сохраняется для будущего HTTPS reverse-proxy. В v0.2 панель по умолчанию слушает localhost для безопасного доступа через SSH-туннель.';;
      panel_domain) echo 'Домен панели (можно оставить пустым)';;
      panel_bind_desc) echo 'Адрес 127.0.0.1 не публикует панель в Интернет. 0.0.0.0 использовать только если вы понимаете риск.';;
      panel_bind) echo 'Bind-адрес панели';; panel_port) echo 'Порт панели';;
      agent_desc) echo 'Агент отдаёт controller только технический статус ноды. Для /v1/status можно использовать отдельный bearer-token.';;
      agent_port) echo 'Порт node-agent';; telemt_service) echo 'Имя systemd-сервиса Telemt';; node_name) echo 'Имя ноды';; agent_bind) echo 'Bind-адрес node-agent';;
      gen_token) echo 'Сгенерировать новый API token для node-agent?';; enter_token) echo 'Введите API token node-agent: ';;
      txn) echo 'Подготовка транзакции и rollback';;
      preflight) echo 'Проверка ОС и установка зависимостей';;
      app) echo 'Установка компонентов TYXE Pool';;
      web) echo 'Сайт-заглушка и сертификат';;
      dns_req) echo 'Перед выпуском сертификата убедитесь, что DNS домена уже указывает на этот VPS и входящий TCP/80 доступен.';;
      cert_found) echo 'Найден существующий сертификат Let’s Encrypt';;
      cert_expiry) echo 'Срок действия';;
      cert_choose) echo 'Что сделать с сертификатом?';; cert1) echo '1) Использовать существующий сертификат (рекомендуется)';; cert2) echo '2) Выпустить новый сертификат';; cert3) echo '3) Пока пропустить сертификат';;
      cert_none) echo 'Существующий сертификат для этого домена не найден.';; cert_none1) echo '1) Выпустить сертификат Let’s Encrypt';; cert_none2) echo '2) Пока пропустить';;
      email_desc) echo 'Email используется Let’s Encrypt для уведомлений об аккаунте/сертификате. Можно оставить пустым.';; acme_email) echo 'Email Let’s Encrypt';;
      issuing) echo 'Запрашиваю сертификат Let’s Encrypt...';; cert_ok) echo 'Сертификат успешно получен и сохранён в постоянном хранилище. Rollback его не удалит.';; cert_fail) echo 'Не удалось получить сертификат.';; continue_no_cert) echo 'Продолжить установку без нового сертификата?';;
      final) echo 'Финальная проверка';; done) echo 'Установка завершена.';;
      add_now) echo 'Добавить EXIT-ноду в controller сейчас?';; add_later) echo 'Ноду можно добавить позже командой tyxe-pool-node или через веб-панель.';;
      panel_access) echo 'Локальный адрес веб-панели';; ssh_hint) echo 'Для доступа с компьютера можно использовать SSH-туннель';;
      agent_token_out) echo 'API token этой EXIT-ноды (сохраните его; он потребуется при добавлении ноды в controller)';;
      rollback) echo 'Полный откат';; dryrun) echo 'Предварительный просмотр отката';;
      bad_choice) echo 'Неверный выбор.';;
    esac
  else
    case "$k" in
      root) echo 'Run the installer as root or through sudo.';;
      title) echo "TYXE Pool Installer v$VERSION";;
      intro) cat <<'TXT'
This wizard configures TYXE Pool step by step and explains each important action.
File/service changes are written to a manifest. If installation fails, only the current attempt is rolled back automatically.
Existing Let’s Encrypt certificates are NOT removed by rollback/uninstall and can be reused on the next installation.
TXT
      ;;
      existing) echo 'An existing TYXE Pool installation was detected.';;
      existing1) echo '1) Update / reinstall components';; existing2) echo '2) Manage nodes';; existing3) echo '3) Exit without changes';;
      choose) echo 'Choose an item: ';;
      os) echo 'Supported OS: Ubuntu and Debian. Detected';;
      role_title) echo 'Role of this VPS';;
      role_desc) cat <<'TXT'
ENTER / Controller — entry node: central web panel, future load balancer, selfsteal, and EXIT-node management.
EXIT / Agent — exit node: monitoring agent; later milestones will provision/configure Telemt and synchronize users.
TXT
      ;;
      role1) echo '1) ENTER / Controller';; role2) echo '2) EXIT / Node Agent';;
      basic) echo 'Basic parameters';;
      proxy_domain_desc) echo 'The proxy/selfsteal domain must resolve to this ENTER VPS. It is used for the decoy website and TLS certificate.';;
      proxy_domain) echo 'Proxy/selfsteal domain';;
      panel_domain_desc) echo 'The panel domain is stored for a future HTTPS reverse proxy. In v0.2 the panel binds to localhost by default for safe SSH-tunnel access.';;
      panel_domain) echo 'Panel domain (may be blank)';;
      panel_bind_desc) echo '127.0.0.1 keeps the panel off the public Internet. Use 0.0.0.0 only if you understand the risk.';;
      panel_bind) echo 'Panel bind address';; panel_port) echo 'Panel port';;
      agent_desc) echo 'The agent exposes technical node status to the controller. /v1/status can be protected by a dedicated bearer token.';;
      agent_port) echo 'Node-agent port';; telemt_service) echo 'Telemt systemd service name';; node_name) echo 'Node name';; agent_bind) echo 'Node-agent bind address';;
      gen_token) echo 'Generate a new node-agent API token?';; enter_token) echo 'Enter node-agent API token: ';;
      txn) echo 'Preparing transaction and rollback';;
      preflight) echo 'Checking OS and installing dependencies';;
      app) echo 'Installing TYXE Pool components';;
      web) echo 'Decoy website and certificate';;
      dns_req) echo 'Before certificate issuance, make sure the domain resolves to this VPS and inbound TCP/80 is reachable.';;
      cert_found) echo 'Existing Let’s Encrypt certificate found';; cert_expiry) echo 'Expiration';;
      cert_choose) echo 'What should be done with the certificate?';; cert1) echo '1) Reuse the existing certificate (recommended)';; cert2) echo '2) Issue a new certificate';; cert3) echo '3) Skip certificate for now';;
      cert_none) echo 'No existing certificate was found for this domain.';; cert_none1) echo '1) Issue a Let’s Encrypt certificate';; cert_none2) echo '2) Skip for now';;
      email_desc) echo 'Email is used by Let’s Encrypt for account/certificate notices. It may be left blank.';; acme_email) echo 'Let’s Encrypt email';;
      issuing) echo 'Requesting Let’s Encrypt certificate...';; cert_ok) echo 'Certificate issued and stored in persistent storage. Rollback will preserve it.';; cert_fail) echo 'Certificate issuance failed.';; continue_no_cert) echo 'Continue installation without a new certificate?';;
      final) echo 'Final checks';; done) echo 'Installation completed.';;
      add_now) echo 'Add an EXIT node to the controller now?';; add_later) echo 'You can add a node later with tyxe-pool-node or from the web panel.';;
      panel_access) echo 'Local web-panel address';; ssh_hint) echo 'To access it from your computer, you can use an SSH tunnel';;
      agent_token_out) echo 'API token for this EXIT node (save it; you will need it when adding the node to the controller)';;
      rollback) echo 'Full rollback';; dryrun) echo 'Rollback preview';;
      bad_choice) echo 'Invalid choice.';;
    esac
  fi
}

ask(){ local prompt="$1" def="${2:-}" v=''; read_tty v "$prompt${def:+ [$def]}: "; printf '%s' "${v:-$def}"; }
yesno(){ local prompt="$1" def="${2:-y}" v=''; while :; do read_tty v "$prompt [y/n] (${def}): "; v="${v:-$def}"; case "$v" in y|Y|yes|YES|Yes) return 0;; n|N|no|NO|No) return 1;; *) echo 'y/n';; esac; done; }
choice(){ local prompt="$1" min="$2" max="$3" v=''; while :; do read_tty v "$prompt"; if [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )); then printf '%s' "$v"; return; fi; echo "$(m bad_choice)"; done; }
root_check(){ [[ $EUID -eq 0 ]] || { red "$(m root)"; exit 1; }; }

backup_path(){
  local p="$1"
  mkdir -p "$BACKUP"
  if [[ -e "$p" || -L "$p" ]]; then
    local id b
    id=$(printf '%s' "$p" | sed 's#^/##; s#[^A-Za-z0-9._-]#_#g')
    b="$BACKUP/$id.$(date +%s%N)"
    cp -a "$p" "$b"
    printf '%s' "$b"
  fi
}
record_path(){ local typ="$1" path="$2" b=''; b=$(backup_path "$path"); printf 'PATH %s|%s|%s\n' "$typ" "$path" "$b" >> "$MANIFEST"; }
ensure_dir(){ local d="$1"; if [[ ! -d "$d" ]]; then record_path DIR "$d"; mkdir -p "$d"; fi; }
record_pkg(){ printf 'PACKAGE %s\n' "$1" >> "$MANIFEST"; }
record_service(){ local s="$1" en='disabled' ac='inactive'; en=$(systemctl is-enabled "$s" 2>/dev/null || true); ac=$(systemctl is-active "$s" 2>/dev/null || true); printf 'SERVICE %s|%s|%s\n' "$s" "$en" "$ac" >> "$MANIFEST"; }
install_file(){ local src="$1" dst="$2" mode="${3:-0644}"; record_path FILE "$dst"; install -Dm "$mode" "$src" "$dst"; }
write_file(){ local dst="$1" mode="$2" content="$3"; record_path FILE "$dst"; install -d "$(dirname "$dst")"; printf '%s\n' "$content" > "$dst"; chmod "$mode" "$dst"; }

init_txn(){
  mkdir -p "$STATE" "$BACKUP"
  touch "$MANIFEST"
  TX_START_LINE=$(wc -l < "$MANIFEST")
  printf 'BEGIN %s|%s|%s\n' "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LANG_CODE" >> "$MANIFEST"
}

on_error(){
  local rc=$?
  trap - ERR
  red "Installer failed / Ошибка установщика (exit $rc)."
  if [[ -x /usr/local/sbin/proxy-pool-rollback && -f "$MANIFEST" ]]; then
    yellow 'Rolling back only the current attempt / Откатываю только текущую попытку...'
    TYXE_POOL_LANG="$LANG_CODE" /usr/local/sbin/proxy-pool-rollback --since-line "$TX_START_LINE" --lang "$LANG_CODE" || true
  fi
  exit "$rc"
}
trap on_error ERR

detect_cert_source(){ local domain="$1"; if [[ -s "$CERT_STORE/live/$domain/fullchain.pem" ]]; then printf '%s' "$CERT_STORE"; elif [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then printf '/etc/letsencrypt'; fi; }
cert_path(){ local domain="$1" source; source="$(detect_cert_source "$domain")"; [[ -n "$source" ]] || source="$CERT_STORE"; printf '%s/live/%s/fullchain.pem' "$source" "$domain"; }
cert_key_path(){ local domain="$1" source; source="$(detect_cert_source "$domain")"; [[ -n "$source" ]] || source="$CERT_STORE"; printf '%s/live/%s/privkey.pem' "$source" "$domain"; }
cert_exists(){ local p k; p="$(cert_path "$1")"; k="$(cert_key_path "$1")"; [[ -s "$p" && -s "$k" ]]; }
cert_expiry(){ openssl x509 -in "$(cert_path "$1")" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true; }
migrate_legacy_cert_store(){
  local domain="$1"
  if [[ -s "$ETC/acme/live/$domain/fullchain.pem" && ! -s "$CERT_STORE/live/$domain/fullchain.pem" ]]; then
    mkdir -p "$CERT_STORE" "$CERT_WORK" "$CERT_LOGS"
    cp -a "$ETC/acme/." "$CERT_STORE/"
    # Rewrite renewal paths created by the v0.1 custom Certbot config directory.
    if [[ -d "$CERT_STORE/renewal" ]]; then
      grep -rlF "$ETC/acme" "$CERT_STORE/renewal" 2>/dev/null | while IFS= read -r f; do sed -i "s#${ETC}/acme#${CERT_STORE}#g" "$f"; done
    fi
  fi
}
issue_cert(){
  local domain="$1" email="$2"
  mkdir -p "$CERT_STORE" "$CERT_WORK" "$CERT_LOGS"
  yellow "$(m dns_req)"
  if [[ -n "$email" ]]; then
    certbot certonly --webroot -w /var/www/proxy-pool-selfsteal -d "$domain" --cert-name "$domain" --email "$email" --agree-tos --non-interactive --no-eff-email --force-renewal --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS"
  else
    certbot certonly --webroot -w /var/www/proxy-pool-selfsteal -d "$domain" --cert-name "$domain" --register-unsafely-without-email --agree-tos --non-interactive --force-renewal --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS"
  fi
}

choose_language
export TYXE_POOL_LANG="$LANG_CODE"
root_check
section "$(m title)"
m intro

# Existing installation gets a lightweight management menu before modifying anything.
if [[ -f "$ETC/settings.env" ]]; then
  yellow "$(m existing)"
  printf '%s\n%s\n%s\n' "$(m existing1)" "$(m existing2)" "$(m existing3)"
  existing_choice=$(choice "$(m choose)" 1 3)
  case "$existing_choice" in
    2)
      if [[ -x /usr/local/sbin/tyxe-pool-node ]]; then exec /usr/local/sbin/tyxe-pool-node menu; else red 'Node manager is not installed yet. Choose update first.'; exit 1; fi
      ;;
    3) exit 0;;
  esac
fi

. /etc/os-release || true
case "${ID:-}" in ubuntu|debian) ;; *) red "$(m os): ${ID:-unknown}"; exit 1;; esac

section "$(m role_title)"
m role_desc
printf '%s\n%s\n' "$(m role1)" "$(m role2)"
ROLE_CHOICE=$(choice "$(m choose)" 1 2)
[[ "$ROLE_CHOICE" == 1 ]] && ROLE='controller' || ROLE='agent'

PROXY_DOMAIN=''
PANEL_DOMAIN=''
ACME_EMAIL=''
PANEL_BIND='127.0.0.1'
PANEL_PORT='9101'
AGENT_BIND='0.0.0.0'
AGENT_PORT='9100'
TELEMT_SERVICE='telemt'
NODE_NAME="$(hostname -s)"
AGENT_TOKEN=''
CERT_MODE='skip'

section "$(m basic)"
if [[ "$ROLE" == controller ]]; then
  echo "$(m proxy_domain_desc)"
  PROXY_DOMAIN=$(ask "$(m proxy_domain)" 'proxy.example.com')
  echo
  echo "$(m panel_domain_desc)"
  PANEL_DOMAIN=$(ask "$(m panel_domain)" '')
  echo
  echo "$(m panel_bind_desc)"
  PANEL_BIND=$(ask "$(m panel_bind)" '127.0.0.1')
  PANEL_PORT=$(ask "$(m panel_port)" '9101')
else
  echo "$(m agent_desc)"
  NODE_NAME=$(ask "$(m node_name)" "$(hostname -s)")
  AGENT_BIND=$(ask "$(m agent_bind)" '0.0.0.0')
  AGENT_PORT=$(ask "$(m agent_port)" '9100')
  TELEMT_SERVICE=$(ask "$(m telemt_service)" 'telemt')
  if yesno "$(m gen_token)" y; then
    AGENT_TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  else
    read_tty AGENT_TOKEN "$(m enter_token)" 1
  fi
fi

section "$(m txn)"
init_txn
# Install/update rollback engine first so every later failure can be undone.
record_path FILE /usr/local/sbin/proxy-pool-rollback
install -m 0755 "$SCRIPT_DIR/../rollback.sh" /usr/local/sbin/proxy-pool-rollback

section "$(m preflight)"
apt-get update -y
for pkg in ca-certificates curl nginx python3 openssl; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then apt-get install -y "$pkg"; record_pkg "$pkg"; fi
done
if [[ "$ROLE" == controller ]]; then
  for pkg in haproxy certbot; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then apt-get install -y "$pkg"; record_pkg "$pkg"; fi
  done
fi

ensure_dir "$ETC"
ensure_dir "$ROOT"

section "$(m app)"
if [[ "$ROLE" == controller ]]; then
  ensure_dir "$ROOT/controller"
  install_file "$SCRIPT_DIR/../controller/controller.py" "$ROOT/controller/controller.py" 0755
  install_file "$SCRIPT_DIR/node-manager.sh" /usr/local/sbin/tyxe-pool-node 0755
  ensure_dir "$ETC/selfsteal"
  ensure_dir /var/www/proxy-pool-selfsteal
  if [[ "$LANG_CODE" == ru ]]; then
    SITE_HTML='<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Добро пожаловать</title><style>body{font-family:system-ui,-apple-system,sans-serif;max-width:760px;margin:12vh auto;padding:24px;color:#222;background:#fafafa}main{background:#fff;padding:32px;border-radius:16px;border:1px solid #e5e7eb}h1{font-size:32px}p{color:#555}</style></head><body><main><h1>Добро пожаловать</h1><p>Сайт находится в разработке.</p></main></body></html>'
  else
    SITE_HTML='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title><style>body{font-family:system-ui,-apple-system,sans-serif;max-width:760px;margin:12vh auto;padding:24px;color:#222;background:#fafafa}main{background:#fff;padding:32px;border-radius:16px;border:1px solid #e5e7eb}h1{font-size:32px}p{color:#555}</style></head><body><main><h1>Welcome</h1><p>This website is currently under construction.</p></main></body></html>'
  fi
  write_file /var/www/proxy-pool-selfsteal/index.html 0644 "$SITE_HTML"

  SETTINGS_CONTENT="TYXE_POOL_LANG=$LANG_CODE
PROXY_POOL_LANG=$LANG_CODE
PROXY_POOL_ROLE=controller
PROXY_POOL_HOME=$ETC
PROXY_POOL_BIND=$PANEL_BIND
PROXY_POOL_PORT=$PANEL_PORT
PROXY_POOL_PROXY_DOMAIN=$PROXY_DOMAIN
PROXY_POOL_PANEL_DOMAIN=$PANEL_DOMAIN
PROXY_POOL_POLL_INTERVAL=5"
  write_file "$ETC/settings.env" 0600 "$SETTINGS_CONTENT"
  install_file "$SCRIPT_DIR/../systemd/proxy-pool-controller.service" /etc/systemd/system/proxy-pool-controller.service 0644
  record_service proxy-pool-controller
  install_file "$SCRIPT_DIR/../templates/haproxy.cfg.tmpl" "$ETC/haproxy.cfg.tmpl" 0644

  NGINX_CONF="server {
    listen 80;
    listen [::]:80;
    server_name $PROXY_DOMAIN;
    root /var/www/proxy-pool-selfsteal;
    index index.html;
    location /.well-known/acme-challenge/ { allow all; }
    location / { try_files \$uri \$uri/ /index.html; }
}"
  write_file "$ETC/selfsteal/nginx.conf" 0644 "$NGINX_CONF"
  record_path FILE /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf
  ln -sfn "$ETC/selfsteal/nginx.conf" /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf
  nginx -t
  systemctl reload nginx

  systemctl daemon-reload
  systemctl enable --now proxy-pool-controller
else
  ensure_dir "$ROOT/agent"
  install_file "$SCRIPT_DIR/../agent/agent.py" "$ROOT/agent/agent.py" 0755
  SETTINGS_CONTENT="TYXE_POOL_LANG=$LANG_CODE
PROXY_POOL_LANG=$LANG_CODE
PROXY_POOL_ROLE=agent
PROXY_POOL_AGENT_BIND=$AGENT_BIND
PROXY_POOL_AGENT_PORT=$AGENT_PORT
PROXY_POOL_TELEMT_SERVICE=$TELEMT_SERVICE
PROXY_POOL_NODE_NAME=$NODE_NAME
PROXY_POOL_AGENT_TOKEN=$AGENT_TOKEN"
  write_file "$ETC/settings.env" 0600 "$SETTINGS_CONTENT"
  install_file "$SCRIPT_DIR/../systemd/proxy-pool-agent.service" /etc/systemd/system/proxy-pool-agent.service 0644
  record_service proxy-pool-agent
  systemctl daemon-reload
  systemctl enable --now proxy-pool-agent
fi

if [[ "$ROLE" == controller ]]; then
  section "$(m web)"
  migrate_legacy_cert_store "$PROXY_DOMAIN"
  echo "$(m dns_req)"
  if cert_exists "$PROXY_DOMAIN"; then
    green "$(m cert_found): $PROXY_DOMAIN"
    echo "$(m cert_expiry): $(cert_expiry "$PROXY_DOMAIN")"
    echo "$(m cert_choose)"
    printf '%s\n%s\n%s\n' "$(m cert1)" "$(m cert2)" "$(m cert3)"
    cc=$(choice "$(m choose)" 1 3)
    case "$cc" in 1) CERT_MODE='existing';; 2) CERT_MODE='new';; 3) CERT_MODE='skip';; esac
  else
    yellow "$(m cert_none)"
    printf '%s\n%s\n' "$(m cert_none1)" "$(m cert_none2)"
    cc=$(choice "$(m choose)" 1 2)
    [[ "$cc" == 1 ]] && CERT_MODE='new' || CERT_MODE='skip'
  fi

  if [[ "$CERT_MODE" == new ]]; then
    echo "$(m email_desc)"
    ACME_EMAIL=$(ask "$(m acme_email)" '')
    yellow "$(m issuing)"
    if issue_cert "$PROXY_DOMAIN" "$ACME_EMAIL"; then
      green "$(m cert_ok)"
    else
      red "$(m cert_fail)"
      if ! yesno "$(m continue_no_cert)" y; then false; fi
      CERT_MODE='skip'
    fi
  fi
  # Persist choice in settings (certificate files themselves remain outside the rollback manifest).
  CERT_SOURCE="$(detect_cert_source "$PROXY_DOMAIN")"
  printf 'PROXY_POOL_CERT_MODE=%s\nPROXY_POOL_CERT_STORE=%s\n' "$CERT_MODE" "$CERT_SOURCE" >> "$ETC/settings.env"
fi

section "$(m final)"
if [[ "$ROLE" == controller ]]; then
  systemctl is-active --quiet proxy-pool-controller
  curl -fsS "http://127.0.0.1:$PANEL_PORT/healthz" >/dev/null
  green "$(m done)"
  echo "$(m panel_access): http://127.0.0.1:$PANEL_PORT/"
  echo "$(m ssh_hint): ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@YOUR_VPS_IP"
  echo
  if yesno "$(m add_now)" n; then
    /usr/local/sbin/tyxe-pool-node add || yellow "$(m add_later)"
  else
    yellow "$(m add_later)"
  fi
else
  systemctl is-active --quiet proxy-pool-agent
  curl -fsS "http://127.0.0.1:$AGENT_PORT/healthz" >/dev/null
  green "$(m done)"
  printf '\n%s:\n%s\n\n' "$(m agent_token_out)" "$AGENT_TOKEN"
fi

printf '%s: sudo /usr/local/sbin/proxy-pool-rollback --dry-run\n' "$(m dryrun)"
printf '%s: sudo /usr/local/sbin/proxy-pool-rollback --purge-state\n' "$(m rollback)"
