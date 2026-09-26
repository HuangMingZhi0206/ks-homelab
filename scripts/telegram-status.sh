#!/usr/bin/env bash
#
# Answer /status in Telegram with the state of this machine.
#
# Run from cron every minute:
#   * * * * * /opt/homelab/scripts/telegram-status.sh
#
# Reuses TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID from .env — the same bot
# Grafana and heartbeat.sh already send through.
#
# IMPORTANT: only one process may poll getUpdates for a given bot. If you ever
# add the Telegram integration in Home Assistant, give it its own bot or this
# script and that integration will steal each other's messages.
#
# Replies only to TELEGRAM_CHAT_ID. Anyone else who finds the bot gets silence,
# not a status report — the bot's username is discoverable, the chat id is not.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || exit 0

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
STATE="${HOME}/.telegram-status-offset"

send() {
  curl -fsS -m 15 --retry 2 -X POST "${API}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null || true
}

# Prometheus is not published on the host, so ask it from inside its own
# container. $2 is a jq expression run against each result element.
promq() {
  docker exec prometheus wget -qO- \
    "http://127.0.0.1:9090/api/v1/query?query=$(printf '%s' "$1" | jq -sRr @uri)" 2>/dev/null |
    jq -r "[.data.result[] | $2] | join(\", \")" 2>/dev/null
}

status_report() {
  local up load temp undervolt disk hdd stopped
  up="$(uptime -p 2>/dev/null || echo '?')"
  load="$(cut -d' ' -f1-3 /proc/loadavg)"
  undervolt="$(journalctl -k -b 0 2>/dev/null | grep -ci undervolt || echo '?')"
  disk="$(df -h / | awk 'NR==2 {print $4" free of "$2" ("$5" used)"}')"

  # Millidegrees on this kernel; /1000 for something readable.
  if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    temp="$(awk '{printf "%.1f C", $1/1000}' /sys/class/thermal/thermal_zone0/temp)"
  else
    temp="?"
  fi

  if mountpoint -q /srv/hdd 2>/dev/null; then
    hdd="$(df -h /srv/hdd | awk 'NR==2 {print $4" free of "$2}')"
  else
    hdd="not mounted"
  fi

  # Name what is wrong, not what is right: a list of eleven healthy containers
  # is a wall of text you stop reading, and the one that matters hides in it.
  stopped="$(docker ps -a --filter label=com.docker.compose.project --filter status=exited --format '{{.Names}}' 2>/dev/null | paste -sd' ' -)"
  [[ -n "$stopped" ]] || stopped="none"

  # Everything below comes from Prometheus and Grafana, which already know the
  # answers — asking them beats reimplementing the checks here and drifting
  # out of step with what actually alerts.
  local down_targets guests firing
  down_targets="$(promq 'up == 0' '.metric.job + "/" + .metric.instance')"
  [[ -n "$down_targets" ]] || down_targets="none"

  guests="$(promq 'pve_up == 0' '.metric.id')"
  [[ -n "$guests" ]] || guests="none"

  firing="$(docker exec grafana wget -qO- \
    'http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules' 2>/dev/null |
    jq -r '[.data.groups[].rules[] | select(.state=="firing") | .name] | join(", ")' 2>/dev/null)"
  [[ -n "$firing" && "$firing" != "null" ]] || firing="none"

  printf '%s\n\n' "📊 ${HOSTNAME:-pi} status"
  printf 'up        : %s\n' "$up"
  printf 'load      : %s\n' "$load"
  printf 'cpu temp  : %s\n' "$temp"
  printf 'undervolt : %s this boot\n' "$undervolt"
  printf 'root disk : %s\n' "$disk"
  printf 'hdd       : %s\n' "$hdd"
  printf 'stopped   : %s\n' "$stopped"
  printf 'targets   : %s down\n' "$down_targets"
  printf 'pve guests: %s down\n' "$guests"
  printf 'alerts    : %s\n' "$firing"
}

offset=0
[[ -r "$STATE" ]] && offset="$(cat "$STATE")"

# No allowed_updates filter: its value needs quotes, and an unencoded quote in
# the URL makes curl refuse the request outright — silently, because stderr is
# discarded here. The jq select below does the same filtering anyway.
updates="$(curl -fsS -m 20 "${API}/getUpdates?offset=${offset}&timeout=0" 2>/dev/null)" || exit 0
echo "$updates" | jq -e '.ok' >/dev/null 2>&1 || exit 0

# Advance the offset even for messages we ignore, or an unrelated message sits
# at the head of the queue forever and every later /status is never seen.
last="$(echo "$updates" | jq -r '[.result[].update_id] | max // empty')"
[[ -n "$last" ]] && echo $((last + 1)) > "$STATE"

echo "$updates" | jq -r --arg chat "$TELEGRAM_CHAT_ID" \
  '.result[] | select(.message.chat.id | tostring == $chat) | .message.text // empty' 2>/dev/null |
while read -r text; do
  case "$text" in
    /status*) send "$(status_report)" ;;
    /help*)   send "Commands: /status" ;;
  esac
done
