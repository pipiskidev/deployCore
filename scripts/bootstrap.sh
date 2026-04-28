#!/usr/bin/env bash
# One-time platform setup. Idempotent — safe to rerun.
#
# Architecture: HOST nginx + HOST certbot (apt-installed). Backends run in
# Docker and bind to 127.0.0.1:<port>; nginx proxies to those loopback ports.
# Optional Portainer and mail still run in Docker.
#
# Default flow (interactive without --no-ui):
#   1. Install Docker if missing.
#   2. Spin up a temporary web UI on port 8888 via `docker run node:20-alpine`.
#   3. Operator opens http://<server-ip>:8888 in their browser, fills out a
#      form (email, timezone, what to install, domains, tokens), clicks Save.
#   4. UI writes .env, projects/example/.env, shared/mail/mailserver.env (only the
#      ones selected) + .install-ui-result.json sidecar, then exits.
#   5. Bootstrap reads the sidecar to know which optional services to bring up
#      and continues with apt install of nginx + certbot, sync, enable timer,
#      then up-portainer.sh / up-mail.sh as needed.
#
# Usage:
#   ./scripts/bootstrap.sh                       # interactive web UI
#   ./scripts/bootstrap.sh --no-ui               # interactive shell prompts (no browser)
#   ./scripts/bootstrap.sh --no-ui --yes         # fully scripted, no extras (.env must exist)
#   ./scripts/bootstrap.sh --no-ui --with-portainer --with-mail
#   INSTALL_UI_PORT=9090 ./scripts/bootstrap.sh  # change the temp UI port

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

with_portainer=0
with_mail=0
no_prompt=0
no_ui=0
for arg in "$@"; do
  case "$arg" in
    --with-portainer) with_portainer=1 ;;
    --with-mail)      with_mail=1 ;;
    --yes|--no-prompt) no_prompt=1 ;;
    --no-ui)          no_ui=1 ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
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

# Step 1: Docker (also needed for the install UI when --no-ui isn't set).
ensure_docker_installed
require_docker

# Step 2: install UI (browser form). Skipped with --no-ui or --yes.
ui_port="${INSTALL_UI_PORT:-8888}"
sidecar="$REPO_ROOT/.install-ui-result.json"
rm -f "$sidecar"

if [[ "$no_ui" -eq 0 && "$no_prompt" -eq 0 ]]; then
  log "starting install UI on port $ui_port (Ctrl-C to cancel)"
  log "open in your browser: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>'):$ui_port"

  # Run via docker so we don't have to install Node on the host.
  # --user maps to host UID/GID so the .env files written are owned correctly.
  set +e
  docker run --rm \
    -p "${ui_port}:${ui_port}" \
    -v "$REPO_ROOT:/work" \
    --workdir /work \
    --user "$(id -u):$(id -g)" \
    -e "INSTALL_UI_PORT=${ui_port}" \
    node:20-alpine \
    node scripts/install-ui.js /work
  ui_rc=$?
  set -e

  case "$ui_rc" in
    0)   ok "configuration saved by install UI" ;;
    130) die "bootstrap cancelled by operator (UI)" ;;
    *)   die "install UI exited unexpectedly (rc=$ui_rc)" ;;
  esac

  # The UI may have flagged optional components in the sidecar.
  if [[ -f "$sidecar" ]]; then
    if grep -q '"install_portainer":true'  "$sidecar"; then with_portainer=1; fi
    if grep -q '"install_mail":true'       "$sidecar"; then with_mail=1; fi
  fi
fi

# Step 3: host nginx + certbot.
require_root_or_sudo
ensure_nginx_certbot_installed

# Step 4: .env (the UI usually writes this; --no-ui paths still need a fallback).
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
  || die "LETSENCRYPT_EMAIL still at the example default. Edit .env first (or use the install UI)."

# Step 4: sync nginx configs to /etc/nginx and reload.
log "syncing repo nginx/ → /etc/nginx/"
"$REPO_ROOT/scripts/sync-nginx.sh"

# Step 4b: enable nginx so it survives reboots.
sudo systemctl enable --now nginx

# Step 5: certbot auto-renewal via systemd timer (installed by certbot package).
if systemctl list-unit-files 2>/dev/null | grep -q '^certbot\.timer'; then
  log "enabling certbot.timer (twice-daily renewal check)"
  sudo systemctl enable --now certbot.timer
  ok "certbot.timer is active"
else
  warn "certbot.timer not found — your certbot package may not include it."
  warn "Renewals would need a manual cron entry: 0 3 * * * certbot renew --quiet"
fi

# Step 6: Portainer.
if [[ "$with_portainer" -eq 0 && "$no_prompt" -eq 0 ]]; then
  ask_yn "Install Portainer (publicly exposed admin UI on a dedicated subdomain)?" N \
    && with_portainer=1
fi
if [[ "$with_portainer" -eq 1 ]]; then
  if [[ -z "${PORTAINER_DOMAIN:-}" && "$no_prompt" -eq 1 ]]; then
    die "--with-portainer + --yes requires PORTAINER_DOMAIN set in .env"
  fi
  log "running up-portainer.sh"
  "$REPO_ROOT/scripts/up-portainer.sh"
fi

# Step 7: mail.
if [[ "$with_mail" -eq 0 && "$no_prompt" -eq 0 ]]; then
  ask_yn "Install mail server (shared/mail/, opt-in SMTP)?" N && with_mail=1
fi
if [[ "$with_mail" -eq 1 ]]; then
  if [[ ! -f "$REPO_ROOT/shared/mail/mailserver.env" ]]; then
    cp "$REPO_ROOT/shared/mail/mailserver.env.example" "$REPO_ROOT/shared/mail/mailserver.env"
    warn "created shared/mail/mailserver.env from example."
    warn "Edit it (MAIL_DOMAIN, LETSENCRYPT_DOMAIN, LETSENCRYPT_EMAIL) and rerun: ./scripts/up-mail.sh"
  else
    "$REPO_ROOT/scripts/up-mail.sh"
  fi
fi

cat <<EOF

${C_BOLD}Bootstrap complete.${C_RESET}

  What's running:
    nginx            (host service, :80/:443)
    certbot.timer    (twice-daily renewal check)
$([[ $with_portainer -eq 1 ]] && echo "    portainer        (admin UI at https://${PORTAINER_DOMAIN:-})")
$([[ $with_mail -eq 1 ]] && echo "    mailserver       (SMTP/IMAP)")

  Next:
    Add a project:        ./scripts/add-project.sh <name> <domain>
    Bring a project up:   ./scripts/up-project.sh <name> [profile]
    Reload nginx:         ./scripts/reload-nginx.sh
    Issue/renew cert:     ./scripts/issue-cert.sh <domain>
    Sync nginx changes:   ./scripts/sync-nginx.sh

  Editing nginx files:
    The source of truth is the repo (nginx/). After editing, run
    ./scripts/sync-nginx.sh to copy + reload. Project configs
    (/etc/nginx/conf.d/<name>.conf) are SYMLINKS to projects/<name>/nginx.conf,
    so edits apply immediately on ./scripts/reload-nginx.sh — no sync needed.

EOF
