#!/usr/bin/env bash
# Issue a Let's Encrypt certificate for <domain> via webroot.
#
# Usage: ./scripts/issue-cert.sh example.com
#
# Prereq: core must be up (bootstrap.sh) so that core-nginx serves
# /.well-known/acme-challenge/ for any host (via _default.conf).
#
# Honors ACME_STAGING=1 in .env to use Let's Encrypt staging
# (untrusted certs, but no rate limits — useful for testing).

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

domain="${1-}"
validate_domain "$domain"

require_docker
load_env

[[ -n "${LETSENCRYPT_EMAIL:-}" ]] || die "LETSENCRYPT_EMAIL not set in .env"

# Sanity-check that core-nginx is running and binds :80.
if ! core_compose ps --status running --services 2>/dev/null | grep -q '^nginx$'; then
  die "core-nginx is not running. Run ./scripts/bootstrap.sh first."
fi

staging_args=()
if [[ "${ACME_STAGING:-0}" == "1" ]]; then
  warn "ACME_STAGING=1 — issuing a staging cert (browser will not trust it)"
  staging_args=(--staging)
fi

log "requesting cert for $domain via webroot"
core_compose run --rm certbot certonly \
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
