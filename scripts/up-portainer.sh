#!/usr/bin/env bash
# Bring up the optional Portainer admin UI.
#
# - Validates PORTAINER_DOMAIN in .env (asks if missing)
# - Issues a Let's Encrypt cert
# - Renders /etc/nginx/conf.d/portainer.conf from the template
# - Starts the Portainer container (loopback bind 127.0.0.1:9000)
# - Reloads nginx
#
# Idempotent: rerunning is safe.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_docker
require_root_or_sudo
load_env

domain="${PORTAINER_DOMAIN:-}"
if [[ -z "$domain" ]]; then
  printf "Portainer domain (e.g. portainer.example.com): "
  read -r domain
  [[ -n "$domain" ]] || die "domain is required"
  if grep -q '^PORTAINER_DOMAIN=' "$REPO_ROOT/.env"; then
    sed -i.bak "s|^PORTAINER_DOMAIN=.*|PORTAINER_DOMAIN=$domain|" "$REPO_ROOT/.env"
    rm -f "$REPO_ROOT/.env.bak"
  else
    echo "PORTAINER_DOMAIN=$domain" >> "$REPO_ROOT/.env"
  fi
fi
validate_domain "$domain"

template="$REPO_ROOT/nginx/conf.d/portainer.conf.template"
target="/etc/nginx/conf.d/portainer.conf"

[[ -f "$template" ]] || die "missing template: $template"

log "issuing Let's Encrypt cert for $domain"
"$REPO_ROOT/scripts/issue-cert.sh" "$domain"

log "rendering $target"
sudo bash -c "sed 's|\${PORTAINER_DOMAIN}|$domain|g' '$template' > '$target'"
sudo chmod 0644 "$target"

log "starting Portainer container"
docker compose -f "$REPO_ROOT/portainer/docker-compose.yml" up -d

log "reloading nginx"
"$REPO_ROOT/scripts/reload-nginx.sh"
ok "Portainer available at https://$domain"

cat <<EOF

  Security note:
    Portainer is now publicly reachable. Set a strong admin password on
    first login. To restrict access by IP, edit $target and uncomment
    the allow/deny block, then ./scripts/reload-nginx.sh.

EOF
