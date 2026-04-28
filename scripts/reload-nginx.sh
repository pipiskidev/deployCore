#!/usr/bin/env bash
# Validate the nginx config inside the core-nginx container, then reload.
# Exits non-zero if the validation fails — nginx keeps serving the previous
# config in that case.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_docker

log "running nginx -t"
if ! core_compose exec -T nginx nginx -t; then
  die "nginx config invalid — not reloading. Fix the offending conf.d/*.conf and rerun."
fi

log "reloading nginx"
core_compose exec -T nginx nginx -s reload
ok "nginx reloaded"
