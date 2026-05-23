#!/usr/bin/env bash
set -euo pipefail

# Creates the host bind mount expected by Hermes when telegram-bot-api --local
# returns /var/lib/telegram-bot-api/... absolute paths.
#
# Defaults match Tianze's current deployment:
#   source: /home/tankztz/.openclaw/telegram-bot-api
#   target: /var/lib/telegram-bot-api
#
# Usage:
#   sudo ./scripts/setup-bind-mount.sh
#   SOURCE=/path/to/storage TARGET=/var/lib/telegram-bot-api sudo -E ./scripts/setup-bind-mount.sh
#
# Add PERSIST=1 to append an /etc/fstab entry.

SOURCE="${SOURCE:-/home/tankztz/.openclaw/telegram-bot-api}"
TARGET="${TARGET:-/var/lib/telegram-bot-api}"
PERSIST="${PERSIST:-0}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run with sudo/root because mount and /etc/fstab require privileges" >&2
  exit 2
fi

if [[ ! -d "$SOURCE" ]]; then
  echo "ERROR: source directory does not exist: $SOURCE" >&2
  exit 1
fi

install -d -m 755 "$TARGET"

if findmnt -rno SOURCE,TARGET "$TARGET" >/dev/null 2>&1; then
  echo "Already mounted:"
  findmnt "$TARGET"
else
  mount --bind "$SOURCE" "$TARGET"
  echo "Mounted:"
  findmnt "$TARGET"
fi

if [[ "$PERSIST" == "1" ]]; then
  line="$SOURCE $TARGET none bind 0 0"
  if grep -Fxq "$line" /etc/fstab; then
    echo "fstab already contains bind mount entry"
  else
    printf '%s\n' "$line" >> /etc/fstab
    echo "Appended to /etc/fstab: $line"
  fi
fi
