#!/usr/bin/env bash
# deploy.sh
# -------------------------------------------------------------------
# Pulls latest code in all four repos, rebuilds images, brings the
# Docker Compose stack up for the chosen environment, then waits for
# the backend's /health endpoint to return 200.
#
# Usage:
#   scripts/deploy.sh <staging|prod>              # pull + build + up
#   scripts/deploy.sh <staging|prod> --no-pull    # skip git pull
#   scripts/deploy.sh <staging|prod> --no-build   # skip image rebuild
#   scripts/deploy.sh <staging|prod> --tunnel     # runs cloudflared as a Docker container,
#                                                 # disables nginx + certbot
#
# Assumes the four repos are checked out side-by-side:
#   ~/monopetsky-infra/     (this repo)
#   ~/monopetsky-backend/
#   ~/monopetsky-frontend/
#   ~/monopetsky-cms/
# -------------------------------------------------------------------

set -euo pipefail

# ---------- Parse positional env arg ----------
ENV="${1:-}"
shift || true
case "${ENV}" in
    staging|prod) ;;
    *) echo "Usage: $0 <staging|prod> [--no-pull] [--no-build] [--tunnel]" >&2; exit 1 ;;
esac

# ---------- Parse remaining flags ----------
DO_PULL=true
DO_BUILD=true
USE_TUNNEL=false
for arg in "$@"; do
    case "$arg" in
        --no-pull)  DO_PULL=false ;;
        --no-build) DO_BUILD=false ;;
        --tunnel)   USE_TUNNEL=true ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# ---------- Resolve paths ----------
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(dirname "${INFRA_DIR}")"
ENV_FILE="${INFRA_DIR}/.env.${ENV}"
NGINX_CONF="${INFRA_DIR}/nginx/conf.d/monopetsky.conf"

# ---------- Pre-flight checks ----------
if [ ! -f "${ENV_FILE}" ]; then
    echo "ERROR: ${ENV_FILE} not found." >&2
    echo "       Run: ./scripts/configure-env.sh ${ENV}" >&2
    exit 1
fi

if [ "${USE_TUNNEL}" != true ] && [ ! -f "${NGINX_CONF}" ]; then
    echo "ERROR: ${NGINX_CONF} not found — nginx config has not been rendered." >&2
    echo "       Run: ./scripts/configure-nginx.sh" >&2
    echo "       Or use --tunnel if you're ingressing via Cloudflare Tunnel." >&2
    exit 1
fi

cd "${INFRA_DIR}"

COMPOSE=(docker compose -f docker-compose.yml -f "docker-compose.${ENV}.yml" --env-file "${ENV_FILE}")
if [ "${USE_TUNNEL}" = true ]; then
    COMPOSE+=(-f docker-compose.tunnel.yml)
fi

# ---------- Pull latest code ----------
if [ "${DO_PULL}" = true ]; then
    echo "[deploy] git pull on infra, backend, frontend, cms"
    for repo in monopetsky-infra monopetsky-backend monopetsky-frontend monopetsky-cms; do
        if [ -d "${ROOT_DIR}/${repo}/.git" ]; then
            echo "  -> ${repo}"
            git -C "${ROOT_DIR}/${repo}" fetch --quiet origin
            git -C "${ROOT_DIR}/${repo}" pull --ff-only --quiet
        else
            echo "  !! ${ROOT_DIR}/${repo} not a git repo, skipping" >&2
        fi
    done
fi

# ---------- Build images ----------
if [ "${DO_BUILD}" = true ]; then
    echo "[deploy] building images"
    "${COMPOSE[@]}" build
fi

# ---------- Bring stack up ----------
echo "[deploy] bringing stack up (${ENV})"
"${COMPOSE[@]}" up -d

# ---------- Wait for backend health ----------
echo "[deploy] waiting for backend health..."
BACKEND_PORT="$(grep -E '^BACKEND_PORT=' "${ENV_FILE}" | cut -d= -f2)"
BACKEND_PORT="${BACKEND_PORT:-4000}"

for i in $(seq 1 30); do
    if curl -fsS "http://localhost:${BACKEND_PORT}/health" >/dev/null 2>&1; then
        echo "[deploy] backend healthy."
        break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
        echo "[deploy] WARNING: backend health check did not pass within 60s" >&2
        echo "[deploy] check logs: scripts/logs.sh ${ENV} backend"
        exit 1
    fi
done

echo "[deploy] done."
"${COMPOSE[@]}" ps
