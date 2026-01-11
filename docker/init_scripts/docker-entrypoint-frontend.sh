#!/bin/sh

# Frontend-only entrypoint script for RomM
# This script sets up nginx configuration for the frontend container

# Set default values for environment variables used by nginx templates.
# Nginx uses `envsubst` to load environment variables into configuration files, but it does not
# support the default value syntax `${VAR:-default}`.
export BACKEND_URL=${BACKEND_URL:-http://romm-backend:5000}
export ROMM_PORT=${ROMM_PORT:-8080}

# Set IPV6_LISTEN based on IPV4_ONLY
if [ "${IPV4_ONLY}" = "true" ]; then
	export IPV6_LISTEN="#listen [::]:${ROMM_PORT};"
else
	export IPV6_LISTEN="listen [::]:${ROMM_PORT};"
fi

# Replace environment variables used in nginx configuration templates.
/docker-entrypoint.d/20-envsubst-on-templates.sh >/dev/null

exec "$@"
