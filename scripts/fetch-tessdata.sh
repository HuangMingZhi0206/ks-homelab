#!/usr/bin/env bash
#
# Download the Indonesian OCR language file for Stirling-PDF.
#
# The image ships eng, deu, fra, por, chi_sim and osd, but not ind. This puts
# ind.traineddata in stirling/, which docker-compose.yml mounts into the
# container. Run it BEFORE the first `docker compose up` of the `doctools`
# profile: Docker creates a missing bind-mount source as an empty directory, and
# the container then sees a directory where it expects a file.
#
# The file comes from tesseract-ocr/tessdata_fast (smaller and faster than
# tessdata_best, at some cost in accuracy on blurry or small text). It is
# pinned to a commit and checked against a SHA-256, so a changed upstream file
# fails loudly instead of being trusted.
#
# Idempotent: does nothing when the file is already there and correct.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$REPO_ROOT/stirling"
DEST="$DEST_DIR/ind.traineddata"

COMMIT="923915d4ced2a7235221788285785a29c4a42d4a"
SHA256="69786901da87ab8766c1ea7fbb10b28f2110c14da3f6c8f2735df131fba95d88"
URL="https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/${COMMIT}/ind.traineddata"

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

check() { echo "${SHA256}  $1" | sha256sum -c --status; }

# A directory here means an earlier `up` ran first and Docker created it.
if [[ -d "$DEST" ]]; then
  err "$DEST is a directory (created by Docker). Remove it and run this again:"
  err "  docker compose --profile doctools down && rmdir '$DEST'"
  exit 1
fi

if [[ -f "$DEST" ]] && check "$DEST"; then
  ok "ind.traineddata already present and verified"
  exit 0
fi

mkdir -p "$DEST_DIR"
tmp="$(mktemp "$DEST_DIR/.ind.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

info "downloading ind.traineddata (tessdata_fast @ ${COMMIT:0:7})"
curl -fsSL --retry 3 --max-time 120 -o "$tmp" "$URL"

if ! check "$tmp"; then
  err "SHA-256 mismatch: the downloaded file is not the one this script was pinned to"
  exit 1
fi

chmod 644 "$tmp"
mv "$tmp" "$DEST"
trap - EXIT
ok "installed $DEST"
