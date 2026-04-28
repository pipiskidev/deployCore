#!/usr/bin/env bash
# Bring up the optional mail server (shared/mail/).
#
# Uses --project-name core so the mail compose can attach to the
# `core_letsencrypt` named volume created by core/docker-compose.yml.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_docker

mail_dir="$REPO_ROOT/shared/mail"
[[ -f "$mail_dir/docker-compose.yml" ]] || die "shared/mail/ missing"

if [[ ! -f "$mail_dir/mailserver.env" ]]; then
  cp "$mail_dir/mailserver.env.example" "$mail_dir/mailserver.env"
  warn "created shared/mail/mailserver.env from example."
  warn "Edit it (MAIL_DOMAIN, LETSENCRYPT_DOMAIN, LETSENCRYPT_EMAIL) and rerun."
  exit 1
fi

log "starting mail server"
docker compose --project-name core -f "$mail_dir/docker-compose.yml" up -d
ok "mail is up"

cat <<EOF

  Add a mailbox:    docker exec -ti mailserver setup email add user@example.com
  Generate DKIM:    docker exec -ti mailserver setup config dkim
  Logs:             docker compose --project-name core -f shared/mail/docker-compose.yml logs -f

EOF
