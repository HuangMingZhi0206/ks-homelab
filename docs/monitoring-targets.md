# Monitoring machines outside this host

Prometheus scrapes containers on this host directly. Everything else — the
hypervisor, the switch — speaks a protocol it does not understand, so an
exporter sits in between and translates. Two are wired up here, both optional.

Without these, the stack only monitors the machine it runs on. That is the least
useful part of the network to watch: if it goes down, so does the monitoring.

## Proxmox VE

Gives node CPU, memory, storage and per-VM/LXC state.

**1. Create a read-only user and token in Proxmox.**

*Datacenter → Permissions → Users → Add*: user `prometheus`, realm `Proxmox VE
authentication server`.

*Datacenter → Permissions → API Tokens → Add*: user `prometheus@pve`, Token ID
`monitoring`, and **uncheck Privilege Separation** so the token inherits the
user's permissions. The secret is shown once — copy it now.

*Datacenter → Permissions → Add → User Permission*: Path `/`, User
`prometheus@pve`, Role **`PVEAuditor`**.

`PVEAuditor` is read-only. It cannot start, stop, or change anything, which is
what you want for something whose only job is to look.

**2. Fill in `.env`:**

```
PVE_USER=prometheus@pve
PVE_TOKEN_NAME=monitoring
PVE_TOKEN_VALUE=<the secret>
```

**3. Point the scrape job at your host.** In
`monitoring/prometheus/prometheus.yml`, the `proxmox` job's `targets` must be
the Proxmox host's address.

## Managed switch (SNMP)

Gives per-port throughput, link state, and error counters. Switches in this
class have no REST API, so SNMP is the only way in — and it is read-only in
practice, so treat the switch as monitor-only and keep configuring VLANs through
its web UI.

**1. Enable SNMP on the switch.** On a D-Link DGS-1100: *System → SNMP
Settings* — enable it and set a read-only community string.

**2. Set the community and address.** In `prometheus.yml`, the `switch` job's
`auth` parameter selects a credential from the exporter's bundled config;
`public_v2` means community `public`. If yours differs, mount a custom
`snmp.yml` rather than editing the bundled one. Set `targets` to the switch's
address.

The `if_mib` module is generic — it reads standard interface counters, so it
works on essentially any managed switch, not just this one.

## Turning them on

```bash
docker compose --profile pve-exporter --profile snmp-exporter up -d
```

To make it permanent, add them to `COMPOSE_PROFILES` in `.env`.

Check both are being scraped at `https://prometheus.<domain>` → *Status →
Targets*. A job shown as **down** with a connection error usually means its
profile is not enabled; **up** with no data usually means credentials.

## Dashboards

Neither exporter ships a dashboard. Search grafana.com/dashboards for
"Proxmox via Prometheus" and "SNMP Interface", then import by ID under
*Dashboards → New → Import*. Check the panel queries expect the same job names
used here (`proxmox`, `switch`) — most let you pick the job from a dropdown.
