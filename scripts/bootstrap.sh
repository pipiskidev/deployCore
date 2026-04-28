#!/usr/bin/env bash
# One-time platform setup. Idempotent — safe to rerun.
#
# By default brings up only the mandatory core: nginx + certbot. Other
# components are opt-in.
#
# Usage:
#   ./scripts/bootstrap.sh                        # interactive: asks about each optional component
#   ./scripts/bootstrap.sh --yes                  # accept defaults (no prompts, no extras)
#   ./scripts/bootstrap.sh --with-portainer       # +portainer
#   ./scripts/bootstrap.sh --with-mail            # +mail (shared/mail/)
#   ./scripts/bootstrap.sh --with-portainer --with-mail
#   ./scripts/bootstrap.sh --no-prompt            # alias for --yes
#
# Steps:
#   1. Install Docker if missing (Debian/Ubuntu/RHEL family).
#   2. Verify Docker + Docker Compose v2 are present.
#   3. Ensure .env exists; if not, copy from .env.example and bail.
#   4. Create the external Docker network 'web' if missing.
#   5. Bring up core nginx + certbot (always).
#   6. Optionally bring up portainer.
#   7. Optionally bring up mail (shared/mail/).

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

with_portainer=0
with_mail=0
no_prompt=0
for arg in "$@"; do
  case "$arg" in
    --with-portainer) with_portainer=1 ;;
    --with-mail)      with_mail=1 ;;
    --yes|--no-prompt) no_prompt=1 ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown flag: $arg (see --help)" ;;
  esac
done

ask_yn() {
  local prompt="$1" default="${2:-N}" reply
  if [[ "$no_prompt" -eq 1 ]]; then
    [[ "$default" =~ ^[Yy]$ ]]
    return
  fi
  printf "%s [%s] " "$prompt" "${default}/$([[ $default =~ ^[Yy]$ ]] && echo n || echo y)"
  read -r reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

ensure_docker_installed
require_docker

if [[ ! -f "$REPO_ROOT/.env" ]]; then
  if [[ -f "$REPO_ROOT/.env.example" ]]; then
    cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
    warn "created .env from .env.example. Edit it (LETSENCRYPT_EMAIL at minimum) and rerun."
    exit 1
  else
    die ".env and .env.example both missing — repo is broken"
  fi
fi

load_env
[[ "${LETSENCRYPT_EMAIL:-admin@example.com}" != "admin@example.com" ]] \
  || die "LETSENCRYPT_EMAIL still at the example default. Edit .env first."

if ! docker network inspect web >/dev/null 2>&1; then
  log "creating Docker network 'web'"
  docker network create web >/dev/null
  ok "network 'web' created"
else
  ok "network 'web' already exists"
fi

# Ask about optional components if not explicitly toggled by flags.
if [[ "$with_portainer" -eq 0 && "$no_prompt" -eq 0 ]]; then
  ask_yn "Install Portainer (admin UI on 127.0.0.1:9000)?" N && with_portainer=1
fi
if [[ "$with_mail" -eq 0 && "$no_prompt" -eq 0 ]]; then
  ask_yn "Install mail server (shared/mail/, opt-in SMTP)?" N && with_mail=1
fi

# Compose --profile flags. Empty string = no profiles = only services without
# profile come up (nginx, certbot).
core_profiles=()
[[ "$with_portainer" -eq 1 ]] && core_profiles+=(--profile portainer)

log "starting core (nginx + certbot$([[ $with_portainer -eq 1 ]] && echo ' + portainer'))"
core_compose "${core_profiles[@]}" up -d --build
ok "core is up"

log "verifying nginx config"
core_compose exec -T nginx nginx -t

if [[ "$with_mail" -eq 1 ]]; then
  if [[ ! -f "$REPO_ROOT/shared/mail/mailserver.env" ]]; then
    cp "$REPO_ROOT/shared/mail/mailserver.env.example" "$REPO_ROOT/shared/mail/mailserver.env"
    warn "created shared/mail/mailserver.env from example."
    warn "Edit it (MAIL_DOMAIN, LETSENCRYPT_DOMAIN, LETSENCRYPT_EMAIL) and rerun: ./scripts/up-mail.sh"
  else
    log "starting mail server"
    docker compose --project-name core -f "$REPO_ROOT/shared/mail/docker-compose.yml" up -d
    ok "mail is up"
  fi
fi

cat <<EOF

${C_BOLD}Bootstrap complete.${C_RESET}

  What's running:
    core-nginx       (reverse proxy on :80/:443)
    core-certbot     (12h renewal loop)
$([[ $with_portainer -eq 1 ]] && echo "    core-portainer   (admin UI, 127.0.0.1:9000)")
$([[ $with_mail -eq 1 ]] && echo "    mailserver       (SMTP/IMAP)")

  Next:
    Add a project:        ./scripts/add-project.sh <name> <domain>
    Bring a project up:   ./scripts/up-project.sh <name> [profile]
    Reload nginx:         ./scripts/reload-nginx.sh
    Issue/renew cert:     ./scripts/issue-cert.sh <domain>
$([[ $with_portainer -eq 1 ]] && echo "
  Portainer:
    ssh -L 9000:localhost:9000 \$USER@\$(hostname -f 2>/dev/null || hostname)
    then open http://localhost:9000")

EOF
