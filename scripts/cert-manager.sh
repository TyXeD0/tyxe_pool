#!/usr/bin/env bash
set -Eeuo pipefail

ETC=/etc/proxy-pool
SETTINGS=$ETC/settings.env
SITE_ROOT=/var/www/proxy-pool-selfsteal
CERT_STORE=/var/lib/tyxe-pool-persistent/letsencrypt
CERT_WORK=/var/lib/tyxe-pool-persistent/acme-work
CERT_LOGS=/var/lib/tyxe-pool-persistent/acme-logs
RENEW_SERVICE=/etc/systemd/system/tyxe-cert-renew.service
RENEW_TIMER=/etc/systemd/system/tyxe-cert-renew.timer

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
cyan(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
getenv_file(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
yesno(){ local p="$1" v=''; read -r -p "$p [y/N]: " v </dev/tty || true; [[ "$v" =~ ^[yY]$ ]]; }

[[ $EUID -eq 0 ]] || { red 'Запустите через sudo/root.'; exit 1; }
[[ -r $SETTINGS ]] || { red 'TYXE settings не найдены.'; exit 1; }
[[ "$(getenv_file "$SETTINGS" PROXY_POOL_ROLE)" == controller ]] || { red 'Сертификаты shared-443 управляются на ENTER/controller.'; exit 1; }

PROXY_DOMAIN=$(getenv_file "$SETTINGS" PROXY_POOL_PROXY_DOMAIN)
PANEL_DOMAIN=$(getenv_file "$SETTINGS" PROXY_POOL_PANEL_DOMAIN)

valid_domain(){ [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" == *.* && "$1" != .* && "$1" != *. ]]; }
resolve_target(){
  case "${1:-proxy}" in
    proxy) DOMAIN=$PROXY_DOMAIN ;;
    panel) DOMAIN=$PANEL_DOMAIN ;;
    *) DOMAIN="$1" ;;
  esac
  [[ -n ${DOMAIN:-} ]] || { red 'Домен не настроен.'; return 1; }
  valid_domain "$DOMAIN" || { red "Некорректный домен: $DOMAIN"; return 1; }
  if [[ "$DOMAIN" != "$PROXY_DOMAIN" && "$DOMAIN" != "$PANEL_DOMAIN" ]]; then
    red 'Разрешены только proxy/panel домены текущей установки TYXE.'; return 1
  fi
}

cert_dir(){
  local d="$1"
  if [[ -s "$CERT_STORE/live/$d/fullchain.pem" && -s "$CERT_STORE/live/$d/privkey.pem" ]]; then
    printf '%s/live/%s' "$CERT_STORE" "$d"; return 0
  fi
  if [[ -s "/etc/letsencrypt/live/$d/fullchain.pem" && -s "/etc/letsencrypt/live/$d/privkey.pem" ]]; then
    printf '/etc/letsencrypt/live/%s' "$d"; return 0
  fi
  return 1
}

public_ipv4(){ ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -n1; }

preflight_http(){
  local d="$1" resolved pub token path got
  command -v certbot >/dev/null 2>&1 || { red 'certbot не установлен.'; return 1; }
  command -v nginx >/dev/null 2>&1 || { red 'nginx не установлен.'; return 1; }
  systemctl is-active --quiet nginx || { red 'nginx не active.'; return 1; }
  ss -ltnH 'sport = :80' 2>/dev/null | grep -q . || { red 'На ENTER никто не слушает TCP/80.'; return 1; }

  resolved=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
  pub=$(public_ipv4)
  [[ -n $resolved ]] || { red "DNS A для $d не резолвится."; return 1; }
  if [[ -n $pub && $resolved != "$pub" ]]; then
    yellow "DNS $d -> $resolved, публичный IPv4 ENTER -> $pub"
    yesno 'Продолжить выпуск сертификата несмотря на несовпадение?' || return 1
  fi

  install -d -m 755 "$SITE_ROOT/.well-known/acme-challenge"
  token="tyxe-preflight-$$-$(date +%s)"
  path="$SITE_ROOT/.well-known/acme-challenge/$token"
  printf '%s' "$token" > "$path"
  trap 'rm -f "${path:-}"' RETURN
  got=$(curl -fsS --max-time 5 -H "Host: $d" "http://127.0.0.1/.well-known/acme-challenge/$token" 2>/dev/null || true)
  [[ "$got" == "$token" ]] || {
    red "nginx не отдаёт ACME webroot для $d через TCP/80."
    red "Проверьте server_name и location /.well-known/acme-challenge/."
    return 1
  }
  green "DNS/HTTP-01 preflight: $d -> $resolved, webroot OK"
}

install_renew_timer(){
  cat > "$RENEW_SERVICE" <<EOF
[Unit]
Description=TYXE Let's Encrypt renewal
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --config-dir $CERT_STORE --work-dir $CERT_WORK --logs-dir $CERT_LOGS --quiet
ExecStartPost=/bin/systemctl reload nginx
EOF
  cat > "$RENEW_TIMER" <<'EOF'
[Unit]
Description=Daily TYXE Let's Encrypt renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now tyxe-cert-renew.timer >/dev/null
}

ensure_cert(){
  resolve_target "${1:-proxy}" || return 1
  cyan "Certificate: $DOMAIN"
  local existing email=''
  if existing=$(cert_dir "$DOMAIN"); then
    green "Сертификат уже существует: $existing"
    openssl x509 -in "$existing/fullchain.pem" -noout -subject -issuer -enddate 2>/dev/null || true
    install_renew_timer
    return 0
  fi

  preflight_http "$DOMAIN" || return 1
  yellow "Будет выпущен Let's Encrypt сертификат для $DOMAIN и сохранён вне rollback TYXE."
  yesno 'Выпустить сертификат?' || return 0
  read -r -p "Email Let's Encrypt (пусто = без email): " email </dev/tty || true

  install -d -m 700 "$CERT_STORE" "$CERT_WORK" "$CERT_LOGS"
  args=(certonly --webroot -w "$SITE_ROOT" -d "$DOMAIN" --cert-name "$DOMAIN" --agree-tos --non-interactive --no-eff-email --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS")
  [[ -n $email ]] && args+=(--email "$email") || args+=(--register-unsafely-without-email)
  certbot "${args[@]}"

  existing=$(cert_dir "$DOMAIN") || { red 'Certbot завершился, но сертификат не найден в ожидаемом хранилище.'; return 1; }
  install_renew_timer
  green "Готово: $existing"
  openssl x509 -in "$existing/fullchain.pem" -noout -subject -issuer -enddate 2>/dev/null || true
}

status(){
  cyan 'TYXE certificates'
  local d p
  for d in "$PROXY_DOMAIN" "$PANEL_DOMAIN"; do
    [[ -n $d ]] || continue
    printf '%s: ' "$d"
    if p=$(cert_dir "$d"); then
      printf '%s\n' "$p"
      openssl x509 -in "$p/fullchain.pem" -noout -enddate 2>/dev/null || true
    else
      echo 'missing'
    fi
  done
  printf '\nRenew timer: '
  systemctl is-enabled tyxe-cert-renew.timer 2>/dev/null || true
  systemctl list-timers tyxe-cert-renew.timer --no-pager 2>/dev/null || true
}

case "${1:-status}" in
  ensure|issue) shift; ensure_cert "${1:-proxy}" ;;
  status) status ;;
  *) echo 'Usage: tyxe-cert [status|ensure proxy|ensure panel]' >&2; exit 2 ;;
esac
