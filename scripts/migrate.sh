#!/usr/bin/env bash
# migrate.sh
# -------------------------------------------------------------------
# Manually apply backend SQL migrations against the running Postgres
# container. The backend entrypoint already runs migrations on boot
# when RUN_MIGRATIONS_ON_BOOT=true; this script is for ad-hoc re-runs
# without restarting the backend (e.g. after adding a new migration
# without bumping the image).
#
# Usage: scripts/migrate.sh <staging|prod>
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

echo "[migrate] running migrations via backend container's entrypoint logic..."
"${COMPOSE[@]}" exec -T backend sh -c '
    set -e
    : "${DATABASE_URL:?DATABASE_URL must be set}"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS _schema_migrations (filename VARCHAR(255) PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"
    for f in /app/migrations/*.sql; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        if psql "$DATABASE_URL" -tAc "SELECT 1 FROM _schema_migrations WHERE filename='\''$name'\''" | grep -q 1; then
            echo "  skip $name"
        else
            echo "  apply $name"
            psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f"
            psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "INSERT INTO _schema_migrations (filename) VALUES ('\''$name'\'')"
        fi
    done
    echo "[migrate] complete."
'
