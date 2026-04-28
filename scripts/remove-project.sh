#!/usr/bin/env bash
# Remove a project from the running platform.
#
# Usage: ./scripts/remove-project.sh <name>
#
# Stops the project's containers, removes its nginx-conf symlink, reloads
# nginx. Does NOT delete the project folder, its .env, named volumes, or
# any TLS certificates — those require explicit operator action.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

name="${1-}"
validate_project_name "$name"

require_docker

project_dir="$REPO_ROOT/projects/$name"
conf_link="$REPO_ROOT/core/nginx/conf.d/${name}.conf"

[[ -d "$project_dir" ]] || die "project '$name' not found at $project_dir"

log "stopping project '$name'"
project_compose "$name" --profile full down || warn "compose down reported a non-fatal error — continuing"

if [[ -L "$conf_link" ]]; then
  log "removing nginx config symlink: $conf_link"
  rm -f "$conf_link"
elif [[ -e "$conf_link" ]]; then
  warn "$conf_link is not a symlink — leaving it alone, you must remove it manually"
else
  ok "no nginx config to remove"
fi

log "reloading nginx"
"$REPO_ROOT/scripts/reload-nginx.sh" || warn "nginx reload failed — likely no other projects are configured. Safe to ignore."

cat <<EOF

${C_BOLD}Project '$name' stopped and unwired.${C_RESET}

  Project files:        $project_dir   (preserved — delete manually if you mean it)
  Named volumes:        not removed    (e.g. ${name}-mongo-data)
                        — list:    docker volume ls --filter name=${name}
                        — delete:  docker volume rm ${name}-<...>
  TLS certificate:      not revoked    — see core/docker-compose.yml for revocation
                        command if needed.

EOF
