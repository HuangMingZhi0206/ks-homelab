#!/usr/bin/env bash
#
# Answer commands in Telegram: /status /pve /kamar /ac /lampu.
#
# Runs as a service, not from cron:
#   sudo cp scripts/telegram-bot.service /etc/systemd/system/
#   sudo systemctl enable --now telegram-bot
#
# It used to be a cron job firing every minute, which meant a command waited
# 30 seconds on average before anything even looked for it. Long polling holds
# one request open instead, so the reply comes back as fast as it can be built.
# Remove the cron entry when you install the service: two pollers on one bot
# steal each other's messages.
#
# Reuses TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID from .env — the same bot
# Grafana and heartbeat.sh already send through.
#
# IMPORTANT: only one process may poll getUpdates for a given bot. If you ever
# add the Telegram integration in Home Assistant, give it its own bot, or this
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

# Pass the URL on stdin, never in argv.
#
# The bot token is part of every Telegram URL, and anything in a command line
# is world-readable through ps — to any user on this box, and to anyone shown
# a process listing. It also lands in any transcript of one, which is how this
# was found. curl -K reads options from a file; "-" makes that stdin, which no
# other process can see.
curl_tg() {
  local url="$1"; shift
  printf 'url = "%s"\n' "$url" | curl -fsS -K - "$@"
}

send() {
  curl_tg "${API}/sendMessage" -m 15 --retry 2 -X POST \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null || true
}

# Prometheus is not published on the host, so ask it from inside its own
# container. The query is URL-encoded here so PromQL can be written plainly.
prom() {
  docker exec prometheus wget -qO- \
    "http://127.0.0.1:9090/api/v1/query?query=$(printf '%s' "$1" | jq -sRr @uri)" 2>/dev/null
}

# A comma-joined list built from each result element ($2 is a jq expression).
prom_list() {
  prom "$1" | jq -r "[.data.result[] | $2] | join(\", \")" 2>/dev/null
}

# A single scalar, or empty when the metric is missing.
prom_one() {
  prom "$1" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null
}

pct() { [[ -n "$1" ]] && awk -v v="$1" 'BEGIN{printf "%.0f%%", v*100}' || echo '?'; }

# A value with its unit, or "?" when the metric is missing. Distinguishing the
# two matters: "0 C" and "no reading" are very different bedrooms.
unit() { [[ -n "$1" ]] && printf '%s%s' "$1" "${2:-}" || printf '?'; }

# --- room panel --------------------------------------------------------------
#
# The Arduino in the bedroom, via roomhub/hub_kamar.py. See roomhub/README.md.

FIFO="/var/lib/roomhub/cmd"

# Opening a FIFO for writing blocks until something opens it for reading. The
# daemon holds it open, so this returns instantly while roomhub is running —
# and waits forever if it is not. This script runs from cron every minute, so
# without the timeout a stopped daemon would leave one stuck process per
# minute until the Pi ran out of them.
roomhub_send() {
  if [[ ! -p "$FIFO" ]]; then
    send "⚠️ Room panel is not running. Check: systemctl status roomhub"
    return 1
  fi
  if ! timeout 3 sh -c 'printf "%s\n" "$1" > "$2"' _ "$1" "$FIFO"; then
    send "⚠️ Room panel is not answering. Check: journalctl -u roomhub -n 30"
    return 1
  fi
  return 0
}

room_report() {
  local t h ac act age

  t="$(prom_one 'roomhub_room_temperature_celsius')"
  h="$(prom_one 'roomhub_room_humidity_percent')"
  ac="$(prom_one 'roomhub_ac_power')"
  act="$(prom_one 'roomhub_ac_target_celsius')"
  age="$(prom_one 'time() - roomhub_last_status_timestamp_seconds')"

  printf '%s\n\n' "🛏 Bedroom"
  printf 'temp     : %s\n' "$(unit "$t" ' C')"
  printf 'humidity : %s\n' "$(unit "$h" '%')"
  printf 'ac       : %s %s\n' \
    "$([[ "$ac" == "1" ]] && echo ON || { [[ -n "$ac" ]] && echo OFF || echo '?'; })" \
    "${act:+(set $act C)}"
  # The sensor line and the link line are separate on purpose: a missing
  # temperature with a fresh link means the DHT11 failed, not the panel.
  printf 'reported : %s\n' "$([[ -n "$age" ]] && awk -v a="$age" 'BEGIN{printf "%.0fs ago", a}' || echo 'no data')"
}

# Commands physically move things in a bedroom, so say what was sent, not what
# happened. IR is one way: the AC never confirms, and claiming it turned on
# would be a guess dressed as a fact.
ac_command() {
  local arg
  arg="$(printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"

  case "$arg" in
    on)  roomhub_send 'ACPOWER=ON'  && send "❄️ AC: ON sent" ;;
    off) roomhub_send 'ACPOWER=OFF' && send "❄️ AC: OFF sent" ;;
    ''|help)
      send "/ac on — turn on"$'\n'"/ac off — turn off"$'\n'"/ac 24 — set temperature, 16-30" ;;
    *)
      if [[ "$arg" =~ ^[0-9]+$ ]] && (( arg >= 16 && arg <= 30 )); then
        roomhub_send "ACTEMP=${arg}" && send "❄️ AC: ${arg} C sent"
      else
        send "Temperature must be 16-30. Example: /ac 24"
      fi ;;
  esac
}

# Index into menuLampu[] in roomhub.ino. The lamp remote only sends toggles and
# cannot report anything back, so there is no state to show — only presses.
# The Indonesian argument names still work. They were the interface for a
# while, and a command that used to work and now silently does not is worse
# than a slightly longer case statement.
lamp_command() {
  local arg idx
  arg="$(printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"

  case "$arg" in
    ''|on|off|toggle) idx=0 ;;
    mode)             idx=1 ;;
    bright|terang)    idx=2 ;;
    dim|redup)        idx=3 ;;
    timer10)          idx=4 ;;
    timer30)          idx=5 ;;
    *)
      send "/lamp — on/off"$'\n'"/lamp mode | bright | dim"$'\n'"/lamp timer10 | timer30"
      return ;;
  esac

  roomhub_send "SEND=0,${idx}" && send "💡 Lamp: command sent"
}

# Grouped, because a flat list of eleven lines is something you stop reading
# at line four. Kept in step with scripts/telegram-register-commands.sh, which
# feeds the same list to Telegram's own "/" menu.
help_text() {
  cat <<'EOF'
🤖 Commands

— Monitoring —
/status  Pi: uptime, load, temperature, disk, containers, alerts
/pve     Proxmox: node, guests, backups, scrape targets
/room    bedroom temperature & humidity, AC state

— Bedroom AC —
/ac on
/ac off
/ac 24   set temperature, 16-30

— Desk lamp —
/lamp            on/off
/lamp mode
/lamp bright
/lamp dim
/lamp timer10
/lamp timer30

/help    this list

AC and lamp commands fire IR. The reply says "sent", not "AC is on":
IR is one way and the unit never confirms.
EOF
}

status_report() {
  local up load temp undervolt disk hdd stopped firing
  up="$(uptime -p 2>/dev/null || echo '?')"
  load="$(cut -d' ' -f1-3 /proc/loadavg)"
  undervolt="$(journalctl -k -b 0 2>/dev/null | grep -ci undervolt || true)"
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

  firing="$(docker exec grafana wget -qO- \
    'http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules' 2>/dev/null |
    jq -r '[.data.groups[].rules[] | select(.state=="firing") | .name] | join(", ")' 2>/dev/null)"
  [[ -n "$firing" && "$firing" != "null" ]] || firing="none"

  printf '%s\n\n' "📊 Pi — ${HOSTNAME:-pi}"
  printf 'up        : %s\n' "$up"
  printf 'load      : %s\n' "$load"
  printf 'cpu temp  : %s\n' "$temp"
  printf 'undervolt : %s this boot\n' "${undervolt:-0}"
  printf 'root disk : %s\n' "$disk"
  printf 'hdd       : %s\n' "$hdd"
  printf 'stopped   : %s\n' "$stopped"
  printf 'alerts    : %s\n' "$firing"
}

pve_report() {
  local cpu mem_u mem_t mem running down nobackup targets

  cpu="$(pct "$(prom_one 'pve_cpu_usage_ratio{id="node/pve"}')")"
  mem_u="$(prom_one 'pve_memory_usage_bytes{id="node/pve"}')"
  mem_t="$(prom_one 'pve_memory_size_bytes{id="node/pve"}')"
  if [[ -n "$mem_u" && -n "$mem_t" && "$mem_t" != "0" ]]; then
    mem="$(awk -v u="$mem_u" -v t="$mem_t" 'BEGIN{printf "%.1f of %.1f GiB (%.0f%%)", u/1073741824, t/1073741824, u/t*100}')"
  else
    mem="?"
  fi

  running="$(prom_list 'pve_up{id=~"qemu/.*|lxc/.*"} == 1' '.metric.id')"
  [[ -n "$running" ]] || running="none"
  down="$(prom_list 'pve_up{id=~"qemu/.*|lxc/.*"} == 0' '.metric.id')"
  [[ -n "$down" ]] || down="none"

  # Proxmox counts this itself. Worth showing rather than alerting on: the
  # backups are a known gap, and an alert for something you already decided to
  # defer is just noise.
  nobackup="$(prom_one 'pve_not_backed_up_total')"

  # Anything Prometheus cannot scrape at all — the Dell itself, the switch,
  # an exporter that died.
  targets="$(prom_list 'up == 0' '.metric.job + "/" + .metric.instance')"
  [[ -n "$targets" ]] || targets="none"

  printf '%s\n\n' "🖥 Proxmox — pve"
  printf 'cpu       : %s\n' "$cpu"
  printf 'memory    : %s\n' "$mem"
  printf 'running   : %s\n' "$running"
  printf 'down      : %s\n' "$down"
  printf 'no backup : %s guests\n' "${nobackup:-?}"
  printf 'targets   : %s down\n' "$targets"
}

# Long polling: Telegram holds the request open until a message arrives or
# POLL_TIMEOUT expires, so a command is answered in about the time it takes to
# run it. Asking with timeout=0 from cron instead meant waiting for the next
# minute boundary — 30 seconds on average, and it felt broken.
#
# curl's own -m must exceed POLL_TIMEOUT, or curl gives up on a request that is
# working exactly as intended.
POLL_TIMEOUT="${POLL_TIMEOUT:-25}"

poll_once() {
  local offset updates last

  offset=0
  [[ -r "$STATE" ]] && offset="$(cat "$STATE")"

  # No allowed_updates filter: its value needs quotes, and an unencoded quote
  # in the URL makes curl refuse the request outright — silently, because
  # stderr is discarded here. The jq select below does the same filtering.
  updates="$(curl_tg "${API}/getUpdates?offset=${offset}&timeout=${POLL_TIMEOUT}" \
    -m $((POLL_TIMEOUT + 15)) 2>/dev/null)" || return 1
  echo "$updates" | jq -e '.ok' >/dev/null 2>&1 || return 1

  # Advance the offset even for messages we ignore, or an unrelated message
  # sits at the head of the queue forever and every later command is unseen.
  last="$(echo "$updates" | jq -r '[.result[].update_id] | max // empty')"
  [[ -n "$last" ]] && echo $((last + 1)) > "$STATE"

  echo "$updates" | jq -r --arg chat "$TELEGRAM_CHAT_ID" \
    '.result[] | select(.message.chat.id | tostring == $chat) | .message.text // empty' 2>/dev/null |
  while read -r text; do
  case "$text" in
    /status*) send "$(status_report)" ;;
    /pve*)    send "$(pve_report)" ;;
    # The Indonesian names stay as aliases: they are in the chat history and
    # in muscle memory, and a command that quietly stopped working would be
    # read as the bot breaking.
    /room*|/kamar*) send "$(room_report)" ;;
    # Match on the space or end of string, so /account never reaches /ac.
    /ac|/ac\ *)       ac_command "${text#/ac}" ;;
    /lamp|/lamp\ *)   lamp_command "${text#/lamp}" ;;
    /lampu|/lampu\ *) lamp_command "${text#/lampu}" ;;
    # /start is what Telegram sends the first time a chat is opened, so it is
    # the one command a person is guaranteed to send without being told.
    /help*|/start*) send "$(help_text)" ;;
    # Anything else starting with a slash is a typo or a command that no
    # longer exists. Silence would look like the bot is down.
    /*) send "Unknown command."$'\n\n'"$(help_text)" ;;
  esac
  done
}

# --once for testing and for a cron fallback. Otherwise loop forever under
# systemd (scripts/telegram-bot.service).
if [[ "${1:-}" == "--once" ]]; then
  poll_once || exit 0
  exit 0
fi

while true; do
  # A failed poll is usually the internet being briefly absent, which on a
  # home connection is not an event. Pause before retrying so an outage does
  # not turn into a request flood; a successful poll already blocked for up to
  # POLL_TIMEOUT, so it needs no pause of its own.
  poll_once || sleep 5
done
