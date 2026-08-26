#!/usr/bin/env bash
#
# Backup the homelab stack.
#
# Backs up:
#   - config state: .env, secrets/, authelia/users_database.yml, traefik/acme/
#   - named volumes: authelia_data, redis_data, grafana_data
#     (+ prometheus_data with --with-prometheus; it is large and re-collectable)
#
# Modes:
#   - If restic is installed AND RESTIC_REPOSITORY is set (in .env or the
#     environment), the staged backup is pushed to the restic repo and old
#     snapshots are pruned (7 daily / 4 weekly / 6 monthly).
#   - Otherwise backups are kept locally in ${BACKUP_DIR} (default ./backups)
#     with simple rotation, keeping the newest ${BACKUP_KEEP} (default 7).
#
# Flags:
#   --stop              stop the stack during backup for guaranteed-consistent
#                       sqlite/tsdb copies (restarted automatically, even on error)
#   --with-prometheus   include the Prometheus TSDB volume
#
# Cron example (03:30 daily):
#   30 3 * * * /path/to/repo/scripts/backup.sh --stop >> /var/log/homelab-backup.log 2>&1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[-]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

# shellcheck disable=SC1091
[[ -f .env ]] && source .env

BACKUP_DIR="${BACKUP_DIR:-$REPO_ROOT/backups}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-homelab}"

STOP=false
WITH_PROM=false
for arg in "$@"; do
  case "$arg" in
    --stop) STOP=true ;;
    --with-prometheus) WITH_PROM=true ;;
    *) err "unknown flag: $arg"; exit 1 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { err "docker is not installed"; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$BACKUP_DIR/$STAMP"
mkdir -p "$STAGE"
chmod 700 "$BACKUP_DIR"

if $STOP; then
  info "Stopping the stack for a consistent backup"
  docker compose stop
  trap 'info "Restarting the stack"; docker compose start' EXIT
fi

# ------------------------------------------------------------------ config files
info "Backing up config state"
CONFIG_ITEMS=()
for item in .env secrets authelia/users_database.yml traefik/acme; do
  [[ -e "$item" ]] && CONFIG_ITEMS+=("$item")
done
if [[ ${#CONFIG_ITEMS[@]} -gt 0 ]]; then
  tar -czf "$STAGE/config.tar.gz" "${CONFIG_ITEMS[@]}"
  chmod 600 "$STAGE/config.tar.gz"
  ok "config.tar.gz (${CONFIG_ITEMS[*]})"
else
  warn "no config state found to back up"
fi

# ------------------------------------------------------------------ volumes
VOLUMES=(authelia_data redis_data grafana_data)
$WITH_PROM && VOLUMES+=(prometheus_data)

for vol in "${VOLUMES[@]}"; do
  full="${COMPOSE_PROJECT}_${vol}"
  if ! docker volume inspect "$full" >/dev/null 2>&1; then
    warn "volume $full does not exist — skipping"
    continue
  fi
  info "Backing up volume $full"
  docker run --rm \
    -v "$full":/data:ro \
    -v "$STAGE":/backup \
    alpine tar -czf "/backup/${vol}.tar.gz" -C /data .
  ok "${vol}.tar.gz"
done

# ------------------------------------------------------------------ offsite (restic) or local rotation
if command -v restic >/dev/null 2>&1 && [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
  info "Pushing snapshot to restic repo: $RESTIC_REPOSITORY"
  restic backup "$STAGE" --tag homelab
  restic forget --tag homelab \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  rm -rf "$STAGE"
  ok "restic snapshot stored; local staging removed"
else
  info "restic not configured — keeping local backup with rotation (keep $BACKUP_KEEP)"
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' \
    | sort -r \
    | tail -n +"$((BACKUP_KEEP + 1))" \
    | while IFS= read -r old; do
        warn "rotating out $old"
        rm -rf "$old"
      done
  ok "backup stored in $STAGE"
fi

ok "Backup finished"
