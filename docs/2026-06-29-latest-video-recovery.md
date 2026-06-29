# Recovery: find the latest Telegram video when Hermes says it cannot find it

Date: 2026-06-29

## Symptom

In a Telegram media workflow chat, the user sends a video and then asks Hermes to process it, but the agent says it cannot find the video.

This is especially likely when a long-running Telegram gateway session drops or fails to render media attachment metadata. The Telegram local Bot API storage may still contain the file even if the agent-visible conversation turn has empty text or no attachment object.

## Operator rule

Do **not** stop at “I cannot find the video” when the chat is backed by `telegram-bot-api --local`.

First inspect the local Bot API storage for the most recent video-like file, verify it with `ffprobe`, and use that absolute path as the source media for the requested video workflow.

## One-command recovery

From this runbook repo:

```bash
./scripts/find-latest-telegram-video.sh
```

Useful variants:

```bash
# Show more candidates from the last 4 hours
LIMIT=10 SINCE_MINUTES=240 ./scripts/find-latest-telegram-video.sh

# If storage was migrated or mounted elsewhere
ROOT=$HOME/.hermes/telegram-bot-api ./scripts/find-latest-telegram-video.sh
```

The script prints the real absolute path so the local Hermes process can open it. Do not paste raw output into public issues without redacting the bot-token path segment.

## Expected success signal

Example sanitized output:

```text
Found 1 video-like file(s) under /home/tankztz/.hermes/telegram-bot-api; showing 1 newest.
WARNING: paths may contain a bot-token directory; redact before sharing publicly.

#1
path: /home/tankztz/.hermes/telegram-bot-api/[REDACTED]/documents/file_65.MOV
size_bytes: 10484698
mtime: 2026-06-29 16:43:03 +0800
readable: yes
duration: 18.410998
stream_0: video codec=hevc size=720x1280
stream_1: audio codec=aac
```

If the newest candidate matches the user's send time and is readable, use that path directly for cover/caption/transcoding workflows.

## Triage checklist

1. Search recent local Bot API media:

   ```bash
   ./scripts/find-latest-telegram-video.sh
   ```

2. If no file is found, increase the time window:

   ```bash
   SINCE_MINUTES=1440 LIMIT=20 ./scripts/find-latest-telegram-video.sh
   ```

3. If the file exists but is not readable, fix path visibility/permissions using:

   ```bash
   ./scripts/verify-telegram-local-path.sh '<telegram-file-id>'
   ./scripts/setup-bind-mount.sh
   ```

4. If multiple plausible videos are equally recent, pick the one whose `mtime`, duration, and dimensions best match the user's current send. Only ask the user if the candidates remain ambiguous.

5. After using this emergency recovery path, still fix the underlying gateway/session bug: video/document/animation messages must be normalized into attachments and rendered into non-empty inbound text.

## Why this belongs in the runbook

The previous incidents fixed two lower-level problems:

- local Bot API absolute `file_path` values must be read from disk, not converted into bogus `/file/bot.../var/lib/...` URLs;
- Telegram videos or video documents must not become empty user messages when caching fails.

Those fixes are still necessary, but the operator/agent needs an immediate fallback for production media chats: when the user just sent a video, search the local Bot API media store first and proceed with the newest readable video instead of asking the user to resend.

## Pitfalls

- Do not use this as the only permanent fix. It is a recovery path for dropped attachment metadata.
- Do not expose token-bearing path segments in GitHub issues, screenshots, or chat summaries.
- Do not assume videos always live under `videos/`; iOS `.MOV` files may arrive as `documents/file_N.MOV`.
- Do not rely only on filename. Use modification time plus `ffprobe` metadata.
- Restart the gateway after deploying code/config changes; otherwise old Python code can keep dropping attachments.
