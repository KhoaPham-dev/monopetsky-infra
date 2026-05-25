#!/usr/bin/env bash
# configure-nginx.sh
# -------------------------------------------------------------------
# Renders nginx/conf.d/monopetsky.conf.template into a real
# nginx/conf.d/monopetsky.conf by substituting the operator's hostnames
# for the __PLACEHOLDER__ tokens. Six hostnames total: prod/staging x
# storefront/cms/backend.
#
# Usage:
#   ./scripts/configure-nginx.sh                    # interactive prompts
#   ./scripts/configure-nginx.sh \                  # non-interactive
#       --prod-fe monopetsky.com \
#       --prod-cms cms.monopetsky.com \
#       --prod-be api.monopetsky.com \
#       --staging-fe staging.monopetsky.com \
#       --staging-cms cms.staging.monopetsky.com \
#       --staging-be api.staging.monopetsky.com
#
# The rendered file is gitignored — re-run this script whenever the
# hostnames change.
# -------------------------------------------------------------------

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="${INFRA_DIR}/nginx/conf.d/monopetsky.conf.template"
OUTPUT="${INFRA_DIR}/nginx/conf.d/monopetsky.conf"

PROD_FE=""
PROD_CMS=""
PROD_BE=""
STAGING_FE=""
STAGING_CMS=""
STAGING_BE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --prod-fe)     PROD_FE="$2";     shift 2 ;;
        --prod-cms)    PROD_CMS="$2";    shift 2 ;;
        --prod-be)     PROD_BE="$2";     shift 2 ;;
        --staging-fe)  STAGING_FE="$2";  shift 2 ;;
        --staging-cms) STAGING_CMS="$2"; shift 2 ;;
        --staging-be)  STAGING_BE="$2";  shift 2 ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Lightweight hostname check — rejects empty input and obvious nonsense.
is_valid_hostname() {
    local h="$1"
    [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$h" != *..* ]]
}

prompt_hostname() {
    local label="$1"
    local varname="$2"
    local current="${!varname}"
    while [ -z "$current" ] || ! is_valid_hostname "$current"; do
        printf "  %s: " "$label"
        read -r current
        if ! is_valid_hostname "$current"; then
            echo "  ! invalid hostname, try again." >&2
            current=""
        fi
    done
    printf -v "$varname" "%s" "$current"
}

echo "[configure-nginx] Enter the six hostnames to bake into nginx config."
echo "[configure-nginx] Press Ctrl-C to abort."
prompt_hostname "Production storefront host  (e.g. monopetsky.com)"            PROD_FE
prompt_hostname "Production CMS host         (e.g. cms.monopetsky.com)"        PROD_CMS
prompt_hostname "Production backend host     (e.g. api.monopetsky.com)"        PROD_BE
prompt_hostname "Staging storefront host     (e.g. staging.monopetsky.com)"    STAGING_FE
prompt_hostname "Staging CMS host            (e.g. cms.staging.monopetsky.com)" STAGING_CMS
prompt_hostname "Staging backend host        (e.g. api.staging.monopetsky.com)" STAGING_BE

[ -f "$TEMPLATE" ] || { echo "ERROR: template not found at $TEMPLATE" >&2; exit 1; }

sed \
    -e "s|__PROD_FRONTEND_HOST__|${PROD_FE}|g" \
    -e "s|__PROD_CMS_HOST__|${PROD_CMS}|g" \
    -e "s|__PROD_BACKEND_HOST__|${PROD_BE}|g" \
    -e "s|__STAGING_FRONTEND_HOST__|${STAGING_FE}|g" \
    -e "s|__STAGING_CMS_HOST__|${STAGING_CMS}|g" \
    -e "s|__STAGING_BACKEND_HOST__|${STAGING_BE}|g" \
    "$TEMPLATE" > "$OUTPUT"

echo "[configure-nginx] Rendered $OUTPUT"
echo "[configure-nginx] Substituted hostnames:"
echo "    prod    storefront = $PROD_FE"
echo "    prod    cms        = $PROD_CMS"
echo "    prod    backend    = $PROD_BE"
echo "    staging storefront = $STAGING_FE"
echo "    staging cms        = $STAGING_CMS"
echo "    staging backend    = $STAGING_BE"
echo "[configure-nginx] Next: ./scripts/deploy.sh <staging|prod>"
