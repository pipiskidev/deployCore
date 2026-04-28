# Shared bash helpers. Sourced by every script in scripts/.
# Don't run directly.

set -euo pipefail

# Resolve repo root regardless of where the calling script lives or where it's invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors. Disabled when not on a TTY (e.g. piped to tee).
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
fi

log()    { printf "%s==>%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()     { printf "%s ✓%s  %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()   { printf "%s !%s  %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()    { printf "%s ✗%s  %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
die()    { err "$*"; exit 1; }

# Validate "name" argument: only [a-z0-9-], 2-40 chars, no leading/trailing dash.
validate_project_name() {
  local name="${1-}"
  [[ -n "$name" ]] || die "project name is required"
  [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] \
    || die "invalid project name '$name': must be lowercase [a-z0-9-], 2–40 chars, no leading/trailing dash"
}

# Validate domain. Loose: at least one dot, only [a-zA-Z0-9.-], no consecutive dots.
validate_domain() {
  local d="${1-}"
  [[ -n "$d" ]] || die "domain is required"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] \
    || die "invalid domain '$d'"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

require_docker() {
  require_tool docker
  docker info >/dev/null 2>&1 \
    || die "docker daemon not reachable. Is the user in the 'docker' group? sudo usermod -aG docker \$USER && relogin."
  docker compose version >/dev/null 2>&1 \
    || die "'docker compose' v2 plugin missing. Install docker-compose-plugin (apt: docker-compose-plugin)."
}

# Detect OS family from /etc/os-release. Echoes one of: debian, rhel, unknown.
detect_os_family() {
  if [[ ! -r /etc/os-release ]]; then
    echo unknown
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) echo debian ;;
    *rhel*|*centos*|*fedora*|*rocky*|*alma*) echo rhel ;;
    *) echo unknown ;;
  esac
}

# Install Docker Engine + Compose plugin via the official get.docker.com
# script. Idempotent — safe to call when docker is already installed.
# Returns 0 if docker is available afterwards (either pre-existing or freshly
# installed), non-zero if installation failed.
ensure_docker_installed() {
  if command -v docker >/dev/null 2>&1 \
     && docker info >/dev/null 2>&1 \
     && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  local os
  os=$(detect_os_family)
  if [[ "$os" == "unknown" ]]; then
    err "Docker missing and OS not recognized (looked at /etc/os-release)."
    err "Install Docker manually, then rerun bootstrap.sh:"
    err "  https://docs.docker.com/engine/install/"
    return 1
  fi

  warn "Docker (or docker compose v2) not available."
  warn "About to install via the official script: https://get.docker.com"
  warn "This requires sudo and will:"
  warn "  - install docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin"
  warn "  - add user '${USER:-$(whoami)}' to the 'docker' group (re-login required after)"
  printf "Continue? [y/N] "
  local reply
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by operator"

  require_tool curl

  log "downloading and running get.docker.com"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh

  log "adding ${USER:-$(whoami)} to the 'docker' group"
  sudo usermod -aG docker "${USER:-$(whoami)}"

  # Try to enable + start the daemon (no-op on systems where systemd isn't init).
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker || true
  fi

  if docker info >/dev/null 2>&1; then
    ok "Docker installed and reachable"
    return 0
  fi

  warn "Docker installed, but the current shell can't reach the daemon yet."
  warn "Either log out and back in, or run: 'newgrp docker' then rerun bootstrap.sh."
  return 1
}

# Load global .env into the current shell. No-op if missing (some scripts work without it).
load_env() {
  local env_file="$REPO_ROOT/.env"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

# Substitute ${PROJECT_NAME}, ${DOMAIN}, ${IMAGE}, ${APP_PORT} placeholders in
# a file in place. We use a simple sed loop instead of envsubst to avoid
# accidentally consuming nginx's own $variable references.
substitute_placeholders() {
  local file="$1" project_name="$2" domain="$3"
  [[ -f "$file" ]] || die "substitute target missing: $file"
  sed -i.bak \
    -e "s|\${PROJECT_NAME}|${project_name}|g" \
    -e "s|\${DOMAIN}|${domain}|g" \
    "$file"
  rm -f "$file.bak"
}

# Convenience: run docker compose with the core compose file.
core_compose() {
  docker compose -f "$REPO_ROOT/core/docker-compose.yml" "$@"
}

# Convenience: run docker compose with a specific project's compose file.
project_compose() {
  local name="$1"; shift
  docker compose -f "$REPO_ROOT/projects/$name/docker-compose.yml" "$@"
}
