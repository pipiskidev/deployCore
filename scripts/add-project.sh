#!/usr/bin/env bash
# Add a new project to a running deployCore platform.
#
# Usage: ./scripts/add-project.sh <name> <domain> [--profile <p>] [--skip-cert] [--skip-up]
#
# Flags:
#   --profile <p>   Compose profile to bring up (default: full).
#                   Examples: backend, web, app — see projects/<name>/docker-compose.yml.
#                   Can be passed multiple times: --profile backend --profile worker.
#   --skip-cert     Don't issue a Let's Encrypt cert (DNS not ready yet, manual later).
#   --skip-up       Don't bring up containers — only scaffold files and (optionally) cert.
#                   Useful if you want to edit the project's compose first.
#
# Steps:
#   1. Validate name and domain.
#   2. Copy projects/_template/ to projects/<name>/.
#   3. Substitute ${PROJECT_NAME} and ${DOMAIN} placeholders.
#   4. Open projects/<name>/.env in $EDITOR (or print path if unset).
#   5. Issue a Let's Encrypt cert for <domain> (unless --skip-cert).
#   6. Symlink projects/<name>/nginx.conf into core/nginx/conf.d/<name>.conf.
#   7. docker compose up -d --profile <p> (unless --skip-up).
#   8. Reload nginx (unless --skip-up).
#
# Idempotent: if projects/<name>/ exists, exits with a clear error.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

skip_cert=0
skip_up=0
profiles=()
positional=()
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --skip-cert) skip_cert=1 ;;
    --skip-up)   skip_up=1 ;;
    --profile)
      i=$((i+1))
      [[ $i -le $# ]] || die "--profile requires a value"
      profiles+=("--profile" "${!i}")
      ;;
    --profile=*)
      profiles+=("--profile" "${arg#*=}")
      ;;
    --help|-h)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown flag: $arg (see --help)" ;;
    *) positional+=("$arg") ;;
  esac
  i=$((i+1))
done

[[ "${#positional[@]}" -eq 2 ]] || die "usage: $(basename "$0") <name> <domain> [--profile <p>] [--skip-cert] [--skip-up]"
name="${positional[0]}"
domain="${positional[1]}"

# Default profile if none provided.
[[ "${#profiles[@]}" -eq 0 ]] && profiles=(--profile full)

validate_project_name "$name"
validate_domain "$domain"

require_docker
load_env

project_dir="$REPO_ROOT/projects/$name"
template_dir="$REPO_ROOT/projects/_template"
conf_link="$REPO_ROOT/core/nginx/conf.d/${name}.conf"

[[ -d "$template_dir" ]] || die "template missing: $template_dir"
[[ ! -e "$project_dir" ]] || die "project '$name' already exists at $project_dir"
[[ ! -e "$conf_link" ]]  || die "nginx config slot already taken: $conf_link"

log "copying template → projects/$name/"
cp -r "$template_dir" "$project_dir"

log "substituting placeholders"
substitute_placeholders "$project_dir/docker-compose.yml" "$name" "$domain"
substitute_placeholders "$project_dir/nginx.conf"          "$name" "$domain"
substitute_placeholders "$project_dir/README.md"           "$name" "$domain" 2>/dev/null || true

# Initialize .env from the template's .env.example so add-project leaves a
# real .env file (gitignored) for the operator to edit.
if [[ -f "$project_dir/.env.example" && ! -f "$project_dir/.env" ]]; then
  cp "$project_dir/.env.example" "$project_dir/.env"
fi

editor="${EDITOR:-${VISUAL:-}}"
if [[ -n "$editor" ]]; then
  log "opening $project_dir/.env in $editor — fill in IMAGE, APP_PORT, and project secrets"
  "$editor" "$project_dir/.env"
else
  warn "EDITOR not set — edit $project_dir/.env manually now, then press ENTER to continue"
  read -r
fi

# Verify the operator filled in the required vars.
# shellcheck disable=SC1090
source "$project_dir/.env"
[[ -n "${IMAGE:-}" ]]    || die "IMAGE not set in $project_dir/.env"
[[ -n "${APP_PORT:-}" ]] || die "APP_PORT not set in $project_dir/.env"

# Now do the second-pass substitution of IMAGE/APP_PORT. We do this AFTER the
# operator edit so they only have to enter values once.
sed -i.bak \
  -e "s|\${IMAGE}|${IMAGE}|g" \
  -e "s|\${APP_PORT}|${APP_PORT}|g" \
  "$project_dir/docker-compose.yml" "$project_dir/nginx.conf"
rm -f "$project_dir/docker-compose.yml.bak" "$project_dir/nginx.conf.bak"

if [[ "$skip_cert" -eq 0 ]]; then
  log "issuing Let's Encrypt cert"
  "$REPO_ROOT/scripts/issue-cert.sh" "$domain"
else
  warn "--skip-cert: nginx will fail to reload until $domain has a cert at /etc/letsencrypt/live/$domain/"
fi

log "symlinking nginx config"
ln -s "../../projects/$name/nginx.conf" "$conf_link"

if [[ "$skip_up" -eq 1 ]]; then
  warn "--skip-up: project scaffolded but containers not started."
  warn "When ready: ./scripts/up-project.sh $name [profile...]"
else
  log "bringing project up (${profiles[*]})"
  project_compose "$name" "${profiles[@]}" up -d

  log "reloading nginx"
  "$REPO_ROOT/scripts/reload-nginx.sh"
fi

cat <<EOF

${C_BOLD}Project '$name' added.${C_RESET}

  Location:    $project_dir
  Domain:      $domain
  Nginx conf:  $conf_link → projects/$name/nginx.conf
  Profile:     ${profiles[*]}
  Smoke test:  curl -I https://$domain

  Manage:
    ./scripts/up-project.sh $name [profile]      # bring up (or change which services run)
    ./scripts/remove-project.sh $name            # take down
    docker compose -f projects/$name/docker-compose.yml ps
    docker compose -f projects/$name/docker-compose.yml logs -f

EOF
