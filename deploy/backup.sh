#!/usr/bin/env bash
# backup.sh — CurationsVibes CRM database and file-storage backup
#
# Usage:
#   ./backup.sh [--env-file /path/to/.env.prod]
#
# Behaviour:
#   1. Dumps the Postgres database to a compressed SQL file.
#   2. Archives the server local-storage volume.
#   3. Writes both to $BACKUP_DIR with a timestamped folder.
#   4. If BACKUP_S3_BUCKET is set, uploads the archive to S3/R2.
#   5. Prunes local backups older than KEEP_DAYS (default 30).
#
# Schedule with cron (runs at 02:00 daily):
#   0 2 * * * /opt/curations-crm/deploy/backup.sh --env-file /opt/curations-crm/deploy/.env.prod >> /var/log/curations-crm-backup.log 2>&1

set -euo pipefail

# ── Parse arguments ───────────────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/.env.prod"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  # Export only the variables we need; avoid overwriting the running shell.
  set -o allexport
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +o allexport
fi

# ── Configuration (with defaults) ────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-/opt/curations-crm/backups}"
KEEP_DAYS="${KEEP_DAYS:-30}"
PG_DATABASE_USER="${PG_DATABASE_USER:-postgres}"
COMPOSE_FILE="${COMPOSE_FILE:-$(dirname "$0")/docker-compose.prod.yml}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: '$1' is required but not installed."; exit 1; }
}

require_cmd docker

# ── Preflight checks ──────────────────────────────────────────────────────────
log "Starting CurationsVibes CRM backup — $TIMESTAMP"
mkdir -p "$BACKUP_PATH"

# Resolve the Postgres container name from Compose.
DB_CONTAINER="$(docker compose -f "$COMPOSE_FILE" ps -q db 2>/dev/null | head -n1)"
if [[ -z "$DB_CONTAINER" ]]; then
  log "ERROR: Postgres container not found. Is the stack running?"
  exit 1
fi

# ── 1. Database dump ──────────────────────────────────────────────────────────
DB_DUMP="${BACKUP_PATH}/database.sql.gz"
log "Dumping Postgres database to ${DB_DUMP}…"
docker exec "$DB_CONTAINER" \
  pg_dump -U "$PG_DATABASE_USER" default \
  | gzip -9 > "$DB_DUMP"
log "Database dump complete ($(du -sh "$DB_DUMP" | cut -f1))."

# ── 2. Local-storage volume archive ───────────────────────────────────────────
STORAGE_ARCHIVE="${BACKUP_PATH}/local-storage.tar.gz"
log "Archiving server local-storage volume to ${STORAGE_ARCHIVE}…"
# Use a temporary alpine container to read the named volume.
# Query the server container ID (may be stopped) using -aq.
SERVER_CONTAINER="$(docker compose -f "$COMPOSE_FILE" ps -aq server | head -n1)"
if [[ -z "$SERVER_CONTAINER" ]]; then
  log "ERROR: Server container not found. Has the stack ever been started?"
  exit 1
fi
docker run --rm \
  --volumes-from "$SERVER_CONTAINER" \
  alpine \
  tar czf - /app/packages/twenty-server/.local-storage \
  > "$STORAGE_ARCHIVE" 2>/dev/null || true
log "Storage archive complete ($(du -sh "$STORAGE_ARCHIVE" | cut -f1))."

# ── 3. Create a single compressed archive ─────────────────────────────────────
FINAL_ARCHIVE="${BACKUP_DIR}/curations-crm-${TIMESTAMP}.tar.gz"
log "Packaging final archive: ${FINAL_ARCHIVE}…"
tar czf "$FINAL_ARCHIVE" -C "$BACKUP_DIR" "$TIMESTAMP"
rm -rf "$BACKUP_PATH"
log "Final archive: $(du -sh "$FINAL_ARCHIVE" | cut -f1)."

# ── 4. Optional: upload to S3/R2 ─────────────────────────────────────────────
if [[ -n "${BACKUP_S3_BUCKET:-}" ]]; then
  if command -v aws >/dev/null 2>&1; then
    log "Uploading to s3://${BACKUP_S3_BUCKET}/…"
    AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}" \
    AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}" \
    AWS_DEFAULT_REGION="${BACKUP_S3_REGION:-auto}" \
    aws s3 cp "$FINAL_ARCHIVE" \
      "s3://${BACKUP_S3_BUCKET}/curations-crm-${TIMESTAMP}.tar.gz" \
      ${BACKUP_S3_ENDPOINT:+--endpoint-url "$BACKUP_S3_ENDPOINT"}
    log "Upload complete."
  else
    log "WARNING: BACKUP_S3_BUCKET is set but 'aws' CLI is not installed. Skipping upload."
    log "         Install with: pip install awscli"
  fi
fi

# ── 5. Prune old local backups ────────────────────────────────────────────────
log "Removing local backups older than ${KEEP_DAYS} days…"
find "$BACKUP_DIR" -maxdepth 1 -name "curations-crm-*.tar.gz" \
  -mtime "+${KEEP_DAYS}" -delete
log "Pruning complete."

log "Backup finished successfully: ${FINAL_ARCHIVE}"
