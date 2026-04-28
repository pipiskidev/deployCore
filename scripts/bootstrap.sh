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
#   ./scripts/bootstrap.sh --force-ui            # re-open the UI even if .env exists
#   INSTALL_UI_PORT=9090 ./scripts/bootstrap.sh  # change the temp UI port
#
# Re-running bootstrap.sh on an already-configured server is safe: every step
# is idempotent and skips work it doesn't need to do (Docker/nginx/certbot
# are not reinstalled, network 'web' isn't recreated, the install UI is
# skipped if .env already exists). Use ./scripts/preflight.sh to see state
# without modifying anything.

set -euo pipefail

# Self-heal executable bits. If this repo was cloned with file modes lost
# (committed from Windows without +x, or a tarball that dropped them),
# nothing in scripts/ can run. Restore +x here before anything else does.
_self_dir="$(dirname "$(readlink -f "$0")")"
_repo_root="$(cd "$_self_dir/.." && pwd)"
chmod +x "$_self_dir"/*.sh "$_self_dir"/lib/*.sh 2>/dev/null || true

# shellcheck source=lib/common.sh
source "$_self_dir/lib/common.sh"

with_portainer=0
with_mail=0
no_prompt=0
no_ui=0
force_ui=0
for arg in "$@"; do
  case "$arg" in
    --with-portainer) with_portainer=1 ;;
    --with-mail)      with_mail=1 ;;
    --yes|--no-prompt) no_prompt=1 ;;
    --no-ui)          no_ui=1 ;;
    --force-ui)       force_ui=1 ;;
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

# Show the user what's already installed/configured before doing anything.
# Each subsequent step is a no-op if its component is already in the desired
# state — so a re-run of bootstrap.sh on a fully-configured server is safe.
print_inventory

# Step 1: Docker (also needed for the install UI when --no-ui isn't set).
ensure_docker_installed
require_docker

# Step 2: install UI (browser form). Skipped with --no-ui, --yes, OR if .env
# already exists with a non-default LETSENCRYPT_EMAIL (re-run scenario).
# Override the auto-skip with --force-ui if you want to re-edit values.
#
# The sidecar (.install-ui-result.json) PERSISTS across runs so we remember
# which optional services the operator selected previously, even when the UI
# is auto-skipped. This is critical for resuming after a partial failure
# (e.g., bootstrap died on portainer reload — on the next run we still know
# example-backend was supposed to come up).
ui_port="${INSTALL_UI_PORT:-8888}"
sidecar="$REPO_ROOT/.install-ui-result.json"

# Auto-skip on re-runs: if .env exists and has a real LETSENCRYPT_EMAIL, the
# operator already configured this server. Don't open UI again unless asked.
if [[ "$no_ui" -eq 0 && "$force_ui" -eq 0 && -f "$REPO_ROOT/.env" ]]; then
  existing_email=$(grep -E '^LETSENCRYPT_EMAIL=' "$REPO_ROOT/.env" 2>/dev/null | cut -d= -f2-)
  if [[ -n "$existing_email" && "$existing_email" != "admin@example.com" ]]; then
    ok ".env already configured (LETSENCRYPT_EMAIL=$existing_email) — skipping install UI"
    warn "to re-open the browser form, rerun:  ./scripts/bootstrap.sh --force-ui"
    no_ui=1
  fi
fi

if [[ "$no_ui" -eq 0 && "$no_prompt" -eq 0 ]]; then
  # Only delete the old sidecar if we're actually about to write a new one.
  rm -f "$sidecar"

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
fi

# Always read the sidecar (whether the UI ran this time or not).
if [[ -f "$sidecar" ]]; then
  grep -q '"install_portainer":true' "$sidecar" && with_portainer=1 || true
  grep -q '"install_mail":true'      "$sidecar" && with_mail=1      || true
  grep -q '"install_backend":true'   "$sidecar" && ex_backend=1     || true
  grep -q '"install_frontend":true'  "$sidecar" && ex_frontend=1    || true
  grep -q '"install_mongo":true'     "$sidecar" && ex_mongo=1       || true
elif [[ -f "$REPO_ROOT/projects/example/.env" ]]; then
  # Recovery case: example/.env exists but sidecar is gone (e.g., the previous
  # bootstrap deleted it before crashing on a different step). Infer that the
  # operator wanted SOMETHING from example and bring up whatever isn't already
  # running.
  warn "projects/example/.env exists but sidecar is missing"
  warn "  bringing up all example services that aren't already running"
  warn "  (run ./scripts/bootstrap.sh --force-ui to redo the selection cleanly)"
  ex_backend=1
  ex_frontend=1
  ex_mongo=1
fi
ex_backend="${ex_backend:-0}"
ex_frontend="${ex_frontend:-0}"
ex_mongo="${ex_mongo:-0}"

# Print the resolved selection so the operator sees what bootstrap will do.
selected=()
[[ "$with_portainer" -eq 1 ]] && selected+=("portainer")
[[ "$with_mail"      -eq 1 ]] && selected+=("mail")
[[ "$ex_backend"     -eq 1 ]] && selected+=("example-backend")
[[ "$ex_frontend"    -eq 1 ]] && selected+=("example-frontend")
[[ "$ex_mongo"       -eq 1 ]] && selected+=("example-mongo")
if [[ "${#selected[@]}" -gt 0 ]]; then
  log "selected optional services: ${selected[*]}"
else
  log "no optional services selected — only nginx + certbot will be set up"
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

# Step 5: certbot auto-renewal. On RHEL family this is `certbot.timer`. On
# Debian/Ubuntu the certbot package installs /etc/cron.d/certbot instead
# (which runs `certbot -q renew` twice a day). Either is fine; warn only if
# neither is present.
if systemctl list-unit-files 2>/dev/null | grep -q '^certbot\.timer'; then
  log "enabling certbot.timer (twice-daily renewal check)"
  sudo systemctl enable --now certbot.timer
  ok "certbot.timer is active"
elif [[ -f /etc/cron.d/certbot ]]; then
  ok "certbot renewals handled via /etc/cron.d/certbot (Debian/Ubuntu default)"
else
  warn "neither certbot.timer nor /etc/cron.d/certbot found — auto-renewal NOT scheduled"
  warn "  add a manual cron entry:  0 3 * * * /usr/bin/certbot renew --quiet"
fi

# Helper: returns 0 if a container with the given name is currently running.
container_running() {
  [[ "$(docker ps --filter "name=^${1}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null)" == "$1" ]]
}

# Step 6: Portainer.
# Skip the question entirely if it's already running. up-portainer.sh is
# itself idempotent, but asking the operator about something that's already
# done is noise.
if container_running core-portainer; then
  ok "Portainer already running (core-portainer container) — skipping"
  with_portainer=0
elif [[ "$with_portainer" -eq 0 && "$no_prompt" -eq 0 ]]; then
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
if container_running mailserver; then
  ok "mailserver already running — skipping"
  with_mail=0
elif [[ "$with_mail" -eq 0 && "$no_prompt" -eq 0 ]]; then
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

# Step 8: example project services. Each example service was independently
# selected in the install UI. Map the flags into compose profiles and bring
# only the requested subset up. We don't symlink nginx or issue certs here —
# that's the operator's call, since they may run example backend-only without
# a domain. The README documents the wire-up commands.
#
# For each requested service, skip its profile if its container is already
# running. Then `docker compose up` is only invoked if at least one profile
# remains — avoiding a pointless compose call when everything is already up.
container_running example-backend && {
  [[ "$ex_backend"  -eq 1 ]] && ok "example-backend already running — skipping"
  ex_backend=0
}
container_running example-web && {
  [[ "$ex_frontend" -eq 1 ]] && ok "example-web already running — skipping"
  ex_frontend=0
}
container_running example-mongo && {
  [[ "$ex_mongo"    -eq 1 ]] && ok "example-mongo already running — skipping"
  ex_mongo=0
}

example_profiles=()
[[ "$ex_backend"  -eq 1 ]] && example_profiles+=(--profile backend)
[[ "$ex_frontend" -eq 1 ]] && example_profiles+=(--profile web)
[[ "$ex_mongo"    -eq 1 ]] && example_profiles+=(--profile mongo)

if [[ "${#example_profiles[@]}" -gt 0 ]]; then
  if [[ ! -f "$REPO_ROOT/projects/example/.env" ]]; then
    warn "example services selected but projects/example/.env missing — skipping example bring-up"
    warn "  fill projects/example/.env, then run: docker compose -f projects/example/docker-compose.yml ${example_profiles[*]} up -d"
  else
    log "starting example services (${example_profiles[*]})"
    docker compose -f "$REPO_ROOT/projects/example/docker-compose.yml" "${example_profiles[@]}" up -d
    ok "example services up"
    if [[ "$ex_backend" -eq 1 || "$ex_frontend" -eq 1 ]]; then
      warn "Public access is NOT yet wired:"
      warn "  1. Edit projects/example/nginx.conf — replace 'example.example.com' with your real domain"
      warn "  2. ./scripts/issue-cert.sh <your-domain>"
      warn "  3. sudo ln -sf \"\$(pwd)/projects/example/nginx.conf\" /etc/nginx/conf.d/example.conf"
      warn "  4. ./scripts/reload-nginx.sh"
    fi
  fi
fi

cat <<EOF

${C_BOLD}Bootstrap complete.${C_RESET}

  What's running:
    nginx            (host service, :80/:443)
    certbot.timer    (twice-daily renewal check)
$([[ $with_portainer -eq 1 ]] && echo "    portainer        (admin UI at https://${PORTAINER_DOMAIN:-})")
$([[ $with_mail -eq 1 ]] && echo "    mailserver       (SMTP/IMAP)")
$([[ $ex_backend  -eq 1 ]] && echo "    example-backend  (Spring Boot, 127.0.0.1:8066)")
$([[ $ex_frontend -eq 1 ]] && echo "    example-web      (Next.js, 127.0.0.1:3005)")
$([[ $ex_mongo    -eq 1 ]] && echo "    example-mongo    (internal, no host port)")

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
