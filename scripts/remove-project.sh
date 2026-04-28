#!/usr/bin/env bash
# Remove a project from the running platform.
#
# Usage: ./scripts/remove-project.sh <name>
#
# Stops containers, removes /etc/nginx/conf.d/<name>.conf, reloads nginx.
# Does NOT delete the project folder, .env, named volumes, or TLS certs.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

name="${1-}"
validate_project_name "$name"

require_docker
require_root_or_sudo

project_dir="$REPO_ROOT/projects/$name"
conf_link="/etc/nginx/conf.d/${name}.conf"

[[ -d "$project_dir" ]] || die "project '$name' not found at $project_dir"

log "stopping project '$name'"
project_compose "$name" --profile full down || warn "compose down reported a non-fatal error — continuing"

if [[ -L "$conf_link" ]]; then
  log "removing nginx config symlink: $conf_link"
  sudo rm -f "$conf_link"
elif [[ -e "$conf_link" ]]; then
  warn "$conf_link is not a symlink — leaving it alone, you must remove it manually"
else
  ok "no nginx config to remove"
fi

log "reloading nginx"
"$REPO_ROOT/scripts/reload-nginx.sh" || warn "nginx reload failed — likely no other server blocks. Safe to ignore if so."

cat <<EOF

${C_BOLD}Project '$name' stopped and unwired.${C_RESET}

  Project files:    $project_dir   (preserved — delete manually if you mean it)
  Named volumes:    not removed    (e.g. ${name}-mongo-data)
                    list:    docker volume ls --filter name=${name}
                    delete:  docker volume rm ${name}-<...>
  TLS certificate:  not revoked    sudo certbot revoke --cert-name <domain>

EOF
