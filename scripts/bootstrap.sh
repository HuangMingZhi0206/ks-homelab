#!/usr/bin/env bash
#
# Bootstrap the homelab stack:
#   1. Verify docker + compose are available
#   2. Create .env from .env.example (interactive)
#   3. Generate secrets (Authelia keys, Grafana admin password)
#   4. Prepare Traefik ACME storage
#   5. Create the Authelia user database with a hashed admin password
#   6. Pull images and start the stack
#
# Safe to re-run: existing .env, secrets, and user database are left untouched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

AUTHELIA_IMAGE="authelia/authelia:4.39"

info()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

# Terminals that send CRLF — the Proxmox noVNC console among them — leave a
# stray carriage return in every `read` result. That CR ends up inside the
# generated YAML, and Authelia then refuses to start with "control characters
# are not allowed". Strip CR/LF from anything captured from a prompt.
clean() { printf '%s' "$1" | tr -d '\r\n'; }

# ------------------------------------------------------------------ prerequisites
command -v docker >/dev/null 2>&1 || { err "docker is not installed"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "docker compose v2 is required"; exit 1; }
docker info >/dev/null 2>&1 || { err "cannot talk to the Docker daemon (is it running? are you in the docker group?)"; exit 1; }
ok "Docker and Compose are available"

# ------------------------------------------------------------------ .env
if [[ ! -f .env ]]; then
  info "Creating .env"
  read -rp "Base domain (e.g. home.example.com): " DOMAIN
  read -rp "Let's Encrypt email: " ACME_EMAIL
  read -rp "Timezone [Etc/UTC]: " TZ_INPUT
  DOMAIN="$(clean "$DOMAIN")"
  ACME_EMAIL="$(clean "$ACME_EMAIL")"
  TZ_INPUT="$(clean "${TZ_INPUT:-Etc/UTC}")"

  [[ -n "$DOMAIN" && -n "$ACME_EMAIL" ]] || { err "domain and email are required"; exit 1; }

  sed -e "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" \
      -e "s|^ACME_EMAIL=.*|ACME_EMAIL=${ACME_EMAIL}|" \
      -e "s|^TZ=.*|TZ=${TZ_INPUT}|" \
      .env.example > .env
  ok ".env written"
else
  ok ".env already exists — keeping it"
fi

# shellcheck disable=SC1091
source .env

# Traefik's static config cannot read env vars — patch the ACME email in place.
if grep -q 'changeme@example.com' traefik/traefik.yml; then
  sed -i.bak "s|changeme@example.com|${ACME_EMAIL}|" traefik/traefik.yml && rm -f traefik/traefik.yml.bak
  ok "ACME email set in traefik/traefik.yml"
fi

# ------------------------------------------------------------------ fallback TLS cert
# Real certificates come from Let's Encrypt, but issuance is asynchronous and
# can fail (bad token, rate limit, DNS not propagated). dynamic/tls.yml sets
# sniStrict, which rejects any SNI matching no configured certificate, so keep a
# self-signed wildcard as the certificate that covers that gap. Regenerate it
# whenever it no longer matches the configured domain.
mkdir -p traefik/certs
if [[ -s traefik/certs/local.crt ]] \
  && ! openssl x509 -in traefik/certs/local.crt -noout -text 2>/dev/null \
     | grep -qF "DNS:*.${DOMAIN}"; then
  info "fallback certificate does not cover *.${DOMAIN} — regenerating"
  rm -f traefik/certs/local.crt traefik/certs/local.key
fi
if [[ ! -s traefik/certs/local.crt ]]; then
  info "Generating self-signed wildcard certificate for *.${DOMAIN}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout traefik/certs/local.key -out traefik/certs/local.crt \
    -subj "/CN=*.${DOMAIN}" \
    -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}" 2>/dev/null \
    || { err "openssl failed to generate the fallback certificate"; exit 1; }
  ok "traefik/certs/local.crt generated for *.${DOMAIN} (valid 10 years)"
fi
chmod 644 traefik/certs/local.crt
chmod 600 traefik/certs/local.key


# ------------------------------------------------------------------ secrets
info "Generating secrets (skipping any that already exist)"
mkdir -p secrets
chmod 700 secrets
gen_secret() {
  local f="secrets/$1" mode="${2:-600}"
  if [[ ! -s "$f" ]]; then
    openssl rand -hex 32 > "$f"
    ok "generated $f"
  fi
  chmod "$mode" "$f"
}
gen_secret authelia_jwt_secret
gen_secret authelia_session_secret
gen_secret authelia_storage_encryption_key
# Grafana's entrypoint reads this as uid 472, not root. Compose outside Swarm
# silently ignores the secret's uid/gid/mode fields, so the source file itself
# must be readable by that user or Grafana dies with "Permission denied".
# secrets/ is mode 700, so this is not exposed to other users on the host.
gen_secret grafana_admin_password 644

# ------------------------------------------------------------------ traefik ACME storage
mkdir -p traefik/acme
if [[ ! -f traefik/acme/acme.json ]]; then
  touch traefik/acme/acme.json
fi
chmod 600 traefik/acme/acme.json
ok "traefik/acme/acme.json ready (mode 600)"

# ------------------------------------------------------------------ authelia users
if [[ ! -f authelia/users_database.yml ]]; then
  info "Creating Authelia admin user"
  read -rp "Admin username [admin]: " ADMIN_USER
  ADMIN_USER="$(clean "${ADMIN_USER:-admin}")"
  read -rp "Admin email [admin@${DOMAIN}]: " ADMIN_EMAIL
  ADMIN_EMAIL="$(clean "${ADMIN_EMAIL:-admin@${DOMAIN}}")"

  while true; do
    read -rsp "Admin password: " ADMIN_PASS; echo
    read -rsp "Confirm password: " ADMIN_PASS2; echo
    ADMIN_PASS="$(clean "$ADMIN_PASS")"
    ADMIN_PASS2="$(clean "$ADMIN_PASS2")"
    [[ "$ADMIN_PASS" == "$ADMIN_PASS2" && -n "$ADMIN_PASS" ]] && break
    err "passwords empty or do not match, try again"
  done

  info "Hashing password (argon2id)"
  HASH="$(clean "$(docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$ADMIN_PASS" | awk '/Digest:/ {print $2}')")"
  [[ -n "$HASH" ]] || { err "failed to generate password hash"; exit 1; }

  cat > authelia/users_database.yml <<EOF
users:
  ${ADMIN_USER}:
    disabled: false
    displayname: "${ADMIN_USER}"
    password: "${HASH}"
    email: ${ADMIN_EMAIL}
    groups:
      - admins
EOF
  chmod 600 authelia/users_database.yml
  ok "authelia/users_database.yml written"
else
  ok "authelia/users_database.yml already exists — keeping it"
fi

# ------------------------------------------------------------------ launch
info "Validating compose file"
docker compose config -q
ok "compose file is valid"

info "Pulling images"
docker compose pull

info "Starting the stack"
docker compose up -d

echo
ok "Stack is up. Give Let's Encrypt ~30s for first certificate issuance."
echo
echo "  Auth portal   : https://auth.${DOMAIN}"
echo "  Traefik       : https://traefik.${DOMAIN}"
echo "  Grafana       : https://grafana.${DOMAIN}   (Grafana admin pw: secrets/grafana_admin_password)"
echo "  Prometheus    : https://prometheus.${DOMAIN}"
echo
echo "  Check status  : docker compose ps"
echo "  Follow logs   : docker compose logs -f traefik authelia"
