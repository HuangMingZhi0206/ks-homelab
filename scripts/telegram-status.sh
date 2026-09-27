#!/usr/bin/env bash
#
# Answer /status and /pve in Telegram.
#
# Run from cron every minute:
#   * * * * * /opt/homelab/scripts/telegram-status.sh
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

send() {
  curl -fsS -m 15 --retry 2 -X POST "${API}/sendMessage" \
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
    send "⚠️ Panel kamar tidak aktif. Cek: systemctl status roomhub"
    return 1
  fi
  if ! timeout 3 sh -c 'printf "%s\n" "$1" > "$2"' _ "$1" "$FIFO"; then
    send "⚠️ Panel kamar tidak merespons. Cek: journalctl -u roomhub -n 30"
    return 1
  fi
  return 0
}

kamar_report() {
  local t h ac act age

  t="$(prom_one 'roomhub_room_temperature_celsius')"
  h="$(prom_one 'roomhub_room_humidity_percent')"
  ac="$(prom_one 'roomhub_ac_power')"
  act="$(prom_one 'roomhub_ac_target_celsius')"
  age="$(prom_one 'time() - roomhub_last_status_timestamp_seconds')"

  printf '%s\n\n' "🛏 Kamar"
  printf 'suhu      : %s\n' "$(unit "$t" ' C')"
  printf 'kelembapan: %s\n' "$(unit "$h" '%')"
  printf 'ac        : %s %s\n' \
    "$([[ "$ac" == "1" ]] && echo ON || { [[ -n "$ac" ]] && echo OFF || echo '?'; })" \
    "${act:+(set $act C)}"
  # The sensor line and the link line are separate on purpose: a missing
  # temperature with a fresh link means the DHT11 failed, not the panel.
  printf 'lapor     : %s\n' "$([[ -n "$age" ]] && awk -v a="$age" 'BEGIN{printf "%.0f detik lalu", a}' || echo 'tidak ada data')"
}

# Commands physically move things in a bedroom, so say what was sent, not what
# happened. IR is one way: the AC never confirms, and claiming it turned on
# would be a guess dressed as a fact.
ac_command() {
  local arg
  arg="$(printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"

  case "$arg" in
    on)  roomhub_send 'ACPOWER=ON'  && send "❄️ AC: perintah ON dikirim" ;;
    off) roomhub_send 'ACPOWER=OFF' && send "❄️ AC: perintah OFF dikirim" ;;
    ''|help)
      send "/ac on — nyalakan"$'\n'"/ac off — matikan"$'\n'"/ac 24 — set suhu 16-30" ;;
    *)
      if [[ "$arg" =~ ^[0-9]+$ ]] && (( arg >= 16 && arg <= 30 )); then
        roomhub_send "ACTEMP=${arg}" && send "❄️ AC: suhu ${arg} C dikirim"
      else
        send "Suhu harus 16-30. Contoh: /ac 24"
      fi ;;
  esac
}

# Index into menuLampu[] in roomhub.ino. The lamp remote only sends toggles and
# cannot report anything back, so there is no state to show — only presses.
lampu_command() {
  local arg idx
  arg="$(printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"

  case "$arg" in
    ''|on|off|toggle) idx=0 ;;
    mode)             idx=1 ;;
    terang)           idx=2 ;;
    redup)            idx=3 ;;
    timer10)          idx=4 ;;
    timer30)          idx=5 ;;
    *)
      send "/lampu — on/off"$'\n'"/lampu mode | terang | redup"$'\n'"/lampu timer10 | timer30"
      return ;;
  esac

  roomhub_send "SEND=0,${idx}" && send "💡 Lampu: perintah dikirim"
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

offset=0
[[ -r "$STATE" ]] && offset="$(cat "$STATE")"

# No allowed_updates filter: its value needs quotes, and an unencoded quote in
# the URL makes curl refuse the request outright — silently, because stderr is
# discarded here. The jq select below does the same filtering anyway.
updates="$(curl -fsS -m 20 "${API}/getUpdates?offset=${offset}&timeout=0" 2>/dev/null)" || exit 0
echo "$updates" | jq -e '.ok' >/dev/null 2>&1 || exit 0

# Advance the offset even for messages we ignore, or an unrelated message sits
# at the head of the queue forever and every later command is never seen.
last="$(echo "$updates" | jq -r '[.result[].update_id] | max // empty')"
[[ -n "$last" ]] && echo $((last + 1)) > "$STATE"

echo "$updates" | jq -r --arg chat "$TELEGRAM_CHAT_ID" \
  '.result[] | select(.message.chat.id | tostring == $chat) | .message.text // empty' 2>/dev/null |
while read -r text; do
  case "$text" in
    /status*) send "$(status_report)" ;;
    /pve*)    send "$(pve_report)" ;;
    /kamar*)  send "$(kamar_report)" ;;
    # Match on the space or end of string, so /account never reaches /ac.
    /ac|/ac\ *)       ac_command "${text#/ac}" ;;
    /lampu|/lampu\ *) lampu_command "${text#/lampu}" ;;
    /help*)
      send "/status — this Pi and its alerts"$'\n'\
"/pve — Proxmox node, guests and scrape targets"$'\n'\
"/kamar — suhu, kelembapan, status AC"$'\n'\
"/ac on|off|24 — kontrol AC"$'\n'\
"/lampu [mode|terang|redup|timer10|timer30] — lampu meja" ;;
  esac
done
