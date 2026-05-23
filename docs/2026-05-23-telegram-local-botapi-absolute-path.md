# Incident notes: IMG_3483.MOV download failure

Date: 2026-05-23

## Symptom

Hermes received Telegram metadata for `IMG_3483.MOV` but could not download bytes.

Sanitized metadata:

```text
Filename: IMG_3483.MOV
MIME type: video/mp4
Size: 27910368 bytes
Telegram file_id: [REDACTED]
Telegram file_unique_id: [REDACTED]
```

Failure shape:

```text
raw Bot API download failed — 404 Not Found for
http://127.0.0.1:8081/file/bot[REDACTED]/var/lib/telegram-bot-api/[REDACTED]/documents/file_39.MOV
```

## Findings

- Local Bot API server process:

  ```text
  telegram-bot-api --dir=/var/lib/telegram-bot-api --temp-dir=/tmp/telegram-bot-api --username=telegram-bot-api --groupname=telegram-bot-api --http-port=8081 --local
  ```

- It runs inside Docker/containerd.
- Its container mountinfo showed:

  ```text
  /home/tankztz/.openclaw/telegram-bot-api -> /var/lib/telegram-bot-api
  ```

- On the host, the actual file existed and was readable at:

  ```text
  /home/tankztz/.openclaw/telegram-bot-api/[REDACTED]/documents/file_39.MOV
  ```

- On the host, `/var/lib/telegram-bot-api` did not exist before the bind mount.
- Remote official Telegram Bot API returned `Bad Request: file is too big`; it could not be used as a fallback.

## Fixes

### Code fix

Hermes source local commit:

```text
fa8d7ba29 fix: handle local Telegram Bot API file paths
```

Tests:

```text
python -m pytest tests/gateway/test_telegram_documents.py -q -o 'addopts='
45 passed
```

Push to `NousResearch/hermes-agent.git` was blocked by permissions for `tankztz`.

### Deployment fix option A: bind mount

Expose the container path on the host:

```bash
sudo install -d -m 755 /var/lib/telegram-bot-api
sudo mount --bind /home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api
```

Persistent:

```fstab
/home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api none bind 0 0
```

### Deployment fix option B: Hermes prefix mapping

If sudo/root is not available, map the local Bot API container prefix to the host-visible storage path in `~/.hermes/config.yaml`:

```yaml
platforms:
  telegram:
    extra:
      local_path_prefixes:
        /var/lib/telegram-bot-api: /home/tankztz/.openclaw/telegram-bot-api
```

Restart Hermes gateway after changing config.

## Follow-up cleanup: move storage out of `~/.openclaw`

The Bot API Docker/containerd process was still bind-mounted from:

```text
/home/tankztz/.openclaw/telegram-bot-api -> /var/lib/telegram-bot-api
```

Because those files are owned as the container user (`messagebus:lxd` on the host) and the running bind mount cannot be retargeted by an unprivileged user, the actual migration needs root/Docker permissions. Helper script created on the host:

```bash
sudo bash /home/tankztz/.hermes/scripts/migrate-telegram-botapi-from-openclaw.sh
```

That script stops the Bot API container, moves the real storage to:

```text
/home/tankztz/.hermes/telegram-bot-api
```

then leaves a compatibility symlink at the old path so an existing Docker restart policy using the old bind source can still restart safely, updates Hermes `local_path_prefixes`, and restarts `hermes-gateway.service`.

## Verification commands

```bash
stat -c '%F %A %U:%G %n' /home/tankztz/.hermes/telegram-bot-api
readlink /home/tankztz/.openclaw/telegram-bot-api
findmnt /var/lib/telegram-bot-api
stat /home/tankztz/.hermes/telegram-bot-api/*/documents/file_39.MOV
hermes gateway restart
```

Then resend the large Telegram MOV.
