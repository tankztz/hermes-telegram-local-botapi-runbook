# Security notes

This repository intentionally avoids storing secrets.

Do not commit:

- Telegram bot token
- Full `file_id` values if they are not needed
- Full token-bearing `file_path` values
- `~/.hermes/.env`
- Gateway logs containing credentials or user content

Use `[REDACTED]` in documentation and examples.

The bind mount command itself is safe to document because it only references host directories and not credentials:

```bash
sudo mount --bind /home/tankztz/.openclaw/telegram-bot-api /var/lib/telegram-bot-api
```
