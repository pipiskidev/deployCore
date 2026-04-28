# Shared bash helpers. Sourced by every script in scripts/. Don't run directly.

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

require_root_or_sudo() {
  if [[ $EUID -eq 0 ]]; then return 0; fi
  command -v sudo >/dev/null 2>&1 || die "this script needs root via sudo, but sudo is not installed"
  # Cache sudo credentials up front so the rest of the script doesn't pause repeatedly.
  sudo -v || die "sudo authentication failed"
}

# Detect OS family from /etc/os-release. Echoes one of: debian, rhel, unknown.
detect_os_family() {
  if [[ ! -r /etc/os-release ]]; then echo unknown; return; fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) echo debian ;;
    *rhel*|*centos*|*fedora*|*rocky*|*alma*) echo rhel ;;
    *) echo unknown ;;
  esac
}

# Install Docker Engine + Compose plugin (idempotent).
ensure_docker_installed() {
  if command -v docker >/dev/null 2>&1 \
     && docker info >/dev/null 2>&1 \
     && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  local os
  os=$(detect_os_family)
  if [[ "$os" == "unknown" ]]; then
    err "Docker missing and OS not recognized. Install manually:"
    err "  https://docs.docker.com/engine/install/"
    return 1
  fi

  warn "Docker (or docker compose v2) not available."
  warn "About to install via the official script: https://get.docker.com"
  printf "Continue? [y/N] "
  local reply; read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by operator"

  require_tool curl

  log "downloading and running get.docker.com"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh

  log "adding ${USER:-$(whoami)} to the 'docker' group"
  sudo usermod -aG docker "${USER:-$(whoami)}"

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

# Install nginx + certbot via the host's package manager. Idempotent.
ensure_nginx_certbot_installed() {
  local os; os=$(detect_os_family)

  case "$os" in
    debian)
      if ! command -v nginx >/dev/null 2>&1; then
        log "installing nginx (apt)"
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
      else
        ok "nginx already installed ($(nginx -v 2>&1 | sed 's/^[^:]*: //'))"
      fi
      if ! command -v certbot >/dev/null 2>&1; then
        log "installing certbot (apt)"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
      else
        ok "certbot already installed"
      fi
      ;;
    rhel)
      if ! command -v nginx >/dev/null 2>&1; then
        log "installing nginx (dnf/yum)"
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y -q nginx
        else
          sudo yum install -y -q nginx
        fi
      else
        ok "nginx already installed"
      fi
      if ! command -v certbot >/dev/null 2>&1; then
        log "installing certbot (dnf/yum)"
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y -q certbot
        else
          sudo yum install -y -q certbot
        fi
      else
        ok "certbot already installed"
      fi
      ;;
    *)
      die "unsupported OS family — install nginx + certbot manually, then rerun bootstrap.sh"
      ;;
  esac
}

# Load global .env into the current shell. No-op if missing.
load_env() {
  local env_file="$REPO_ROOT/.env"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

# Substitute ${PROJECT_NAME} and ${DOMAIN} in a file in place. We use sed
# instead of envsubst to avoid accidentally consuming nginx's $variable refs.
substitute_placeholders() {
  local file="$1" project_name="$2" domain="$3"
  [[ -f "$file" ]] || die "substitute target missing: $file"
  sed -i.bak \
    -e "s|\${PROJECT_NAME}|${project_name}|g" \
    -e "s|\${DOMAIN}|${domain}|g" \
    "$file"
  rm -f "$file.bak"
}

# Find a free TCP port in [start, end]. Loopback only — we don't care about
# external bindings. Echoes the port. Dies if none free.
find_free_port() {
  local start="${1:-10000}" end="${2:-19999}"
  local port
  for port in $(seq "$start" "$end"); do
    # ss is in iproute2 on every modern Linux. Check that nothing listens on
    # 127.0.0.1:port; ignore wildcard 0.0.0.0 (different namespace).
    if ! ss -lnt "src 127.0.0.1:$port" 2>/dev/null | grep -q LISTEN \
       && ! ss -lnt "src [::1]:$port" 2>/dev/null | grep -q LISTEN; then
      # Also exclude ports already declared in any project's .env (race-free
      # against a project that's been added but not yet started).
      if ! grep -hE "^HOST_PORT=$port\$" "$REPO_ROOT/projects"/*/.env 2>/dev/null | grep -q .; then
        echo "$port"
        return
      fi
    fi
  done
  die "no free port in $start-$end"
}

# Convenience: run docker compose with a specific project's compose file.
project_compose() {
  local name="$1"; shift
  docker compose -f "$REPO_ROOT/projects/$name/docker-compose.yml" "$@"
}
