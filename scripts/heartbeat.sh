#!/usr/bin/env bash
#
# Heartbeat to healthchecks.io, from cron on the Pi.
#
# This exists to cover the one thing the Grafana alerts cannot: Grafana,
# Prometheus and ntfy all run on this Pi, so when the Pi goes down nothing is
# left to tell you. healthchecks.io watches from outside — if these pings stop
# arriving, it emails you.
#
# It is not a bare liveness ping. A Pi that is up while Traefik is dead is not
# healthy, so the core containers are checked and a failure is reported
# explicitly to the /fail endpoint rather than being hidden by a cheerful ping.
#
# Install (every 5 minutes):
#   crontab -e
#   */5 * * * * /opt/homelab/scripts/heartbeat.sh
#
# Set HEALTHCHECKS_URL in .env. Without it this exits quietly, so the cron
# entry is harmless on a machine that has not been set up.

# Deliberately not `set -e`: this script's job is to report problems, not to
# die on the first one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
[[ -n "${HEALTHCHECKS_URL:-}" ]] || exit 0

# The containers whose absence means the stack is not serving, regardless of
# what else is running. Profile services are left out on purpose — they are
# optional by definition, so alerting on them would fire on any machine that
# simply has them switched off.
CORE="traefik authelia redis prometheus grafana"

down=""
for c in $CORE; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  [[ "$state" == "running" ]] || down="${down} ${c}=${state}"
done

# Carried in the ping body so it shows up in the check's history on
# healthchecks.io. On this Pi that matters: the power supply has been dropping
# voltage, and a count climbing between heartbeats is the evidence.
undervolt="$(journalctl -k -b 0 2>/dev/null | grep -ci undervolt || echo '?')"

body="host=$(hostname) uptime=$(cut -d' ' -f1 /proc/uptime) undervoltage=${undervolt}"

if [[ -n "$down" ]]; then
  curl -fsS -m 10 --retry 3 --data-raw "DOWN:${down} | ${body}" \
    "${HEALTHCHECKS_URL}/fail" >/dev/null
else
  curl -fsS -m 10 --retry 3 --data-raw "ok | ${body}" \
    "${HEALTHCHECKS_URL}" >/dev/null
fi
