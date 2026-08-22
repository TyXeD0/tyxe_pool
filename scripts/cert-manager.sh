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
ACME_HELPER=/etc/nginx/conf.d/tyxe-acme-http.conf
TYXE_NGINX=$ETC/selfsteal/nginx.conf

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

parse_dns_json_ipv4(){
  python3 -c 'import ipaddress,json,sys
try:
    doc=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for item in doc.get("Answer", []):
    if item.get("type") != 1:
        continue
    value=str(item.get("data", "")).strip()
    try:
        ipaddress.IPv4Address(value)
    except Exception:
        continue
    print(value)
    break' 2>/dev/null | head -n1
}

public_dns_ipv4(){
  local d="$1" r ans endpoint host ip
  if command -v dig >/dev/null 2>&1; then
    for r in 1.1.1.1 8.8.8.8 9.9.9.9; do
      ans=$(dig +time=2 +tries=1 +short A "$d" "@$r" 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/{print; exit}' || true)
      [[ -n $ans ]] && { printf '%s' "$ans"; return 0; }
      ans=$(dig +tcp +time=2 +tries=1 +short A "$d" "@$r" 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/{print; exit}' || true)
      [[ -n $ans ]] && { printf '%s' "$ans"; return 0; }
    done
  fi
  if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    while IFS='|' read -r host ip endpoint; do
      [[ -n $host && -n $ip && -n $endpoint ]] || continue
      ans=$(
        curl -q --noproxy '*' -fsS --connect-timeout 3 --max-time 7 \
          --resolve "$host:443:$ip" \
          -H 'accept: application/dns-json' \
          "https://$host$endpoint?name=$d&type=A" 2>/dev/null |
        parse_dns_json_ipv4 || true
      )
      [[ -n $ans ]] && { printf '%s' "$ans"; return 0; }
    done <<'EOF_DOH'
cloudflare-dns.com|1.1.1.1|/dns-query
cloudflare-dns.com|1.0.0.1|/dns-query
dns.google|8.8.8.8|/resolve
dns.google|8.8.4.4|/resolve
EOF_DOH
  fi
  return 1
}

challenge_ok(){
  local d="$1" token path got
  install -d -m 755 "$SITE_ROOT" "$SITE_ROOT/.well-known" "$SITE_ROOT/.well-known/acme-challenge"
  chmod 755 "$SITE_ROOT" "$SITE_ROOT/.well-known" "$SITE_ROOT/.well-known/acme-challenge" 2>/dev/null || true
  token="tyxe-preflight-$$-$(date +%s%N)"
  path="$SITE_ROOT/.well-known/acme-challenge/$token"
  printf '%s' "$token" > "$path"
  chmod 644 "$path"
  got=$(curl -q --noproxy '*' -fsS --max-time 5 \
    --resolve "$d:80:127.0.0.1" \
    "http://$d/.well-known/acme-challenge/$token" 2>/dev/null || true)
  rm -f "$path"
  [[ "$got" == "$token" ]]
}

challenge_debug(){
  local d="$1" token path code body
  install -d -m 755 "$SITE_ROOT/.well-known/acme-challenge"
  token="tyxe-debug-$$-$(date +%s%N)"
  path="$SITE_ROOT/.well-known/acme-challenge/$token"
  body="/tmp/tyxe-acme-body.$$"
  printf '%s' "$token" > "$path"; chmod 644 "$path"
  code=$(curl -q --noproxy '*' -sS --max-time 5 \
    --resolve "$d:80:127.0.0.1" \
    -o "$body" -w '%{http_code}' \
    "http://$d/.well-known/acme-challenge/$token" 2>/dev/null || true)
  yellow "Локальный nginx probe: http://$d/.well-known/acme-challenge/<token> -> HTTP ${code:-000}"
  if [[ -s $body ]]; then
    yellow "Первые 160 байт ответа: $(head -c 160 "$body" | tr '\n\r' '  ')"
  fi
  rm -f "$path" "$body"
  yellow "Активные nginx server-блоки для $d:"
  nginx -T 2>/dev/null | grep -n -F -B2 -A10 "server_name $d" >&2 || true
}

tyxe_managed_has_acme(){
  local d="$1"
  [[ -r $TYXE_NGINX ]] || return 1
  grep -Fq "server_name $d" "$TYXE_NGINX" || return 1
  grep -Fq '/.well-known/acme-challenge/' "$TYXE_NGINX" || return 1
}

ensure_acme_http_server(){
  local d="$1" backup=''
  if [[ -e $ACME_HELPER ]]; then
    backup="${ACME_HELPER}.bak.$(date +%s%N)"
    cp -a "$ACME_HELPER" "$backup"
    rm -f "$ACME_HELPER"
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx
    else
      cp -a "$backup" "$ACME_HELPER"
      rm -f "$backup"
    fi
  fi
  if challenge_ok "$d"; then
    rm -f "$backup"
    return 0
  fi
  if tyxe_managed_has_acme "$d"; then
    red "TYXE nginx уже содержит ACME location для $d, но loopback-проверка не получает challenge-файл."
    challenge_debug "$d"
    [[ -n $backup && -e $backup ]] && rm -f "$backup"
    return 1
  fi
  yellow "Для $d нет рабочего ACME HTTP-01 location. TYXE добавит отдельный nginx helper только на TCP/80."
  cat > "$ACME_HELPER" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $d;
    root $SITE_ROOT;
    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOF
  if ! nginx -t; then
    rm -f "$ACME_HELPER"
    [[ -n $backup && -e $backup ]] && cp -a "$backup" "$ACME_HELPER"
    rm -f "$backup"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    red 'nginx -t не прошёл после добавления ACME helper.'
    return 1
  fi
  systemctl reload nginx
  if ! challenge_ok "$d"; then
    challenge_debug "$d"
    rm -f "$ACME_HELPER"
    [[ -n $backup && -e $backup ]] && cp -a "$backup" "$ACME_HELPER"
    rm -f "$backup"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    red "Даже после ACME helper nginx не отдаёт challenge для $d."
    return 1
  fi
  rm -f "$backup"
  green "ACME HTTP-01 helper для $d готов и сохранён для будущего продления."
}

preflight_http(){
  local d="$1" resolved pub
  command -v certbot >/dev/null 2>&1 || { red 'certbot не установлен.'; return 1; }
  command -v nginx >/dev/null 2>&1 || { red 'nginx не установлен.'; return 1; }
  systemctl is-active --quiet nginx || { red 'nginx не active.'; return 1; }
  ss -ltnH 'sport = :80' 2>/dev/null | grep -q . || { red 'На ENTER никто не слушает TCP/80.'; return 1; }
  resolved=$(public_dns_ipv4 "$d" || true)
  pub=$(public_ipv4)
  if [[ -n $resolved ]]; then
    if [[ -n $pub && $resolved != "$pub" ]]; then
      red "Публичный DNS $d -> $resolved, а IPv4 ENTER -> $pub"
      red 'Для HTTP-01 A-запись должна указывать на ENTER. Локальная запись /etc/hosts здесь не учитывается.'
      return 1
    fi
    ensure_acme_http_server "$d" || return 1
    green "DNS/HTTP-01 preflight: $d -> $resolved, webroot OK"
    return 0
  fi
  yellow "Не удалось независимо проверить публичную A-запись $d с этого VPS."
  yellow 'Проверка /etc/hosts намеренно не используется; возможно, провайдер блокирует public DNS/DoH.'
  [[ -n $pub ]] && yellow "Ожидаемый публичный IPv4 ENTER: $pub"
  ensure_acme_http_server "$d" || return 1
  green "Локальный HTTP-01 webroot для $d: OK"
  yellow 'TYXE не блокирует выпуск: окончательную внешнюю DNS/HTTP-проверку выполнит Let’s Encrypt.'
  return 0
}

install_renew_timer(){
  install -d -m 700 "$CERT_STORE" "$CERT_WORK" "$CERT_LOGS"
  cat > "$RENEW_SERVICE" <<EOF
[Unit]
Description=TYXE Let's Encrypt renewal
After=network-online.target nginx.service
Wants=network-online.target nginx.service

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
    ensure_acme_http_server "$DOMAIN" || true
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
  printf 'ACME HTTP helper: '
  [[ -s $ACME_HELPER ]] && echo "$ACME_HELPER" || echo 'not needed/not created'
}

renew_test(){
  cyan 'TYXE renewal dry-run'
  install_renew_timer
  certbot renew --dry-run --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS"
}

case "${1:-status}" in
  ensure|issue) shift; ensure_cert "${1:-proxy}" ;;
  status) status ;;
  renew-test) renew_test ;;
  *) echo 'Usage: tyxe-cert [status|ensure proxy|ensure panel|renew-test]' >&2; exit 2 ;;
esac