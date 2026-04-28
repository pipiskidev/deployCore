#!/usr/bin/env bash
# Issue a Let's Encrypt certificate for <domain> via webroot using HOST certbot.
#
# Usage: ./scripts/issue-cert.sh example.com
#
# Prereq: host nginx must be running and serving /.well-known/acme-challenge/
# from /var/www/certbot/ for any unknown host (this is the role of
# /etc/nginx/conf.d/_default.conf, deployed by sync-nginx.sh during bootstrap).
#
# Honors ACME_STAGING=1 in .env to use Let's Encrypt staging.
# Auto-renewal is handled by the certbot.timer systemd unit (installed by the
# certbot package). We add a host deploy-hook so renewals trigger nginx reload.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

domain="${1-}"
validate_domain "$domain"

require_tool certbot
require_root_or_sudo
load_env

[[ -n "${LETSENCRYPT_EMAIL:-}" ]] || die "LETSENCRYPT_EMAIL not set in .env"

# Sanity: host nginx is running and listening on :80.
if ! sudo systemctl is-active --quiet nginx; then
  die "nginx is not active (sudo systemctl status nginx). Run ./scripts/bootstrap.sh first."
fi

# Make sure the webroot dir exists; sync-nginx.sh creates it during bootstrap
# but issue-cert.sh may run before any sync.
sudo mkdir -p /var/www/certbot

# Install a deploy-hook script so certbot --renew triggers nginx reload.
hook_path=/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
if [[ ! -f "$hook_path" ]]; then
  log "installing certbot deploy hook (reload nginx after renewals)"
  sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nset -e\nsystemctl reload nginx\n' | sudo tee "$hook_path" >/dev/null
  sudo chmod 0755 "$hook_path"
fi

staging_args=()
if [[ "${ACME_STAGING:-0}" == "1" ]]; then
  warn "ACME_STAGING=1 — issuing a staging cert (browser will not trust it)"
  staging_args=(--staging)
fi

log "requesting cert for $domain via webroot"
sudo certbot certonly \
  --webroot \
  -w /var/www/certbot \
  -d "$domain" \
  --email "$LETSENCRYPT_EMAIL" \
  --agree-tos \
  --no-eff-email \
  --non-interactive \
  --keep-until-expiring \
  "${staging_args[@]}"

ok "cert ready: /etc/letsencrypt/live/$domain/"
