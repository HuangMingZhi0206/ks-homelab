#!/usr/bin/env bash
#
# Interactive generator: prints a ready-to-paste docker-compose service block
# with Traefik routing (+ optional Authelia SSO and Compose profile).
# It does NOT modify any file — review the output, then paste it into
# docker-compose.yml. See docs/adding-services.md for the full walkthrough.

set -euo pipefail

read -rp "Service name (lowercase, a-z 0-9 -): " NAME
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid name" >&2; exit 1; }

read -rp "Docker image [${NAME}:latest]: " IMAGE
IMAGE="${IMAGE:-${NAME}:latest}"

read -rp "Subdomain [${NAME}]: " SUBDOMAIN
SUBDOMAIN="${SUBDOMAIN:-$NAME}"

read -rp "Container port the app listens on: " PORT
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "invalid port" >&2; exit 1; }

read -rp "Protect with Authelia SSO? [Y/n]: " SSO
SSO="${SSO:-Y}"

read -rp "Compose profile (empty = always on): " PROFILE

MIDDLEWARE_LINE=""
if [[ "$SSO" =~ ^[Yy] ]]; then
  MIDDLEWARE_LINE="      traefik.http.routers.${NAME}.middlewares: authelia@file"
fi

PROFILE_BLOCK=""
if [[ -n "$PROFILE" ]]; then
  PROFILE_BLOCK="    profiles:
      - ${PROFILE}"
fi

echo
echo "# ------- paste into the services: section of docker-compose.yml -------"
cat <<EOF
  ${NAME}:
    image: ${IMAGE}
    container_name: ${NAME}
    restart: unless-stopped
${PROFILE_BLOCK:+$PROFILE_BLOCK
}    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    labels:
      traefik.enable: "true"
      traefik.http.routers.${NAME}.rule: Host(\`${SUBDOMAIN}.\${DOMAIN}\`)
      traefik.http.routers.${NAME}.entrypoints: websecure
${MIDDLEWARE_LINE:+$MIDDLEWARE_LINE
}      traefik.http.services.${NAME}.loadbalancer.server.port: "${PORT}"
EOF
echo "# -----------------------------------------------------------------------"
echo
echo "Then:"
echo "  1. Add DNS for ${SUBDOMAIN}.<your-domain> (skip if you use a wildcard)"
echo "  2. docker compose up -d ${NAME}"
[[ -n "$PROFILE" ]] && echo "     (profile service: add '${PROFILE}' to COMPOSE_PROFILES in .env first)"
echo "  3. Optional: add a tile in homepage/config/services.yaml"
