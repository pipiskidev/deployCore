#!/usr/bin/env bash
# Preflight inventory — print what's installed/configured on this host.
# Read-only: does NOT install, modify, or start anything.
#
# Run before bootstrap.sh to see what's already in place, or after to verify
# the deployed state.
#
# Usage:
#   ./scripts/preflight.sh             # print human-readable inventory
#   ./scripts/preflight.sh --json      # machine-readable (for CI / monitoring)

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

mode=text
for arg in "$@"; do
  case "$arg" in
    --json) mode=json ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown flag: $arg" ;;
  esac
done

if [[ "$mode" == "json" ]]; then
  # Build a small JSON object. No jq dependency — just stitch strings.
  net_web="missing"
  if is_docker_ready && docker network inspect web >/dev/null 2>&1; then
    net_web="exists"
  fi

  projects=()
  if [[ -d "$REPO_ROOT/projects" ]]; then
    for d in "$REPO_ROOT/projects"/*/; do
      name="$(basename "$d")"
      [[ "$name" != "_template" ]] || continue
      projects+=("\"$name\"")
    done
  fi
  projects_json="[$(IFS=,; echo "${projects[*]:-}")]"

  cat <<EOF
{
  "os":        "$(detect_os_family)",
  "docker":    "$(status_docker)",
  "nginx":     "$(status_nginx)",
  "certbot":   "$(status_certbot)",
  "portainer": "$(status_portainer)",
  "mail":      "$(status_mailserver)",
  "web_network": "$net_web",
  "projects":  $projects_json
}
EOF
  exit 0
fi

print_inventory

# Per-project state.
if [[ -d "$REPO_ROOT/projects" ]]; then
  for d in "$REPO_ROOT/projects"/*/; do
    name="$(basename "$d")"
    [[ "$name" != "_template" ]] || continue

    has_env="no"
    [[ -f "$d/.env" ]] && has_env="yes"

    has_conf="no"
    if [[ -L "/etc/nginx/conf.d/${name}.conf" ]] \
       || [[ -e "/etc/nginx/conf.d/${name}.conf" ]]; then
      has_conf="yes"
    fi

    running="no"
    if is_docker_ready && docker compose -f "$d/docker-compose.yml" ps --status running --services 2>/dev/null | grep -q .; then
      running="yes ($(docker compose -f "$d/docker-compose.yml" ps --status running --services 2>/dev/null | tr '\n' ',' | sed 's/,$//'))"
    fi

    printf "${C_BOLD}project:%s${C_RESET}  .env=%s  nginx=%s  running=%s\n" \
      "$name" "$has_env" "$has_conf" "$running"
  done
fi

# TLS certs (parse the live/ directory).
if [[ -d /etc/letsencrypt/live ]]; then
  printf "\n${C_BOLD}certs (Let's Encrypt):${C_RESET}\n"
  for cert_dir in /etc/letsencrypt/live/*/; do
    [[ -d "$cert_dir" ]] || continue
    domain=$(basename "$cert_dir")
    [[ "$domain" == "README" ]] && continue
    if [[ -f "$cert_dir/cert.pem" ]] && command -v openssl >/dev/null 2>&1; then
      not_after=$(sudo openssl x509 -enddate -noout -in "$cert_dir/cert.pem" 2>/dev/null | sed 's/^notAfter=//')
      printf "  %s  expires: %s\n" "$domain" "$not_after"
    else
      printf "  %s  (cert.pem unreadable — try with sudo)\n" "$domain"
    fi
  done
fi

printf "\n"
