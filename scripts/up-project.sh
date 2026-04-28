#!/usr/bin/env bash
# Bring an existing project up with chosen profile(s).
#
# Usage:
#   ./scripts/up-project.sh <name>                # full profile
#   ./scripts/up-project.sh <name> backend        # only backend profile
#   ./scripts/up-project.sh <name> backend web    # union of profiles
#   ./scripts/up-project.sh <name> --down         # take all services down
#   ./scripts/up-project.sh <name> --no-down      # skip the implicit down
#                                                 (faster, but leftover services
#                                                  from previous profile may persist)

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

require_docker

down_only=0
no_down=0
positional=()
profiles=()
for arg in "$@"; do
  case "$arg" in
    --down)    down_only=1 ;;
    --no-down) no_down=1 ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown flag: $arg" ;;
    *)
      if [[ "${#positional[@]}" -eq 0 ]]; then
        positional+=("$arg")
      else
        profiles+=("--profile" "$arg")
      fi
      ;;
  esac
done

[[ "${#positional[@]}" -eq 1 ]] || die "usage: $(basename "$0") <name> [profile...] [--down|--no-down]"
name="${positional[0]}"
validate_project_name "$name"

[[ -d "$REPO_ROOT/projects/$name" ]] || die "project '$name' not found"

if [[ "$down_only" -eq 1 ]]; then
  log "taking project '$name' down"
  project_compose "$name" --profile full down
  ok "down"
  exit 0
fi

[[ "${#profiles[@]}" -eq 0 ]] && profiles=(--profile full)

if [[ "$no_down" -eq 0 ]]; then
  log "stopping any previously-running services for '$name'"
  project_compose "$name" --profile full down >/dev/null 2>&1 || true
fi

log "bringing project '$name' up (${profiles[*]})"
project_compose "$name" "${profiles[@]}" up -d
ok "project '$name' is up"
