#!/usr/bin/env bash
# Add a new project to a running deployCore platform (host-nginx model).
#
# Usage:
#   ./scripts/add-project.sh <name> <domain>                    [flags]
#   ./scripts/add-project.sh <name> --no-domain                 [flags]
#
# Flags:
#   --no-domain     No public hostname, no nginx routing, no TLS cert.
#                   Container still binds to 127.0.0.1:<HOST_PORT> for internal
#                   access (other containers, SSH tunnels, host-side scripts).
#                   <domain> argument is omitted when --no-domain is used.
#   --image <ref>   Docker image for the app container. Skips the editor step.
#                   Example: --image ghcr.io/myorg/myapp:latest
#   --app-port <n>  Port the app listens on inside the container.
#                   Skips the editor step. Example: --app-port 8080
#   --profile <p>   Compose profile to bring up (default: full).
#                   Repeatable: --profile backend --profile worker.
#   --skip-cert     Don't issue a Let's Encrypt cert (DNS not ready).
#                   Implies you'll wire it up later with issue-cert.sh.
#   --skip-up       Don't bring up containers — only scaffold + cert + nginx wiring.
#   --port <n>      Use this HOST_PORT instead of auto-assigning.
#
# Fully-scripted backend-only example:
#   ./scripts/add-project.sh worker --no-domain \
#       --image eclipse-temurin:17-jdk-jammy --app-port 8080
#
# Steps (full mode, with domain):
#   1. Validate name and domain.
#   2. Copy projects/_template/ to projects/<name>/.
#   3. Auto-pick a free HOST_PORT in 10000-19999 (or use --port).
#   4. Substitute placeholders.
#   5. Open projects/<name>/.env in $EDITOR (fill IMAGE, APP_PORT, project secrets).
#   6. Issue Let's Encrypt cert (unless --skip-cert).
#   7. Symlink projects/<name>/nginx.conf → /etc/nginx/conf.d/<name>.conf.
#   8. docker compose up -d (unless --skip-up).
#   9. Reload host nginx (unless --skip-up).
#
# Steps (--no-domain mode):
#   1, 2, 3, 4, 5, 8 — same as above. Steps 6, 7, 9 are SKIPPED.
#   The project's nginx.conf is left in projects/<name>/ for reference but
#   not symlinked anywhere.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

skip_cert=0
skip_up=0
no_domain=0
fixed_port=""
arg_image=""
arg_app_port=""
profiles=()
positional=()
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --skip-cert) skip_cert=1 ;;
    --skip-up)   skip_up=1 ;;
    --no-domain) no_domain=1 ;;
    --port)
      i=$((i+1)); [[ $i -le $# ]] || die "--port requires a value"
      fixed_port="${!i}"
      ;;
    --port=*) fixed_port="${arg#*=}" ;;
    --image)
      i=$((i+1)); [[ $i -le $# ]] || die "--image requires a value"
      arg_image="${!i}"
      ;;
    --image=*) arg_image="${arg#*=}" ;;
    --app-port)
      i=$((i+1)); [[ $i -le $# ]] || die "--app-port requires a value"
      arg_app_port="${!i}"
      ;;
    --app-port=*) arg_app_port="${arg#*=}" ;;
    --profile)
      i=$((i+1)); [[ $i -le $# ]] || die "--profile requires a value"
      profiles+=("--profile" "${!i}")
      ;;
    --profile=*) profiles+=("--profile" "${arg#*=}") ;;
    --help|-h)
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown flag: $arg (see --help)" ;;
    *) positional+=("$arg") ;;
  esac
  i=$((i+1))
done

if [[ "$no_domain" -eq 1 ]]; then
  [[ "${#positional[@]}" -eq 1 ]] \
    || die "usage with --no-domain: $(basename "$0") <name> --no-domain [flags]"
  name="${positional[0]}"
  domain=""    # placeholder, never used downstream
else
  [[ "${#positional[@]}" -eq 2 ]] \
    || die "usage: $(basename "$0") <name> <domain> [flags]  (or --no-domain to skip the domain)"
  name="${positional[0]}"
  domain="${positional[1]}"
  validate_domain "$domain"
fi

validate_project_name "$name"

require_docker
# Sudo only needed if we're going to symlink into /etc/nginx/conf.d/.
[[ "$no_domain" -eq 1 ]] || require_root_or_sudo
load_env

project_dir="$REPO_ROOT/projects/$name"
template_dir="$REPO_ROOT/projects/_template"
conf_link="/etc/nginx/conf.d/${name}.conf"

[[ -d "$template_dir" ]] || die "template missing: $template_dir"
[[ ! -e "$project_dir" ]] || die "project '$name' already exists at $project_dir"
if [[ "$no_domain" -eq 0 ]]; then
  [[ ! -e "$conf_link" ]] || die "nginx config slot already taken: $conf_link"
fi

# Pick a host port.
if [[ -z "$fixed_port" ]]; then
  host_port=$(find_free_port 10000 19999)
  log "auto-assigned HOST_PORT=$host_port"
else
  [[ "$fixed_port" =~ ^[0-9]+$ ]] || die "--port must be numeric"
  host_port="$fixed_port"
  log "using HOST_PORT=$host_port (from --port)"
fi

log "copying template → projects/$name/"
cp -r "$template_dir" "$project_dir"

log "substituting placeholders"
# In --no-domain mode we still substitute PROJECT_NAME everywhere; DOMAIN gets
# a harmless string so the project's nginx.conf parses if you decide to wire
# it up later via issue-cert.sh + ln -s.
display_domain="${domain:-${name}.local.invalid}"
substitute_placeholders "$project_dir/docker-compose.yml" "$name" "$display_domain"
substitute_placeholders "$project_dir/nginx.conf"          "$name" "$display_domain"
substitute_placeholders "$project_dir/README.md"           "$name" "$display_domain" 2>/dev/null || true

# Initialize .env from .env.example with HOST_PORT pre-filled.
if [[ -f "$project_dir/.env.example" && ! -f "$project_dir/.env" ]]; then
  cp "$project_dir/.env.example" "$project_dir/.env"
fi
sed -i.bak "s|^HOST_PORT=.*|HOST_PORT=$host_port|" "$project_dir/.env"
rm -f "$project_dir/.env.bak"

# Pre-fill IMAGE/APP_PORT from CLI flags if provided.
if [[ -n "$arg_image" ]]; then
  if grep -q '^IMAGE=' "$project_dir/.env"; then
    sed -i.bak "s|^IMAGE=.*|IMAGE=$arg_image|" "$project_dir/.env" && rm -f "$project_dir/.env.bak"
  else
    echo "IMAGE=$arg_image" >> "$project_dir/.env"
  fi
fi
if [[ -n "$arg_app_port" ]]; then
  if grep -q '^APP_PORT=' "$project_dir/.env"; then
    sed -i.bak "s|^APP_PORT=.*|APP_PORT=$arg_app_port|" "$project_dir/.env" && rm -f "$project_dir/.env.bak"
  else
    echo "APP_PORT=$arg_app_port" >> "$project_dir/.env"
  fi
fi

# Determine if .env still has unfilled required vars and whether we need
# to interact with the operator. Sourcing here lets later steps see the
# values and we re-source again after any edit.
load_project_env() {
  IMAGE=""; APP_PORT=""
  # shellcheck disable=SC1090
  source "$project_dir/.env"
}
load_project_env

# Editor flow: open in $EDITOR if set; otherwise inline-prompt for the
# minimum (IMAGE + APP_PORT) so the script never waits silently.
if [[ -z "${IMAGE:-}" || -z "${APP_PORT:-}" ]]; then
  editor="${EDITOR:-${VISUAL:-}}"
  if [[ -n "$editor" ]]; then
    log "opening $project_dir/.env in $editor — fill in IMAGE, APP_PORT, and project secrets"
    "$editor" "$project_dir/.env"
  elif command -v vim >/dev/null 2>&1 || command -v nano >/dev/null 2>&1 || command -v vi >/dev/null 2>&1; then
    log "EDITOR not set — falling back to inline prompts (use --image / --app-port to skip these)"
    if [[ -z "${IMAGE:-}" ]]; then
      printf "IMAGE (e.g. node:20-alpine, ghcr.io/foo/bar:latest): "
      read -r reply
      [[ -n "$reply" ]] || die "IMAGE is required"
      sed -i.bak "s|^IMAGE=.*|IMAGE=$reply|" "$project_dir/.env"
      grep -q '^IMAGE=' "$project_dir/.env" || echo "IMAGE=$reply" >> "$project_dir/.env"
      rm -f "$project_dir/.env.bak"
    fi
    if [[ -z "${APP_PORT:-}" ]]; then
      printf "APP_PORT (port the app listens on inside the container, e.g. 3000): "
      read -r reply
      [[ -n "$reply" ]] || die "APP_PORT is required"
      sed -i.bak "s|^APP_PORT=.*|APP_PORT=$reply|" "$project_dir/.env"
      grep -q '^APP_PORT=' "$project_dir/.env" || echo "APP_PORT=$reply" >> "$project_dir/.env"
      rm -f "$project_dir/.env.bak"
    fi
    warn "any project-specific secrets still need a manual edit of $project_dir/.env"
  else
    die "no editor available and --image/--app-port not provided. Pass --image and --app-port, or set EDITOR=vi (or similar)."
  fi
  load_project_env
fi

# Verify required vars filled in.
[[ -n "${IMAGE:-}" ]]    || die "IMAGE not set in $project_dir/.env"
[[ -n "${APP_PORT:-}" ]] || die "APP_PORT not set in $project_dir/.env"

# Second-pass substitute IMAGE / APP_PORT / HOST_PORT.
sed -i.bak \
  -e "s|\${IMAGE}|${IMAGE}|g" \
  -e "s|\${APP_PORT}|${APP_PORT}|g" \
  -e "s|\${HOST_PORT}|${host_port}|g" \
  "$project_dir/docker-compose.yml" "$project_dir/nginx.conf"
rm -f "$project_dir/docker-compose.yml.bak" "$project_dir/nginx.conf.bak"

if [[ "$no_domain" -eq 1 ]]; then
  warn "--no-domain: skipping cert issuance, nginx symlink, and reload."
  warn "             projects/$name/nginx.conf left for reference; not active."
elif [[ "$skip_cert" -eq 0 ]]; then
  log "issuing Let's Encrypt cert"
  "$REPO_ROOT/scripts/issue-cert.sh" "$domain"
else
  warn "--skip-cert: nginx will fail to reload until $domain has a cert at /etc/letsencrypt/live/$domain/"
fi

if [[ "$no_domain" -eq 0 ]]; then
  log "linking nginx config to /etc/nginx/conf.d/"
  sudo ln -s "$project_dir/nginx.conf" "$conf_link"
fi

if [[ "$skip_up" -eq 1 ]]; then
  warn "--skip-up: project scaffolded but containers not started."
  warn "When ready: ./scripts/up-project.sh $name [profile...]"
else
  [[ "${#profiles[@]}" -eq 0 ]] && profiles=(--profile full)
  log "bringing project up (${profiles[*]})"
  project_compose "$name" "${profiles[@]}" up -d

  if [[ "$no_domain" -eq 0 ]]; then
    log "reloading nginx"
    "$REPO_ROOT/scripts/reload-nginx.sh"
  fi
fi

if [[ "$no_domain" -eq 1 ]]; then
  cat <<EOF

${C_BOLD}Project '$name' added (no-domain mode).${C_RESET}

  Location:        $project_dir
  Host port:       127.0.0.1:$host_port  (loopback only, NOT public)
  Profile:         ${profiles[*]:---profile full}
  Reach it:        curl -I http://127.0.0.1:$host_port    (from this server)
                   ssh -L $host_port:localhost:$host_port  user@server  (from your laptop)

  Manage:
    ./scripts/up-project.sh $name [profile]
    ./scripts/remove-project.sh $name
    docker compose -f projects/$name/docker-compose.yml ps
    docker compose -f projects/$name/docker-compose.yml logs -f

  To make it public later:
    sudo ln -sf "$project_dir/nginx.conf" $conf_link
    ./scripts/issue-cert.sh <your-domain>
    sed -i "s/${name}.local.invalid/<your-domain>/g" $project_dir/nginx.conf
    ./scripts/reload-nginx.sh

EOF
else
  cat <<EOF

${C_BOLD}Project '$name' added.${C_RESET}

  Location:    $project_dir
  Domain:      $domain
  Host port:   127.0.0.1:$host_port  (proxied by nginx)
  Nginx conf:  $conf_link → projects/$name/nginx.conf
  Profile:     ${profiles[*]:---profile full}
  Smoke test:  curl -I https://$domain

  Manage:
    ./scripts/up-project.sh $name [profile]
    ./scripts/remove-project.sh $name
    docker compose -f projects/$name/docker-compose.yml ps
    docker compose -f projects/$name/docker-compose.yml logs -f

EOF
fi
