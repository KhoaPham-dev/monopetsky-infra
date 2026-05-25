#!/usr/bin/env bash
# backup-db.sh
# -------------------------------------------------------------------
# Trigger a Postgres backup on demand. The db-backup container also
# runs an automated pg_dump nightly at 02:00 UTC; use this script when
# you want a fresh backup right now (e.g. before a risky migration).
#
# Usage: scripts/backup-db.sh <staging|prod>
#
# Output goes to the db_backups Docker volume as
#   /backups/manual-YYYYMMDD-HHMMSS.sql.gz
# -------------------------------------------------------------------

set -euo pipefail

ENV="${1:-}"
case "${ENV}" in
    staging|prod) ;;
    *) echo "Usage: $0 <staging|prod>" >&2; exit 1 ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"
[ -f "${ENV_FILE}" ] || { echo "ERROR: ${ENV_FILE} not found" >&2; exit 1; }

cd "${INFRA_DIR}"
COMPOSE=(docker compose -f docker-compose.yml -f "docker-compose.${ENV}.yml" --env-file "${ENV_FILE}")

STAMP="$(date -u +%Y%m%d-%H%M%S)"
FILE="/backups/manual-${STAMP}.sql.gz"
echo "[backup] writing ${FILE} on the db-backup volume..."
"${COMPOSE[@]}" exec -T db-backup sh -c "pg_dump --no-owner --no-privileges | gzip > ${FILE}"
echo "[backup] done. List backups: ${COMPOSE[*]} exec db-backup ls -lh /backups"
