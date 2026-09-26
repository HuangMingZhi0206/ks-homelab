#!/usr/bin/env bash
#
# Heartbeat to healthchecks.io, from cron on the Pi.
#
# This exists to cover the one thing the Grafana alerts cannot: Grafana and
# Prometheus both run on this Pi, so when the Pi goes down nothing is
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

uptime_s="$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)"

body="host=$(hostname) uptime=${uptime_s}s undervoltage=${undervolt}"

# A fast reboot loop is invisible to everything else here, and it is the worst
# failure this machine has. Grafana cannot report it because Grafana dies with
# the host: after a reboot the stack needs ~60s to come up, Grafana another
# ~30s, then a 1m rule interval and a 30s group_wait — about three minutes
# before a message leaves. The night the power supply failed, the Pi was
# rebooting every two minutes, so nothing was ever sent.
#
# The plain ping cannot report it either: these run every five minutes, and a
# host that is back within two looks perfectly healthy from outside.
#
# So say it explicitly. healthchecks.io emails on /fail without waiting for
# anything on this machine to still be alive.
# Telegram directly, reusing the credentials Grafana already has in .env.
#
# Two layers on purpose. This one is fast and lands where you actually look,
# but it can only speak while the Pi is alive — which covers a reboot, because
# after a reboot the Pi *is* alive. The healthchecks ping below is the other
# half: it comes from outside the house, so it still works when this machine
# is gone entirely. Neither replaces the other.
telegram() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
  curl -fsS -m 10 --retry 2 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null || true
}

if [[ "$uptime_s" -lt 600 ]]; then
  telegram "🔴 ${HOSTNAME:-pi} rebooted ${uptime_s}s ago — ${body}"
  curl -fsS -m 10 --retry 3 --data-raw "REBOOTED ${uptime_s}s ago | ${body}" \
    "${HEALTHCHECKS_URL}/fail" >/dev/null
elif [[ -n "$down" ]]; then
  telegram "🔴 ${HOSTNAME:-pi} containers down:${down} — ${body}"
  curl -fsS -m 10 --retry 3 --data-raw "DOWN:${down} | ${body}" \
    "${HEALTHCHECKS_URL}/fail" >/dev/null
else
  curl -fsS -m 10 --retry 3 --data-raw "ok | ${body}" \
    "${HEALTHCHECKS_URL}" >/dev/null
fi
