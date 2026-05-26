#!/usr/bin/env bash
# configure-env.sh
# -------------------------------------------------------------------
# Renders .env.staging or .env.prod from operator-supplied values plus
# auto-generated strong secrets. Saves the operator from editing the
# .env file by hand and from picking weak passwords.
#
# Usage:
#   scripts/configure-env.sh <staging|prod>                 # interactive prompts
#   scripts/configure-env.sh <staging|prod> --force         # overwrite existing file
#   scripts/configure-env.sh prod \                         # non-interactive
#       --frontend-host monopetsky.com \
#       --cms-host       cms.monopetsky.com \
#       --backend-host   api.monopetsky.com \
#       --email          ops@monopetsky.com
#
# Optional secret overrides:
#   --postgres-password <value>   # else generated via openssl rand -hex 32
#   --jwt-secret        <value>   # else generated via openssl rand -hex 64
#
# Web Push VAPID keys are NOT auto-generated (different lifecycle —
# generate once with `npx web-push generate-vapid-keys`, then paste in).
# File mode is set to 600 (owner read/write only).
# -------------------------------------------------------------------

set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required (used to generate random secrets)." >&2
    exit 1
fi

ENV=""
FORCE=false
PROVIDED_FE_HOST=""
PROVIDED_CMS_HOST=""
PROVIDED_BE_HOST=""
PROVIDED_EMAIL=""
PROVIDED_PG_PASSWORD=""
PROVIDED_JWT_SECRET=""

if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    ENV="$1"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --force)             FORCE=true; shift ;;
        --frontend-host)     PROVIDED_FE_HOST="$2";      shift 2 ;;
        --cms-host)          PROVIDED_CMS_HOST="$2";     shift 2 ;;
        --backend-host)      PROVIDED_BE_HOST="$2";      shift 2 ;;
        --email)             PROVIDED_EMAIL="$2";        shift 2 ;;
        --postgres-password) PROVIDED_PG_PASSWORD="$2";  shift 2 ;;
        --jwt-secret)        PROVIDED_JWT_SECRET="$2";   shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

case "${ENV}" in
    staging|prod) ;;
    *) echo "Usage: $0 <staging|prod> [--force] [--frontend-host H] [--cms-host H] [--backend-host H] [--email E] [--postgres-password P] [--jwt-secret S]" >&2; exit 1 ;;
esac

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${INFRA_DIR}/.env.${ENV}"

if [ -f "${OUTPUT}" ] && [ "${FORCE}" != true ]; then
    echo "ERROR: ${OUTPUT} already exists." >&2
    echo "       Re-run with --force to overwrite (this rotates the random secrets!)." >&2
    exit 1
fi

is_valid_hostname() {
    local h="$1"
    [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$h" != *..* ]]
}

is_valid_email() {
    [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

prompt_until_valid() {
    local label="$1"
    local varname="$2"
    local validator="$3"
    local current="${!varname}"
    while [ -z "$current" ] || ! "$validator" "$current"; do
        printf "  %s: " "$label"
        read -r current
        if ! "$validator" "$current"; then
            echo "  ! invalid input, try again." >&2
            current=""
        fi
    done
    printf -v "$varname" "%s" "$current"
}

echo "[configure-env] Generating .env.${ENV}"
echo "[configure-env] Press Ctrl-C to abort."
echo

FE_HOST="${PROVIDED_FE_HOST}"
CMS_HOST="${PROVIDED_CMS_HOST}"
BE_HOST="${PROVIDED_BE_HOST}"
EMAIL="${PROVIDED_EMAIL}"

if [ "${ENV}" = "prod" ]; then
    prompt_until_valid "Public storefront host (e.g. monopetsky.com)"     FE_HOST is_valid_hostname
    prompt_until_valid "Public CMS host        (e.g. cms.monopetsky.com)" CMS_HOST is_valid_hostname
    prompt_until_valid "Public backend host    (e.g. api.monopetsky.com)" BE_HOST is_valid_hostname
else
    prompt_until_valid "Public storefront host (e.g. staging.monopetsky.com)"     FE_HOST is_valid_hostname
    prompt_until_valid "Public CMS host        (e.g. cms.staging.monopetsky.com)" CMS_HOST is_valid_hostname
    prompt_until_valid "Public backend host    (e.g. api.staging.monopetsky.com)" BE_HOST is_valid_hostname
fi
prompt_until_valid "Let's Encrypt contact email" EMAIL is_valid_email

# Derive root domain from FE_HOST: strip leading subdomain if present (e.g. staging.monopetsky.com → monopetsky.com)
ROOT_DOMAIN="${FE_HOST#*.}"
# If no dot was stripped (FE_HOST is already the root, e.g. monopetsky.com), keep it as-is
if [ "${ROOT_DOMAIN}" = "${FE_HOST}" ]; then
    ROOT_DOMAIN="${FE_HOST}"
fi

if [ "${ENV}" = "prod" ]; then
    POSTGRES_DB_DEFAULT="monopetsky"
    BACKUP_RETENTION_DAYS="30"
else
    POSTGRES_DB_DEFAULT="monopetsky_staging"
    BACKUP_RETENTION_DAYS="7"
fi
BACKEND_PORT="5050"
FRONTEND_PORT="5002"
CMS_PORT="5001"
POSTGRES_USER="monopetsky"
POSTGRES_DB="${POSTGRES_DB_DEFAULT}"

if [ -n "${PROVIDED_PG_PASSWORD}" ]; then
    POSTGRES_PASSWORD="${PROVIDED_PG_PASSWORD}"
else
    POSTGRES_PASSWORD="$(openssl rand -hex 32)"
fi

if [ -n "${PROVIDED_JWT_SECRET}" ]; then
    JWT_SECRET="${PROVIDED_JWT_SECRET}"
else
    JWT_SECRET="$(openssl rand -hex 64)"
fi
JWT_REFRESH_SECRET="$(openssl rand -hex 64)"

DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}"
NEXT_PUBLIC_API_URL="https://${BE_HOST}"

cat > "${OUTPUT}" <<EOF
# Generated by scripts/configure-env.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) for env=${ENV}
# This file contains secrets. Do not commit. File mode is set to 600.

# --- Postgres ---
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}

# --- Backend ---
DATABASE_URL=${DATABASE_URL}
JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
BACKEND_PORT=${BACKEND_PORT}
RUN_MIGRATIONS_ON_BOOT=true

# --- Frontend (storefront) ---
FRONTEND_PORT=${FRONTEND_PORT}
NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}

# --- CMS ---
CMS_PORT=${CMS_PORT}

# --- CORS ---
CORS_ORIGIN_STOREFRONT=https://${FE_HOST}
CORS_ORIGIN_CMS=https://${CMS_HOST}

# --- Cookies ---
# Leading dot so the cookie is shared across all subdomains (e.g. .monopetsky.com)
COOKIE_DOMAIN=.${ROOT_DOMAIN}

# --- Public hosts (used by nginx) ---
PUBLIC_FRONTEND_HOST=${FE_HOST}
PUBLIC_CMS_HOST=${CMS_HOST}
PUBLIC_BACKEND_HOST=${BE_HOST}

# --- TLS ---
LETSENCRYPT_EMAIL=${EMAIL}

# --- Backups ---
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}

# --- Web Push (VAPID) — generate with: npx web-push generate-vapid-keys ---
VAPID_PUBLIC_KEY=REPLACE_WITH_VAPID_PUBLIC_KEY
VAPID_PRIVATE_KEY=REPLACE_WITH_VAPID_PRIVATE_KEY
VAPID_SUBJECT=mailto:${EMAIL}
EOF

chmod 600 "${OUTPUT}"

echo
echo "[configure-env] Wrote ${OUTPUT} (mode 600)."
echo "[configure-env] Summary (secrets redacted):"
echo "    POSTGRES_USER     = ${POSTGRES_USER}"
echo "    POSTGRES_DB       = ${POSTGRES_DB}"
echo "    POSTGRES_PASSWORD = <generated $(echo -n "${POSTGRES_PASSWORD}" | wc -c) chars>"
echo "    JWT_SECRET        = <generated $(echo -n "${JWT_SECRET}" | wc -c) chars>"
echo "    BACKEND_PORT      = ${BACKEND_PORT}"
echo "    FRONTEND_PORT     = ${FRONTEND_PORT}"
echo "    CMS_PORT          = ${CMS_PORT}"
echo "    PUBLIC_FRONTEND   = ${FE_HOST}"
echo "    PUBLIC_CMS        = ${CMS_HOST}"
echo "    PUBLIC_BACKEND    = ${BE_HOST}"
echo "    NEXT_PUBLIC_API_URL = ${NEXT_PUBLIC_API_URL}"
echo "    LETSENCRYPT_EMAIL = ${EMAIL}"
echo "    BACKUP_RETENTION  = ${BACKUP_RETENTION_DAYS} days"
echo
echo "[configure-env] IMPORTANT:"
echo "  - Paste real VAPID keys into ${OUTPUT} before deploying (generate via npx web-push generate-vapid-keys)."
echo "  - Back up this file or the generated secrets will be lost."
