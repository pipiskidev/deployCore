#!/usr/bin/env bash
# Validate the host nginx config, then reload.
# nginx keeps serving the previous config if validation fails.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_root_or_sudo

log "running nginx -t"
if ! sudo nginx -t; then
  die "nginx config invalid — not reloading. Fix the offending /etc/nginx/conf.d/*.conf and rerun."
fi

log "reloading nginx"
sudo systemctl reload nginx
ok "nginx reloaded"
