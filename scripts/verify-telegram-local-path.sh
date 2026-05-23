#!/usr/bin/env bash
set -euo pipefail

# Verify that Hermes can read local telegram-bot-api --local absolute paths.
# Usage:
#   TELEGRAM_FILE_ID='...' ./scripts/verify-telegram-local-path.sh
# or:
#   ./scripts/verify-telegram-local-path.sh '<file_id>'

FILE_ID="${1:-${TELEGRAM_FILE_ID:-}}"
BASE_URL="${TELEGRAM_BOT_API_BASE_URL:-http://127.0.0.1:8081/bot}"
ENV_FILE="${HERMES_ENV_FILE:-$HOME/.hermes/.env}"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" && -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN is not set and was not found in $ENV_FILE" >&2
  exit 2
fi

if [[ -z "$FILE_ID" ]]; then
  echo "ERROR: pass a Telegram file_id as arg 1 or TELEGRAM_FILE_ID" >&2
  exit 2
fi

python3 - "$BASE_URL" "$TELEGRAM_BOT_TOKEN" "$FILE_ID" <<'PY'
import json
import os
import sys
from urllib.parse import urlencode
from urllib.request import urlopen

base_url, token, file_id = sys.argv[1:4]
url = f"{base_url}{token}/getFile?" + urlencode({"file_id": file_id})
with urlopen(url, timeout=30) as r:
    data = json.load(r)

safe = json.dumps(data).replace(token, "[REDACTED]")
print("getFile:", safe)

if not data.get("ok"):
    raise SystemExit("getFile returned ok=false")

path = data.get("result", {}).get("file_path")
if not path:
    raise SystemExit("getFile response has no file_path")

if os.path.isabs(path):
    print("absolute_path:", path.replace(token, "[REDACTED]"))
    if os.path.exists(path):
        st = os.stat(path)
        print("exists: yes")
        print("readable:", "yes" if os.access(path, os.R_OK) else "no")
        print("size:", st.st_size)
        if not os.access(path, os.R_OK):
            raise SystemExit("ERROR: file exists but is not readable by this process")
    else:
        print("exists: no")
        print("suggestion: bind-mount the telegram-bot-api storage so this exact absolute path exists")
        raise SystemExit(1)
else:
    print("relative_path:", path)
    print("This is not the --local absolute-path case.")
PY
