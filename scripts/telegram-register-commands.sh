#!/usr/bin/env bash
#
# Register the command list with Telegram, so typing "/" in the chat pops up a
# menu instead of requiring you to remember the names.
#
# Run once, and again after changing the commands in telegram-status.sh:
#   /opt/homelab/scripts/telegram-register-commands.sh
#
# The list lives with the bot, not with the token, so revoking and replacing
# TELEGRAM_BOT_TOKEN does not wipe it. Re-run this only when the commands
# themselves change.
#
# Telegram's menu shows one line per command and cannot show arguments, so the
# descriptions here carry the argument hints that /help spells out properly.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || { echo "TELEGRAM_BOT_TOKEN not set in .env" >&2; exit 1; }

# Names must be lowercase, 1-32 chars, a-z 0-9 and underscore only.
read -r -d '' PAYLOAD <<'JSON'
{"commands":[
  {"command":"status","description":"Pi: uptime, load, temperature, disk, containers, alerts"},
  {"command":"pve","description":"Proxmox: node, guests, backups, scrape targets"},
  {"command":"room","description":"Bedroom temperature & humidity, AC state"},
  {"command":"ac","description":"Control the AC - on | off | 16-30"},
  {"command":"lamp","description":"Desk lamp - empty | mode | bright | dim | timer10 | timer30"},
  {"command":"help","description":"List every command"}
]}
JSON

# The URL carries the token, so it goes in on stdin where ps cannot read it.
# The payload is not secret and stays in argv — both cannot use stdin at once.
response="$(printf 'url = "%s"\n' \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setMyCommands" |
  curl -fsS -K - -m 15 -H 'Content-Type: application/json' -d "$PAYLOAD")" || {
    echo "request failed" >&2
    exit 1
  }

# Telegram answers 200 with ok:false for a rejected list, so the HTTP status is
# not the answer — read the body.
if echo "$response" | grep -q '"ok":true'; then
  echo "commands registered"
else
  echo "telegram rejected the list: $response" >&2
  exit 1
fi
