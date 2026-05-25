#!/usr/bin/env bash
# logs.sh
# -------------------------------------------------------------------
# Tail Compose logs for the chosen environment.
#
# Usage:
#   scripts/logs.sh <staging|prod|dev>           # all services
#   scripts/logs.sh <staging|prod|dev> backend   # one service (backend|cms|frontend|postgres|nginx|certbot|db-backup)
# -------------------------------------------------------------------

set -euo pipefail

ENV="${1:-}"
SERVICE="${2:-}"
case "${ENV}" in
    staging|prod|dev) ;;
    *) echo "Usage: $0 <staging|prod|dev> [service]" >&2; exit 1 ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"
[ -f "${ENV_FILE}" ] || ENV_FILE="${INFRA_DIR}/.env"

cd "${INFRA_DIR}"
if [ -n "${SERVICE}" ]; then
    docker compose -f docker-compose.yml -f "docker-compose.${ENV}.yml" --env-file "${ENV_FILE}" logs -f --tail=200 "${SERVICE}"
else
    docker compose -f docker-compose.yml -f "docker-compose.${ENV}.yml" --env-file "${ENV_FILE}" logs -f --tail=100
fi
