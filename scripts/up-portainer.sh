#!/usr/bin/env bash
# Bring up the optional Portainer admin UI.
#
# - Validates PORTAINER_DOMAIN in .env (asks if missing)
# - Issues a Let's Encrypt cert (skipped if cert already exists)
# - Renders /etc/nginx/conf.d/portainer.conf from the template (skipped if
#   already in place with the same domain — use --force to re-render)
# - Starts the Portainer container (skipped if already running)
# - Reloads nginx (skipped if no config changed)
#
# Flags:
#   --force    Re-render /etc/nginx/conf.d/portainer.conf even if it already
#              exists and looks valid. Use after a template update.
#
# Idempotent: rerunning on a fully-deployed Portainer is a no-op.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --help|-h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $arg" ;;
  esac
done

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
cert_dir="/etc/letsencrypt/live/$domain"
needs_reload=0

[[ -f "$template" ]] || die "missing template: $template"

# Step 1: cert.
if sudo test -f "$cert_dir/fullchain.pem" && sudo test -f "$cert_dir/privkey.pem"; then
  ok "cert exists at $cert_dir — skipping issue-cert.sh"
else
  log "issuing Let's Encrypt cert for $domain"
  "$REPO_ROOT/scripts/issue-cert.sh" "$domain"
fi

# Step 2: nginx conf rendering. Skip if file exists and references our domain
# AND --force was NOT passed.
if [[ "$force" -eq 0 ]] && sudo test -f "$target" && sudo grep -q "server_name ${domain};" "$target"; then
  ok "$target already configured for $domain — skipping render (use --force to re-render)"
else
  log "rendering $target"
  sudo bash -c "sed 's|\${PORTAINER_DOMAIN}|$domain|g' '$template' > '$target'"
  sudo chmod 0644 "$target"
  needs_reload=1
fi

# Step 3: container.
running=$(docker ps --filter "name=^core-portainer$" --format '{{.State}}' 2>/dev/null || true)
if [[ "$running" == "running" ]]; then
  ok "core-portainer container already running — skipping compose up"
else
  log "starting Portainer container"
  docker compose -f "$REPO_ROOT/portainer/docker-compose.yml" up -d
  needs_reload=1
fi

# Step 4: nginx reload.
if [[ "$needs_reload" -eq 1 ]]; then
  log "reloading nginx (config or container changed)"
  "$REPO_ROOT/scripts/reload-nginx.sh"
else
  ok "no nginx changes — skipping reload"
fi

ok "Portainer available at https://$domain"

cat <<EOF

  Security note:
    Portainer is now publicly reachable. Set a strong admin password on
    first login. To restrict access by IP, edit $target and uncomment
    the allow/deny block, then ./scripts/reload-nginx.sh.

EOF
