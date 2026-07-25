# Hermes Telegram Local Bot API Runbook

Reproducible notes for fixing Hermes Telegram large-file downloads when using a local `telegram-bot-api --local` server.

## Incident docs

- `docs/2026-05-23-telegram-local-botapi-absolute-path.md` — absolute `getFile.file_path` from local Bot API must be read from disk or prefix-mapped, not turned into `/file/bot.../var/lib/...` URLs.
- `docs/2026-06-13-video-document-empty-message-regression.md` — regression test for Telegram `.MOV` video documents becoming empty `msg=''` turns when PTB/local Bot API download fails or metadata is dropped.
- `docs/2026-06-29-latest-video-recovery.md` — emergency/operator flow for finding the newest readable local Bot API video when a Telegram media chat says “I just sent a video” but Hermes did not receive attachment metadata.
- `docs/2026-06-30-local-botapi-video-patch-retrospective.md` — postmortem for the difficult `.MOV` video-document patch: why the first fix missed live gateway restart and URL/container-path fallback, plus the permanent test/fix shape.

## Fast recovery: latest video lookup

When the Telegram gateway drops attachment metadata, do **not** ask the user to resend before checking local Bot API storage:

```bash
./scripts/find-latest-telegram-video.sh
```

The script scans `~/.hermes/telegram-bot-api` for recent video-like files, including iOS `.MOV` files that Telegram stores under `documents/`, and verifies readable candidates with `ffprobe` when available.

## Post-update self-repair: photos and small media

Symptom: Telegram text still works, but photos or image documents fail with
`telegram.error.InvalidToken: Not Found: method not found`. This is usually not
a revoked Bot Token. It means PTB tried an invalid HTTP file URL instead of
reading the absolute path returned by local `telegram-bot-api --local`.

After a Hermes update, check whether the small-media fallback is present:

```bash
python3 ./scripts/apply-small-media-local-path-patch.py --check
```

If the check reports `status=missing`, apply the idempotent semantic patch:

```bash
python3 ./scripts/apply-small-media-local-path-patch.py
cd ~/.hermes/hermes-agent
venv/bin/python -m pytest tests/gateway/test_telegram_documents.py -o 'addopts=' -q
hermes gateway restart
```

The script supports both the current plugin adapter path and the legacy gateway
path, refuses unknown upstream shapes, compiles the changed Python file, and is
safe to run repeatedly. If upstream has changed the download implementation, it
stops for inspection instead of guessing.

Required config on Tianze's current host:

```yaml
platforms:
  telegram:
    extra:
      local_path_prefixes:
        /var/lib/telegram-bot-api: /home/tankztz/.hermes/telegram-bot-api
```

Current local Hermes repair commit (2026-07-25):

```text
f668fb5a6 fix(telegram): map local Bot API paths for small media
```

## Problem

Telegram delivered an oversized video/document to the bot, but Hermes could not download the bytes. The observed error looked like this:

```text
The document was received by Telegram, but Hermes could not download it.
Reason: raw Bot API download failed — Client error '404 Not Found' for url
'http://127.0.0.1:8081/file/bot[REDACTED]/var/lib/telegram-bot-api/[REDACTED]/documents/file_39.MOV'
Filename: IMG_3483.MOV
MIME type: video/mp4
Size: 27910368 bytes
Telegram file_id: [REDACTED]
Telegram file_unique_id: [REDACTED]
```

## Root cause

When the official Telegram Bot API is used, `getFile` returns a relative `file_path` such as:

```text
documents/file_39.MOV
```

When the local Bot API server is run with `--local`, `getFile` can return an absolute filesystem path inside the Bot API server environment:

```text
/var/lib/telegram-bot-api/[BOT_TOKEN]/documents/file_39.MOV
```

Hermes must treat that as a local filesystem path, not as an HTTP path fragment. If Hermes is running on the host and `telegram-bot-api` is running in Docker, the host must expose the same path. In this setup:

- Container path: `/var/lib/telegram-bot-api`
- Host storage path: `/home/tankztz/.openclaw/telegram-bot-api`
- Missing host path before fix: `/var/lib/telegram-bot-api`

So the code fix makes Hermes read absolute paths directly, and the deployment fix bind-mounts the host storage to the same absolute path returned by `getFile`.

## One-shot fix on the host

Run on the machine that runs Hermes:

```bash
sudo install -d -m 755 /var/lib/telegram-bot-api
sudo mount --bind /home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api
findmnt /var/lib/telegram-bot-api
```

Then verify a returned file can be read from the host:

```bash
stat /var/lib/telegram-bot-api/*/documents/file_39.MOV
```

Restart Hermes gateway:

```bash
hermes gateway restart
```

## Persistent bind mount

Add this to `/etc/fstab`:

```fstab
/home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api none bind 0 0
```

Or run:

```bash
grep -q '^/home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api ' /etc/fstab || \
  echo '/home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api none bind 0 0' | sudo tee -a /etc/fstab
```

Validate:

```bash
sudo mount -a
findmnt /var/lib/telegram-bot-api
```

## Hermes config

The local Bot API server was configured in `~/.hermes/config.yaml` like this:

```yaml
platforms:
  telegram:
    extra:
      base_url: http://127.0.0.1:8081/bot
      base_file_url: http://127.0.0.1:8081/bot
```

If root access is unavailable and the Bot API container path differs from the host path, configure a prefix mapping instead of a bind mount:

```yaml
platforms:
  telegram:
    extra:
      base_url: http://127.0.0.1:8081/bot
      base_file_url: http://127.0.0.1:8081/bot
      local_path_prefixes:
        /var/lib/telegram-bot-api: /home/tankztz/.openclaw/telegram-bot-api
```

Important: the absolute-path behavior does not rely on downloading through `/file/bot...`. In `--local` mode the returned absolute path must be readable by Hermes directly, either because the path exists via bind mount or because Hermes maps the returned prefix to a host-visible path.

## Hermes code change

Local commit in the Hermes source checkout:

```text
fa8d7ba29 fix: handle local Telegram Bot API file paths
```

Changed files:

- `gateway/platforms/telegram.py`
- `tests/gateway/test_telegram_documents.py`

Behavior added:

1. If local Bot API `getFile` returns an absolute path, Hermes reads that path directly when accessible.
2. Hermes avoids constructing invalid HTTP download URLs such as `/file/bot.../var/lib/...` for absolute local paths.
3. If the returned absolute path is not readable, Hermes returns an actionable error telling the operator to expose/mount the Bot API storage path.

Regression test:

```bash
cd /home/tankztz/.hermes/hermes-agent
python -m pytest tests/gateway/test_telegram_documents.py -q -o 'addopts='
```

Expected result from the fix session:

```text
45 passed
```

## Reproduction checklist

1. Confirm local Bot API is running with `--local`:

   ```bash
   ps -eo pid,ppid,user,group,comm,args | grep -E 'telegram-bot-api|PID' | grep -v grep
   ```

2. Confirm what `getFile` returns for the Telegram `file_id`:

   ```bash
   set -a; . ~/.hermes/.env; set +a
   curl -sS "http://127.0.0.1:8081/bot${TELEGRAM_BOT_TOKEN}/getFile" \
     --get --data-urlencode "file_id=$FILE_ID"
   ```

   Redact the token before sharing output.

3. If `file_path` starts with `/var/lib/telegram-bot-api/...`, make that path readable from the Hermes host/process:

   ```bash
   sudo install -d -m 755 /var/lib/telegram-bot-api
   sudo mount --bind /home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api
   ```

4. Verify read access:

   ```bash
   test -r /var/lib/telegram-bot-api/*/documents/file_39.MOV && echo readable
   ```

5. Restart gateway:

   ```bash
   hermes gateway restart
   ```

6. Send the same large file again in Telegram.

## Common pitfalls

- Do not paste bot tokens or full token-bearing paths in issues/docs.
- Official remote Telegram Bot API may reject oversized files with `Bad Request: file is too big`; local Bot API `--local` is still required.
- `/file/bot.../var/lib/...` returning 404 is expected in this deployment; the fix is local path visibility, not retrying URL variants.
- If Hermes runs in a container or a systemd sandbox, mount the Bot API storage into that same namespace, not just into the host root filesystem.
