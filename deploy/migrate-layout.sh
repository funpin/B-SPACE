#!/usr/bin/env bash
# ============================================================
# Backspace — move an existing install onto the deploy/ layout
# ============================================================
# The compose files, the Caddyfile and the operator scripts used to sit in the
# repository root. They now live in deploy/, while the install's own state
# (.env, data/, livekit.yaml) stays in the root. An install made before the
# move needs three things adjusted once, and this script does exactly those:
#
#   1. COMPOSE_FILE in .env, so `docker compose` run from the root finds
#      deploy/docker-compose.yml (and the proxy override, where it was in use).
#   2. COMPOSE_PROJECT_NAME in .env, when the running containers belong to a
#      project that is not called `backspace`. The compose file now pins that
#      name; without this line an install cloned into another directory would
#      start a second project and lose sight of its caddy-data volume.
#   3. The caddy container, recreated so it mounts deploy/Caddyfile. Its old
#      bind mount points at a file that no longer exists, which keeps working
#      until the next restart and then does not come back.
#
# Usage:
#   ./deploy/migrate-layout.sh         Migrate, with one confirmation prompt.
#   ./deploy/migrate-layout.sh --yes   Migrate without prompting.
#
# Safe to run again: an install already on the new layout is reported as such
# and left alone. ./deploy/update.sh runs it for you when it is needed.
# ============================================================

set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}  OK ${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC} $*" >&2; }

BASE_FILE="deploy/docker-compose.yml"
PROXY_FILE="deploy/docker-compose.proxy.yml"
PINNED_PROJECT="backspace"
APP_CONTAINER="backspace"
CADDY_CONTAINER="caddy"

ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true ;;
    --help|-h)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f .env ]]; then
  info "No .env in $(pwd), so there is no install here to migrate."
  info "A new install starts with ./deploy/install.sh."
  exit 0
fi

# Reads one value without sourcing the file, so a shell metacharacter in a value
# cannot execute anything. Same shape as install.sh and update.sh.
env_val() {
  grep "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Replaces KEY's line, or appends it. Rewritten through a temp file rather than
# with sed -i: GNU and BSD sed disagree about -i.
set_env() {
  local key="$1" value="$2" tmp line found=false
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      if [[ "$found" == false ]]; then
        printf '%s\n' "${key}=${value}"
        found=true
      fi
    else
      printf '%s\n' "$line"
    fi
  done < .env > "$tmp"
  if [[ "$found" == false ]]; then
    printf '\n%s\n' "${key}=${value}" >> "$tmp"
  fi
  # cat rather than mv: keeps the owner and mode of the existing .env.
  cat "$tmp" > .env
  rm -f "$tmp"
}

# ── What COMPOSE_FILE should be ─────────────────────────────

current_files="$(env_val COMPOSE_FILE)"
extra_files=()
wanted_files=""

if [[ -z "$current_files" ]]; then
  wanted_files="$BASE_FILE"
  # With no COMPOSE_FILE, compose used to pick this up on its own from beside
  # the root docker-compose.yml. It has to be named now.
  if [[ -f docker-compose.override.yml ]]; then
    wanted_files="${wanted_files}:docker-compose.override.yml"
    extra_files+=("docker-compose.override.yml")
  fi
else
  IFS=':' read -r -a entries <<< "$current_files"
  for entry in "${entries[@]}"; do
    case "$entry" in
      docker-compose.yml|./docker-compose.yml|"$BASE_FILE")
        mapped="$BASE_FILE" ;;
      docker-compose.proxy.yml|./docker-compose.proxy.yml|"$PROXY_FILE")
        mapped="$PROXY_FILE" ;;
      *)
        mapped="$entry"
        extra_files+=("$entry") ;;
    esac
    wanted_files="${wanted_files:+${wanted_files}:}${mapped}"
  done
fi

# ── What COMPOSE_PROJECT_NAME should be ─────────────────────

DOCKER=""
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    DOCKER="docker"
  elif sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  fi
fi

container_project() {
  [[ -n "$DOCKER" ]] || return 0
  $DOCKER inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$1" 2>/dev/null || true
}

current_project="$(env_val COMPOSE_PROJECT_NAME)"
running_project="$(container_project "$APP_CONTAINER")"
wanted_project="$current_project"
if [[ -z "$current_project" && -n "$running_project" && "$running_project" != "$PINNED_PROJECT" ]]; then
  wanted_project="$running_project"
fi

# ── Does the caddy container still mount the old Caddyfile? ─

caddy_mount=""
caddy_project=""
if [[ -n "$DOCKER" ]]; then
  caddy_mount="$($DOCKER inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' "$CADDY_CONTAINER" 2>/dev/null || true)"
  caddy_project="$(container_project "$CADDY_CONTAINER")"
fi
effective_project="${wanted_project:-$PINNED_PROJECT}"

# Naming a service on the command line activates its profile. In proxy and
# tunnel mode caddy sits in a profile that is never meant to start, so a caddy
# container left over from an earlier all-in-one setup must not be revived.
# Asked of the files this install is about to use, which .env does not name yet.
caddy_enabled() {
  local args=(--env-file .env) entry services
  local -a files
  IFS=':' read -r -a files <<< "$wanted_files"
  for entry in "${files[@]}"; do args+=(-f "$entry"); done
  services="$($DOCKER compose "${args[@]}" config --services 2>/dev/null || true)"
  [[ $'\n'"$services"$'\n' == *$'\n'"caddy"$'\n'* ]]
}

recreate_caddy=false
if [[ -n "$caddy_mount" && "$caddy_mount" != "$(pwd -P)/deploy/Caddyfile" \
      && "$caddy_project" == "$effective_project" ]] && caddy_enabled; then
  recreate_caddy=true
fi

# A host deployed by rsync keeps its own Caddyfile out of the sync, so after the
# move it has the file in the root and none in deploy/.
move_caddyfile=false
if [[ -f Caddyfile && ! -e deploy/Caddyfile ]]; then
  move_caddyfile=true
fi

# ── Anything to do? ─────────────────────────────────────────

if [[ -z "$DOCKER" ]]; then
  warn "Docker is not reachable from this shell, so the project name and the"
  warn "caddy mount cannot be checked. Run this again as a user who can reach it."
fi

if [[ "$wanted_files" == "$current_files" && "$wanted_project" == "$current_project" \
      && "$recreate_caddy" == false && "$move_caddyfile" == false ]]; then
  success "This install already uses the deploy/ layout."
  exit 0
fi

echo ""
echo "This install was set up before the server files moved into deploy/."
echo "To bring it onto the new layout, this will:"
[[ "$wanted_files" != "$current_files" ]]     && echo "  - set COMPOSE_FILE=${wanted_files} in .env"
[[ "$wanted_project" != "$current_project" ]] && echo "  - set COMPOSE_PROJECT_NAME=${wanted_project} in .env (keeps the existing volumes)"
[[ "$move_caddyfile" == true ]]               && echo "  - move ./Caddyfile to deploy/Caddyfile"
[[ "$recreate_caddy" == true ]]               && echo "  - recreate the caddy container so it mounts deploy/Caddyfile (HTTPS drops for a few seconds)"
echo "Nothing in data/ is touched."

if [[ "$ASSUME_YES" != true ]]; then
  if [[ ! -t 0 ]]; then
    error "Not running interactively and --yes was not given."
    error "Re-run as: ./deploy/migrate-layout.sh --yes"
    exit 1
  fi
  read -rp "Continue? [y/N] " yn
  [[ "${yn,,}" == "y" ]] || { echo "Aborted. Nothing was changed."; exit 1; }
fi

# ── Apply ───────────────────────────────────────────────────

if [[ "$move_caddyfile" == true ]]; then
  mv Caddyfile deploy/Caddyfile
  success "Moved ./Caddyfile to deploy/Caddyfile"
fi

if [[ "$wanted_files" != "$current_files" ]]; then
  set_env COMPOSE_FILE "$wanted_files"
  success "COMPOSE_FILE=${wanted_files}"
fi

if [[ "$wanted_project" != "$current_project" ]]; then
  set_env COMPOSE_PROJECT_NAME "$wanted_project"
  success "COMPOSE_PROJECT_NAME=${wanted_project}"
fi

if [[ "$recreate_caddy" == true ]]; then
  # --no-deps: caddy depends on backspace being healthy, and this must not
  # restart or wait on the application container.
  if $DOCKER compose up -d --no-deps caddy; then
    success "caddy now mounts deploy/Caddyfile"
  else
    error "Could not recreate the caddy container."
    error "Run it by hand from $(pwd): docker compose up -d --no-deps caddy"
    exit 1
  fi
fi

# ── What this script cannot settle on its own ───────────────

if [[ ${#extra_files[@]} -gt 0 ]]; then
  warn "COMPOSE_FILE also names: ${extra_files[*]}"
  warn "Relative paths in every compose file now resolve against deploy/, the"
  warn "directory of the first file. Check any ./ paths in those overrides."
fi

if [[ -f Caddyfile && -f deploy/Caddyfile ]] && ! cmp -s Caddyfile deploy/Caddyfile; then
  warn "./Caddyfile differs from deploy/Caddyfile and is no longer read."
  warn "Carry your changes over to deploy/Caddyfile, then delete ./Caddyfile."
fi

echo ""
success "Layout migrated. Operator scripts are now ./deploy/update.sh, ./deploy/backup.sh and ./deploy/restore.sh."
