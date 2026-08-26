# Adding a New Service

Every web service in this stack follows the same recipe: join the `proxy` network, add Traefik labels, and (usually) attach the Authelia middleware. HTTPS certificates, security headers, and SSO then come for free — no Traefik restart needed.

## Quick way: the generator

```bash
./scripts/add-service.sh
```

It asks for a name, image, subdomain, port, whether to protect it with SSO, and an optional Compose profile — then prints a ready-to-paste service block.

## Anatomy of a service block

```yaml
  myapp:
    image: myapp:1.2.3                # always pin versions in production
    container_name: myapp
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy                          # required: Traefik can only reach this network
    labels:
      traefik.enable: "true"           # required: exposedByDefault is false
      traefik.http.routers.myapp.rule: Host(`myapp.${DOMAIN}`)
      traefik.http.routers.myapp.entrypoints: websecure
      traefik.http.routers.myapp.middlewares: authelia@file
      traefik.http.services.myapp.loadbalancer.server.port: "8080"
```

Line by line:

| Piece | Why |
|---|---|
| `networks: [proxy]` | Traefik's docker provider is pinned to the `proxy` network. A container not on it is unreachable. |
| `traefik.enable` | `exposedByDefault: false` in [traefik.yml](../traefik/traefik.yml) means services opt in explicitly. |
| `routers.<name>.rule` | The hostname. `${DOMAIN}` comes from `.env`. Router names must be unique. |
| `entrypoints: websecure` | Port 443. TLS + Let's Encrypt are inherited from the entrypoint defaults; port 80 already redirects. |
| `middlewares: authelia@file` | Forward-auth SSO. **Drop this line** for public services or apps with API clients that can't follow browser redirects (see Ntfy). |
| `loadbalancer.server.port` | The port the app listens on *inside* the container. Needed whenever the image exposes more than one port (safe to always set). |

## When NOT to use the Authelia middleware

- **Native mobile/desktop apps or webhooks** talk to the API directly and can't complete a browser SSO redirect (this is why `ntfy` relies on its own `deny-all` auth instead).
- Apps with their own robust auth that must stay reachable by third parties.

For mixed cases, Authelia access-control rules in [authelia/configuration.yml](../authelia/configuration.yml) support per-path `bypass` policies.

## Optional services & profiles

Services that shouldn't always run get a profile:

```yaml
    profiles:
      - myapp
```

Enable persistently in `.env`:

```
COMPOSE_PROFILES=portainer,homepage,myapp
```

or ad hoc: `docker compose --profile myapp up -d`.

## Checklist after adding

1. **DNS** — add `myapp.<domain>` (skip if you use a wildcard record).
2. `docker compose config -q` — validate.
3. `docker compose up -d myapp` — start; watch `docker compose logs -f traefik` for cert issuance.
4. **Homepage tile** — add an entry in [homepage/config/services.yaml](../homepage/config/services.yaml).
5. **Metrics** — if the app exposes `/metrics`, attach it to the `monitoring` network and add a scrape job in [monitoring/prometheus/prometheus.yml](../monitoring/prometheus/prometheus.yml), then `docker compose restart prometheus`.
6. **Backups** — if it stores state in a named volume, add the volume to the `VOLUMES` list in [scripts/backup.sh](../scripts/backup.sh).
