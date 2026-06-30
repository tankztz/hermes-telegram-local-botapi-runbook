# Retrospective: Telegram local Bot API `.MOV` video patch was harder than expected

Date: 2026-06-30

## Incident summary

A user sent an iOS `.MOV` video document to a Hermes Telegram group backed by a local `telegram-bot-api --local` server. Hermes initially surfaced it as an empty/near-empty user turn, then as metadata with:

```text
[Telegram video document attachment]
filename=IMG_5109.MOV
mime=video/mp4
file_size=16892257
cache_error=Not Found: method not found
```

The actual video existed on disk:

```text
~/.hermes/telegram-bot-api/[BOT_TOKEN]/documents/file_66.MOV
```

`ffprobe` verified it was valid media:

```text
duration: 24.967s
video: hevc 576x1024
audio: aac
size: 16892257 bytes
```

## Why the first patch was not smooth

There were four separate failure modes that looked like one bug:

1. **Runbook-only fix vs running gateway code**
   - The first incident updated this runbook and recovery procedure, but the live `hermes-gateway` process was still running old Python code.
   - Gateway code changes require a process restart; otherwise the same media message keeps hitting the old adapter path.

2. **PTB local Bot API download failure**
   - `python-telegram-bot` attempted `download_as_bytearray()` and failed with:

     ```text
     telegram.error.InvalidToken: Not Found: method not found
     ```

   - The file had already been saved by the local Bot API server, so retrying the HTTP download path was the wrong recovery primitive.

3. **More than one possible `file_path` shape**
   - Relative local Bot API path:

     ```text
     documents/file_66.MOV
     ```

   - Container absolute path:

     ```text
     /var/lib/telegram-bot-api/[BOT_TOKEN]/documents/file_66.MOV
     ```

   - PTB/local server URL that embeds a container absolute path:

     ```text
     http://127.0.0.1:8081/bot[TOKEN]//var/lib/telegram-bot-api/[TOKEN]/documents/file_66.MOV
     ```

   The first patch handled direct absolute/relative filesystem paths but missed the URL-with-absolute-path case. The successful fix searches the host-visible `~/.hermes/telegram-bot-api/**` tree by stable suffixes such as `documents/file_66.MOV` and `file_66.MOV`.

4. **Pure video messages need non-empty agent-visible text even if bytes fail**
   - Telegram videos often have no caption.
   - If caching fails and Hermes only passes `event.text == ""`, the agent treats it as an empty user message.
   - The adapter must always preserve video metadata in a non-empty message note, even when `media_urls` is empty.

## Correct permanent fix shape

In the Telegram adapter:

1. Wrap all PTB `download_as_bytearray()` media paths in a helper that falls back to local Bot API storage.
2. If `file_path` is relative, try:

   ```text
   ~/.hermes/telegram-bot-api/**/<relative-file-path>
   ~/.hermes/telegram-bot-api/**/<basename>
   ```

3. If `file_path` is absolute but not readable, try suffix matches under `~/.hermes/telegram-bot-api`:

   ```text
   <parent>/<basename>   # e.g. documents/file_66.MOV
   <basename>            # e.g. file_66.MOV
   ```

4. If `file_path` is a URL containing a Bot API absolute path, parse or suffix-match it rather than treating the full URL as a filesystem path.
5. For `video`, `animation`, and video-like `document` messages, inject an agent-visible note such as:

   ```text
   [Telegram video document attachment] filename=IMG_5109.MOV mime=video/mp4 file_size=16892257 cached_path=/home/.../cache/videos/video_x.mov
   ```

6. If caching still fails, keep the note and include `cache_error=...`; do not emit an empty user turn.

## Verification commands

From the Hermes source checkout:

```bash
python -m pytest tests/gateway/test_telegram_documents.py -o 'addopts=' -q
python -m pytest \
  tests/gateway/test_telegram_documents.py \
  tests/gateway/test_telegram_photo_interrupts.py \
  tests/gateway/test_session_race_guard.py \
  tests/gateway/test_media_metadata_contract.py \
  -o 'addopts=' -q
```

Observed verification after the final patch:

```text
44 passed
78 passed, 2 skipped
```

Also verify a real recent local Bot API video before/after restart:

```bash
./scripts/find-latest-telegram-video.sh
ffprobe -v error -show_entries format=duration,size:stream=codec_type,codec_name,width,height -of json /path/to/file_66.MOV
```

## Operational restart notes

- A long-running systemd `hermes-gateway` process keeps old adapter code until restarted.
- From inside a live gateway tool call, a direct `systemctl --user restart hermes-gateway` may be blocked or can kill the current tool process before completion.
- Prefer a slash-command `/restart`, `hermes gateway restart` from an external shell, or a delayed `systemd-run --user --on-active=...` restart that lets the current response finish first.

## GitHub issue triage

A related issue exists:

- https://github.com/NousResearch/hermes-agent/issues/41366 — Telegram videos cached but not exposed to the agent.

That issue does not fully cover this incident because this one is specifically about local Bot API `--local` download fallback and path normalization for `.MOV` video documents. Track/report it separately with sanitized examples of:

- `download_as_bytearray()` → `Not Found: method not found`;
- local Bot API storage file exists under `~/.hermes/telegram-bot-api/[BOT_TOKEN]/documents/file_N.MOV`;
- `file_path` may be a token-bearing local server URL containing `/var/lib/telegram-bot-api/...`;
- expected fallback is host-visible suffix lookup plus non-empty attachment metadata.

## Pitfalls for future agents

- Do not stop after documenting a workaround; verify whether the running gateway code was actually patched and restarted.
- Do not assume one `file_path` shape. Test relative, absolute, and URL-embedded absolute paths.
- Do not paste bot tokens or token-bearing paths into public GitHub issues.
- Do not treat `content: ""` as user intent when the Telegram update carried media metadata.
- Do not rely only on `file_size` or filename; verify the actual local candidate with `ffprobe`.
