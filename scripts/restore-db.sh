#!/usr/bin/env bash
# restore-db.sh
# -------------------------------------------------------------------
# Restore Postgres from a backup file inside the db-backup volume.
#
#   DESTRUCTIVE: drops and recreates the target database.
#   Operator must type the DB name to confirm.
#
# Usage:
#   scripts/restore-db.sh <staging|prod> <backup-filename>
# Where <backup-filename> is the basename inside /backups, e.g.
#   backup-20260601-020000.sql.gz
# -------------------------------------------------------------------

set -euo pipefail

ENV="${1:-}"
FILE="${2:-}"
case "${ENV}" in
    staging|prod) ;;
    *) echo "Usage: $0 <staging|prod> <backup-filename>" >&2; exit 1 ;;
esac
[ -n "${FILE}" ] || { echo "ERROR: backup filename required" >&2; exit 1; }

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"
[ -f "${ENV_FILE}" ] || { echo "ERROR: ${ENV_FILE} not found" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "${ENV_FILE}"; set +a

echo "WARNING: this will DROP and recreate database '${POSTGRES_DB}' in ${ENV}."
printf "Type the database name to confirm: "
read -r CONFIRM
[ "${CONFIRM}" = "${POSTGRES_DB}" ] || { echo "Aborted."; exit 1; }

cd "${INFRA_DIR}"
COMPOSE=(docker compose -f docker-compose.yml -f "docker-compose.${ENV}.yml" --env-file "${ENV_FILE}")

echo "[restore] dropping connections, recreating db..."
"${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${POSTGRES_DB}";
CREATE DATABASE "${POSTGRES_DB}" OWNER "${POSTGRES_USER}";
SQL

echo "[restore] piping backup into psql..."
"${COMPOSE[@]}" exec -T db-backup sh -c "gunzip -c /backups/${FILE}" \
    | "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1

echo "[restore] done."
