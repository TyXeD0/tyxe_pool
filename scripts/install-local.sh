#!/usr/bin/env bash
set -Eeuo pipefail

VERSION='0.1.1'
ROOT='/opt/proxy-pool'
ETC='/etc/proxy-pool'
STATE='/var/lib/proxy-pool'
MANIFEST="$STATE/install-manifest"
BACKUP="$STATE/backups"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
section(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ask(){ local p="$1" d="${2:-}" v; read -r -p "$p${d:+ [$d]}: " v || true; printf '%s' "${v:-$d}"; }
yesno(){ local p="$1" d="${2:-y}" v; read -r -p "$p [y/n] (default $d): " v || true; v="${v:-$d}"; [[ "$v" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; }
root_check(){ [[ $EUID -eq 0 ]] || { red 'Run as root.'; exit 1; }; }

init_txn(){
  mkdir -p "$STATE" "$BACKUP"
  if [[ ! -f "$MANIFEST" ]]; then
    : > "$MANIFEST"
  else
    cp -a "$MANIFEST" "$BACKUP/manifest.$(date +%Y%m%d-%H%M%S)"
    : > "$MANIFEST"
  fi
}

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
record_path(){
  local typ="$1" path="$2" b
  b=$(backup_path "$path")
  printf 'PATH %s|%s|%s\n' "$typ" "$path" "$b" >> "$MANIFEST"
}
ensure_dir(){
  local d="$1"
  if [[ ! -d "$d" ]]; then
    record_path DIR "$d"
    mkdir -p "$d"
  fi
}
record_service(){ printf 'SERVICE %s\n' "$1" >> "$MANIFEST"; }
record_pkg(){ printf 'PACKAGE %s\n' "$1" >> "$MANIFEST"; }
install_file(){ local src="$1" dst="$2" mode="${3:-0644}"; record_path FILE "$dst"; install -Dm "$mode" "$src" "$dst"; }
write_file(){ local dst="$1" mode="$2"; shift 2; record_path FILE "$dst"; install -d "$(dirname "$dst")"; printf '%s\n' "$*" > "$dst"; chmod "$mode" "$dst"; }
on_error(){ rc=$?; trap - ERR; red "Installer failed (exit $rc)."; if [[ -x /usr/local/sbin/proxy-pool-rollback && -f "$MANIFEST" ]]; then yellow 'Attempting automatic rollback...'; /usr/local/sbin/proxy-pool-rollback || true; fi; exit $rc; }; trap on_error ERR

root_check
section "Proxy Pool Installer v$VERSION"
cat <<'MSG'
This installer is transactional.
Existing files are backed up before replacement, services are recorded,
and the rollback command is installed before application changes begin.

First milestone:
  - controller/agent bootstrap
  - minimal dashboard/API
  - HAProxy template
  - selfsteal HTTP website + Let's Encrypt certificate issuance
  - rollback

Existing Telemt/HAProxy configurations are NOT overwritten automatically.
MSG

. /etc/os-release || true
case "${ID:-}" in
  ubuntu|debian) ;;
  *) red "Supported OS: Ubuntu/Debian. Detected: ${ID:-unknown}"; exit 1;;
esac

ROLE=$(ask 'Install role (controller/agent)' 'controller')
[[ "$ROLE" == controller || "$ROLE" == agent ]] || { red 'Invalid role'; exit 1; }

section 'Basic parameters'
PROXY_DOMAIN=''; PANEL_DOMAIN=''; ACME_EMAIL=''; PANEL_BIND='127.0.0.1'; PANEL_PORT='9101'; AGENT_PORT='9100'; TELEMT_SERVICE='telemt'; CONTROLLER_URL=''
if [[ "$ROLE" == controller ]]; then
  PROXY_DOMAIN=$(ask 'Public proxy/selfsteal domain' 'proxy.example.com')
  PANEL_DOMAIN=$(ask 'Management panel domain (blank = localhost-only)' '')
  ACME_EMAIL=$(ask "Let's Encrypt email (optional)" '')
  PANEL_BIND=$(ask 'Controller/dashboard bind address' '127.0.0.1')
  PANEL_PORT=$(ask 'Controller/dashboard port' '9101')
else
  AGENT_PORT=$(ask 'Agent listen port' '9100')
  TELEMT_SERVICE=$(ask 'Telemt systemd service name' 'telemt')
  CONTROLLER_URL=$(ask 'Controller URL' 'https://panel.example.com')
  NODE_NAME=$(ask 'Node name' "$(hostname -s)")
fi

section 'Initialize transaction'
init_txn
# Install rollback before package/config changes.
record_path FILE /usr/local/sbin/proxy-pool-rollback
install -m 0755 "$SCRIPT_DIR/../rollback.sh" /usr/local/sbin/proxy-pool-rollback

section 'Preflight'
apt-get update -y
for pkg in ca-certificates curl nginx; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-get install -y "$pkg"; record_pkg "$pkg"
  fi
done
if [[ "$ROLE" == controller ]]; then
  for pkg in haproxy certbot; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      apt-get install -y "$pkg"; record_pkg "$pkg"
    fi
  done
fi

ensure_dir "$ETC"
ensure_dir "$ROOT"

section 'Install application'
if [[ "$ROLE" == controller ]]; then
  ensure_dir "$ROOT/controller"
  record_path FILE "$ROOT/controller/controller.py"
  install -Dm0755 "$SCRIPT_DIR/../controller/controller.py" "$ROOT/controller/controller.py"
  ensure_dir "$ETC/selfsteal"
  ensure_dir /var/www/proxy-pool-selfsteal
  write_file /var/www/proxy-pool-selfsteal/index.html 0644 '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title><style>body{font-family:system-ui,-apple-system,sans-serif;max-width:760px;margin:12vh auto;padding:24px;color:#222;background:#fafafa}main{background:#fff;padding:32px;border-radius:16px;border:1px solid #e5e7eb}h1{font-size:32px}p{color:#555}</style></head><body><main><h1>Welcome</h1><p>This website is currently under construction.</p></main></body></html>'
  write_file "$ETC/controller.env" 0600 "PROXY_POOL_HOME=$ETC
PROXY_POOL_BIND=$PANEL_BIND
PROXY_POOL_PORT=$PANEL_PORT"
  install_file "$SCRIPT_DIR/../systemd/proxy-pool-controller.service" /etc/systemd/system/proxy-pool-controller.service
  record_service proxy-pool-controller
  record_path FILE "$ETC/haproxy.cfg.tmpl"
  install -Dm0644 "$SCRIPT_DIR/../templates/haproxy.cfg.tmpl" "$ETC/haproxy.cfg.tmpl"
  systemctl daemon-reload
  systemctl enable --now proxy-pool-controller
else
  ensure_dir "$ROOT/agent"
  record_path FILE "$ROOT/agent/agent.py"
  install -Dm0755 "$SCRIPT_DIR/../agent/agent.py" "$ROOT/agent/agent.py"
  write_file "$ETC/agent.env" 0600 "PROXY_POOL_AGENT_BIND=0.0.0.0
PROXY_POOL_AGENT_PORT=$AGENT_PORT
PROXY_POOL_TELEMT_SERVICE=$TELEMT_SERVICE
PROXY_POOL_CONTROLLER_URL=$CONTROLLER_URL
PROXY_POOL_NODE_NAME=$NODE_NAME"
  install_file "$SCRIPT_DIR/../systemd/proxy-pool-agent.service" /etc/systemd/system/proxy-pool-agent.service
  record_service proxy-pool-agent
  systemctl daemon-reload
  systemctl enable --now proxy-pool-agent
fi

section 'Selfsteal / web validation'
if [[ "$ROLE" == controller ]]; then
  record_path FILE "$ETC/selfsteal/nginx.conf"
  write_file "$ETC/selfsteal/nginx.conf" 0644 "server {
    listen 80;
    listen [::]:80;
    server_name $PROXY_DOMAIN;
    root /var/www/proxy-pool-selfsteal;
    index index.html;
    location /.well-known/acme-challenge/ { allow all; }
    location / { try_files \$uri \$uri/ /index.html; }
}"
  record_path FILE /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf
  ln -sf "$ETC/selfsteal/nginx.conf" /etc/nginx/sites-enabled/proxy-pool-selfsteal.conf
  nginx -t
  systemctl reload nginx

  yellow "DNS requirement: $PROXY_DOMAIN must resolve to this VPS before ACME HTTP-01 can succeed."
  if yesno "Request Let's Encrypt certificate for $PROXY_DOMAIN now?"; then
    ensure_dir "$ETC/acme"
    ensure_dir "$STATE/acme-work"
    ensure_dir "$STATE/acme-logs"
    if [[ -n "$ACME_EMAIL" ]]; then
      certbot certonly --webroot -w /var/www/proxy-pool-selfsteal -d "$PROXY_DOMAIN" --email "$ACME_EMAIL" --agree-tos --non-interactive --no-eff-email --config-dir "$ETC/acme" --work-dir "$STATE/acme-work" --logs-dir "$STATE/acme-logs"
    else
      certbot certonly --webroot -w /var/www/proxy-pool-selfsteal -d "$PROXY_DOMAIN" --register-unsafely-without-email --agree-tos --non-interactive --config-dir "$ETC/acme" --work-dir "$STATE/acme-work" --logs-dir "$STATE/acme-logs"
    fi
    green "Certificate issued. HTTPS selfsteal integration will be activated in a later milestone so it cannot steal 443 from HAProxy prematurely."
  else
    yellow 'Certificate issuance skipped.'
  fi
fi

section 'Final checks'
if [[ "$ROLE" == controller ]]; then
  systemctl is-active --quiet proxy-pool-controller
  curl -fsS "http://127.0.0.1:$PANEL_PORT/healthz" >/dev/null
  green "Controller is running on $PANEL_BIND:$PANEL_PORT"
else
  systemctl is-active --quiet proxy-pool-agent
  curl -fsS "http://127.0.0.1:$AGENT_PORT/healthz" >/dev/null
  green "Agent is running on 127.0.0.1:$AGENT_PORT"
fi

green "Installation completed."
green "Rollback dry-run: sudo /usr/local/sbin/proxy-pool-rollback --dry-run"
green "Rollback:          sudo /usr/local/sbin/proxy-pool-rollback"
