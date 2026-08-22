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
DEPLOY_HOOK=/usr/local/sbin/tyxe-cert-deploy-hook

red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*" >&2; }
cyan(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
getenv_file(){ sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
yesno(){ local p="$1" v=''; read -r -p "$p [y/N]: " v </dev/tty || true; [[ "$v" =~ ^[yY]$ ]]; }

[[ $EUID -eq 0 ]] || { red 'Запустите через sudo/root.'; exit 1; }
[[ -r $SETTINGS ]] || { red 'TYXE settings не найдены.'; exit 1; }
[[ "$(getenv_file "$SETTINGS" PROXY_POOL_ROLE)" == controller ]] || { red 'Сертификаты управляются на ENTER/controller.'; exit 1; }

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
    red 'Разрешены только proxy/panel домены текущей установки TYXE.'
    return 1
  fi
}

ensure_dirs(){ install -d -m 700 "$CERT_STORE" "$CERT_WORK" "$CERT_LOGS"; }

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

renewal_conf(){
  local d="$1" c
  [[ -r "$CERT_STORE/renewal/$d.conf" ]] && { printf '%s' "$CERT_STORE/renewal/$d.conf"; return 0; }
  for c in "$CERT_STORE"/renewal/*.conf; do
    [[ -r $c ]] || continue
    grep -Fq "live/$d/" "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}

authenticator_for(){
  local d="$1" c
  c=$(renewal_conf "$d" || true)
  [[ -n $c ]] || { echo unknown; return 0; }
  sed -n 's/^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*//p' "$c" | tail -n1 | tr -d '[:space:]'
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
  local d="$1" r ans host ip endpoint
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

check_public_dns(){
  local d="$1" resolved pub
  resolved=$(public_dns_ipv4 "$d" || true)
  pub=$(public_ipv4)
  if [[ -n $resolved ]]; then
    if [[ -n $pub && $resolved != "$pub" ]]; then
      red "Публичный DNS $d -> $resolved, а IPv4 ENTER -> $pub"
      red 'Для HTTP-01 A-запись должна указывать на ENTER.'
      return 1
    fi
    green "Публичный DNS: $d -> $resolved"
    return 0
  fi
  yellow "Не удалось независимо проверить публичную A-запись $d с этого VPS."
  yellow 'Окончательную внешнюю проверку выполнит Let’s Encrypt.'
  [[ -n $pub ]] && yellow "Ожидаемый публичный IPv4 ENTER: $pub"
}

challenge_ok(){
  local d="$1" token path got
  systemctl is-active --quiet nginx || return 1
  ss -ltnH 'sport = :80' 2>/dev/null | grep -q . || return 1
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

certbot_common(){
  printf '%s\n' \
    --agree-tos --non-interactive --no-eff-email \
    --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS"
}

issue_webroot(){
  local d="$1" email="$2" args
  mapfile -t args < <(certbot_common)
  args=(certonly --webroot -w "$SITE_ROOT" -d "$d" --cert-name "$d" "${args[@]}")
  [[ -n $email ]] && args+=(--email "$email") || args+=(--register-unsafely-without-email)
  certbot "${args[@]}"
}

install_renew_timer(){
  ensure_dirs
  cat > "$DEPLOY_HOOK" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
/usr/sbin/nginx -t
/bin/systemctl reload nginx
EOF
  chmod 0755 "$DEPLOY_HOOK"
  cat > "$RENEW_SERVICE" <<EOF
[Unit]
Description=TYXE Let's Encrypt webroot renewal
After=network-online.target nginx.service
Wants=network-online.target nginx.service

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --no-random-sleep-on-renew --config-dir $CERT_STORE --work-dir $CERT_WORK --logs-dir $CERT_LOGS --quiet --deploy-hook $DEPLOY_HOOK
EOF
  cat > "$RENEW_TIMER" <<'EOF'
[Unit]
Description=TYXE automatic TLS renewal

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now tyxe-cert-renew.timer >/dev/null
}

renew_one(){
  local d="$1" dry="${2:-0}" auth args
  cert_dir "$d" >/dev/null 2>&1 || return 0
  renewal_conf "$d" >/dev/null 2>&1 || { red "Нет renewal config для $d."; return 1; }
  auth=$(authenticator_for "$d")
  [[ $auth == webroot ]] || { red "$d использует authenticator=$auth; TYXE v0.3 требует webroot."; return 1; }
  challenge_ok "$d" || { red "Webroot-проверка для $d не проходит. Renewal остановлен без изменения сертификата."; return 1; }
  args=(certbot renew --cert-name "$d" --no-random-sleep-on-renew --config-dir "$CERT_STORE" --work-dir "$CERT_WORK" --logs-dir "$CERT_LOGS")
  (( dry )) && args+=(--dry-run) || args+=(--quiet)
  "${args[@]}"
}

renew_all(){
  local dry="${1:-0}" d failed=0
  ensure_dirs
  for d in "$PROXY_DOMAIN" "$PANEL_DOMAIN"; do
    [[ -n $d ]] || continue
    cyan "Renewal: $d ($(authenticator_for "$d"))"
    renew_one "$d" "$dry" || failed=1
  done
  (( failed == 0 )) || { red 'Одна или несколько ACME renewal-проверок завершились ошибкой.'; return 1; }
  if (( dry == 0 )); then
    nginx -t && systemctl reload nginx
  fi
}

ensure_cert(){
  resolve_target "${1:-proxy}" || return 1
  cyan "Certificate: $DOMAIN"
  command -v certbot >/dev/null 2>&1 || { red 'certbot не установлен.'; return 1; }
  ensure_dirs
  check_public_dns "$DOMAIN" || return 1

  local existing email=''
  if existing=$(cert_dir "$DOMAIN"); then
    green "Сертификат уже существует: $existing"
    openssl x509 -in "$existing/fullchain.pem" -noout -subject -issuer -enddate 2>/dev/null || true
    green "Renewal authenticator: $(authenticator_for "$DOMAIN")"
    challenge_ok "$DOMAIN" || { red 'HTTP-01 webroot не работает. Исправьте nginx/TCP 80 перед renewal.'; return 1; }
    install_renew_timer
    return 0
  fi

  challenge_ok "$DOMAIN" || {
    red "HTTP-01 webroot для $DOMAIN не работает."
    red 'TYXE не использует standalone: nginx должен продолжать работать во время выпуска/продления.'
    return 1
  }

  green 'Локальный HTTP-01 webroot: OK'
  yellow "Будет выпущен Let's Encrypt сертификат для $DOMAIN через webroot и сохранён вне rollback TYXE."
  yesno 'Выпустить сертификат?' || return 0
  read -r -p "Email Let's Encrypt (пусто = без email): " email </dev/tty || true

  if ! issue_webroot "$DOMAIN" "$email"; then
    yellow 'Webroot issuance не удался. Автоматический повтор не выполняется, чтобы не расходовать ACME rate limits.'
    return 1
  fi

  existing=$(cert_dir "$DOMAIN") || { red 'Certbot завершился, но сертификат не найден.'; return 1; }
  install_renew_timer
  green "Готово: $existing"
  green "Renewal authenticator: $(authenticator_for "$DOMAIN")"
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
      printf '  authenticator: %s\n' "$(authenticator_for "$d")"
      if challenge_ok "$d"; then echo '  webroot probe: OK'; else echo '  webroot probe: FAILED'; fi
    else
      echo 'missing'
    fi
  done
  printf '\nRenew timer: '
  systemctl is-enabled tyxe-cert-renew.timer 2>/dev/null || true
  systemctl list-timers tyxe-cert-renew.timer --no-pager 2>/dev/null || true
}

renew_test(){
  cyan 'TYXE renewal dry-run'
  install_renew_timer
  renew_all 1
}

case "${1:-status}" in
  ensure|issue) shift; ensure_cert "${1:-proxy}" ;;
  status) status ;;
  renew-auto) renew_all 0 ;;
  renew-test) renew_test ;;
  *) echo 'Usage: tyxe-cert [status|ensure proxy|ensure panel|renew-test|renew-auto]' >&2; exit 2 ;;
esac
