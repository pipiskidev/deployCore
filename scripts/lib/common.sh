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

# ── Status helpers ───────────────────────────────────────────────────────
# Each `status_*` function echoes a short human-readable string describing
# the current state of one component. `is_*` functions return 0/1 as exit code
# for use in conditionals. None of these functions install or modify anything.

status_docker() {
  if ! command -v docker >/dev/null 2>&1; then echo "not installed"; return; fi
  local v; v=$(docker --version 2>/dev/null | sed -n 's/Docker version \([^,]*\).*/\1/p')
  if ! docker info >/dev/null 2>&1; then echo "installed (${v:-unknown}) but daemon unreachable"; return; fi
  if ! docker compose version >/dev/null 2>&1; then echo "installed (${v:-unknown}), compose plugin MISSING"; return; fi
  local cv; cv=$(docker compose version --short 2>/dev/null)
  echo "installed (engine ${v:-?}, compose ${cv:-?})"
}
is_docker_ready() {
  command -v docker >/dev/null 2>&1 \
    && docker info >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1
}

status_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then echo "not installed"; return; fi
  local v; v=$(nginx -v 2>&1 | sed -n 's/^.*nginx\/\([^ ]*\).*/\1/p')
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    echo "installed (${v:-?}), active"
  else
    echo "installed (${v:-?}), not active"
  fi
}
is_nginx_active() {
  command -v nginx >/dev/null 2>&1 \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl is-active --quiet nginx
}

status_certbot() {
  if ! command -v certbot >/dev/null 2>&1; then echo "not installed"; return; fi
  local v; v=$(certbot --version 2>&1 | sed -n 's/^certbot \([0-9.]*\).*/\1/p')
  local timer="off"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet certbot.timer; then
    timer="active"
  fi
  echo "installed (${v:-?}), timer ${timer}"
}
is_certbot_timer_active() {
  command -v systemctl >/dev/null 2>&1 \
    && systemctl is-active --quiet certbot.timer
}

status_portainer() {
  if ! is_docker_ready; then echo "(needs docker)"; return; fi
  if docker ps --filter "name=^core-portainer$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
    echo "running ($(docker ps --filter "name=^core-portainer$" --format '{{.Status}}'))"
  elif docker ps -a --filter "name=^core-portainer$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
    echo "stopped ($(docker ps -a --filter "name=^core-portainer$" --format '{{.Status}}'))"
  else
    echo "not deployed"
  fi
}

status_mailserver() {
  if ! is_docker_ready; then echo "(needs docker)"; return; fi
  if docker ps --filter "name=^mailserver$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
    echo "running"
  elif docker ps -a --filter "name=^mailserver$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
    echo "stopped"
  else
    echo "not deployed"
  fi
}

# Print a plain inventory of platform components. Used by preflight.sh and
# by bootstrap.sh at the start of a run.
print_inventory() {
  printf "%s%s deployCore preflight%s\n" "$C_BOLD" "$C_BLUE" "$C_RESET"
  printf "  os:        %s (%s)\n" "$(detect_os_family)" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf "  docker:    %s\n" "$(status_docker)"
  printf "  nginx:     %s\n" "$(status_nginx)"
  printf "  certbot:   %s\n" "$(status_certbot)"
  printf "  portainer: %s\n" "$(status_portainer)"
  printf "  mail:      %s\n" "$(status_mailserver)"
  if [[ -d "$REPO_ROOT/projects" ]]; then
    local count=0 names=()
    for d in "$REPO_ROOT/projects"/*/; do
      [[ -d "$d" && "$(basename "$d")" != "_template" ]] || continue
      names+=("$(basename "$d")")
      count=$((count+1))
    done
    if [[ $count -gt 0 ]]; then
      printf "  projects:  %s (%d)\n" "${names[*]}" "$count"
    else
      printf "  projects:  (none)\n"
    fi
  fi
  printf "  network:   web "
  if is_docker_ready && docker network inspect web >/dev/null 2>&1; then
    printf "(exists)\n"
  else
    printf "(missing)\n"
  fi
  printf "\n"
}

# Install Docker Engine + Compose plugin (idempotent).
ensure_docker_installed() {
  if is_docker_ready; then
    ok "docker: $(status_docker) — skipping install"
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

# Install nginx + certbot via the host's package manager. Idempotent — skips
# anything already present without touching the package manager at all.
ensure_nginx_certbot_installed() {
  local os; os=$(detect_os_family)
  local need_nginx=0 need_certbot=0
  command -v nginx   >/dev/null 2>&1 || need_nginx=1
  command -v certbot >/dev/null 2>&1 || need_certbot=1

  if [[ $need_nginx -eq 0 && $need_certbot -eq 0 ]]; then
    ok "nginx: $(status_nginx) — skipping install"
    ok "certbot: $(status_certbot) — skipping install"
    return 0
  fi

  case "$os" in
    debian)
      if [[ $need_nginx -eq 1 || $need_certbot -eq 1 ]]; then
        log "running apt-get update"
        sudo apt-get update -qq
      fi
      if [[ $need_nginx -eq 1 ]]; then
        log "installing nginx (apt)"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
      else
        ok "nginx: $(status_nginx) — skipping install"
      fi
      if [[ $need_certbot -eq 1 ]]; then
        log "installing certbot (apt)"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
      else
        ok "certbot: $(status_certbot) — skipping install"
      fi
      ;;
    rhel)
      if [[ $need_nginx -eq 1 ]]; then
        log "installing nginx (dnf/yum)"
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y -q nginx
        else
          sudo yum install -y -q nginx
        fi
      else
        ok "nginx: $(status_nginx) — skipping install"
      fi
      if [[ $need_certbot -eq 1 ]]; then
        log "installing certbot (dnf/yum)"
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y -q certbot
        else
          sudo yum install -y -q certbot
        fi
      else
        ok "certbot: $(status_certbot) — skipping install"
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
