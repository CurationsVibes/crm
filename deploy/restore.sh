#!/usr/bin/env bash
# restore.sh — CurationsVibes CRM restore from backup archive
#
# Usage:
#   ./restore.sh <backup-archive.tar.gz> [--env-file /path/to/.env.prod]
#
# WARNING: This will STOP the running stack, overwrite the database and
#          local-storage volume, then restart the stack.

set -euo pipefail

# ── Parse arguments ───────────────────────────────────────────────────────────
ARCHIVE=""
ENV_FILE="$(dirname "$0")/.env.prod"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *.tar.gz)   ARCHIVE="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ARCHIVE" ]]; then
  echo "Usage: $0 <backup-archive.tar.gz> [--env-file /path/.env.prod]" >&2
  exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "ERROR: Archive not found: $ARCHIVE" >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
fi

PG_DATABASE_USER="${PG_DATABASE_USER:-postgres}"
COMPOSE_FILE="${COMPOSE_FILE:-$(dirname "$0")/docker-compose.prod.yml}"
WORK_DIR="$(mktemp -d)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

log "=== CurationsVibes CRM Restore ==="
log "Archive : $ARCHIVE"
log "Compose : $COMPOSE_FILE"

# Confirmation gate.
read -r -p "This will OVERWRITE current data. Type 'yes' to continue: " confirm
if [[ "$confirm" != "yes" ]]; then
  log "Aborted."
  exit 0
fi

# ── 1. Extract archive ────────────────────────────────────────────────────────
log "Extracting archive…"
tar xzf "$ARCHIVE" -C "$WORK_DIR"
# Find the timestamped sub-directory inside the archive.
EXTRACTED_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [[ -z "$EXTRACTED_DIR" ]]; then
  # The archive may have been flattened — files are directly in $WORK_DIR.
  EXTRACTED_DIR="$WORK_DIR"
fi

DB_DUMP="$(find "$EXTRACTED_DIR" -name 'database.sql.gz' | head -n1)"
STORAGE_ARCHIVE="$(find "$EXTRACTED_DIR" -name 'local-storage.tar.gz' | head -n1)"

[[ -f "$DB_DUMP" ]]       || { log "ERROR: database.sql.gz not found in archive."; exit 1; }
[[ -f "$STORAGE_ARCHIVE" ]] || { log "ERROR: local-storage.tar.gz not found in archive."; exit 1; }

# ── 2. Stop application containers (keep db + redis running for restore) ───────
log "Stopping server and worker containers…"
docker compose -f "$COMPOSE_FILE" stop server worker cloudflared 2>/dev/null || true

# ── 3. Restore database ───────────────────────────────────────────────────────
DB_CONTAINER="$(docker compose -f "$COMPOSE_FILE" ps -q db | head -n1)"
[[ -n "$DB_CONTAINER" ]] || { log "ERROR: db container not running."; exit 1; }

log "Dropping and recreating database 'default'…"
docker exec "$DB_CONTAINER" \
  psql -U "$PG_DATABASE_USER" -c "DROP DATABASE IF EXISTS default;" postgres
docker exec "$DB_CONTAINER" \
  psql -U "$PG_DATABASE_USER" -c "CREATE DATABASE default;" postgres

log "Restoring database from dump…"
gunzip -c "$DB_DUMP" | docker exec -i "$DB_CONTAINER" \
  psql -U "$PG_DATABASE_USER" default
log "Database restore complete."

# ── 4. Restore local-storage volume ──────────────────────────────────────────
SERVER_CONTAINER="$(docker compose -f "$COMPOSE_FILE" ps -aq server | head -n1)"
[[ -n "$SERVER_CONTAINER" ]] || { log "ERROR: server container not found."; exit 1; }
# The server container is stopped but its volume is still accessible.
# Use an alpine helper that mounts the same volume.
log "Restoring local-storage volume…"
docker run --rm \
  --volumes-from "$SERVER_CONTAINER" \
  -v "$STORAGE_ARCHIVE:/restore/local-storage.tar.gz:ro" \
  alpine \
  sh -c "rm -rf /app/packages/twenty-server/.local-storage && \
         tar xzf /restore/local-storage.tar.gz -C /"
log "Local-storage restore complete."

# ── 5. Restart stack ─────────────────────────────────────────────────────────
log "Restarting full stack…"
docker compose -f "$COMPOSE_FILE" up -d

log "=== Restore complete. Monitor with: docker compose -f $COMPOSE_FILE logs -f ==="
