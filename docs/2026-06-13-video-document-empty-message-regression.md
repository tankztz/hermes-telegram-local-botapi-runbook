# Regression: Telegram local Bot API video document becomes empty message

Date: 2026-06-13

## Symptom

A user sent a Telegram video in a Hermes group chat, then asked Hermes to process it. The gateway log showed the incoming turn as an empty message:

```text
[Telegram] Failed to cache document: Not Found: method not found
inbound message: platform=telegram user=... chat=... msg=''
```

Local Bot API storage still contained the actual video file:

```text
~/.hermes/telegram-bot-api/[BOT_TOKEN]/documents/file_54.MOV
```

`ffprobe` showed it was a valid QuickTime/MOV video:

```text
video: hevc, 720x1280, duration ~33.8s
audio: aac
size: ~13.9 MB
```

So this is not an empty user intent. It is a Telegram media normalization / observability bug.

## Root cause pattern

There are two related failure modes to guard against:

1. PTB `download_as_bytearray()` can fail against a local `telegram-bot-api --local` server with:

   ```text
   Not Found: method not found
   ```

2. When Hermes falls back to raw local Bot API file resolution, video/document metadata must survive even if the raw bytes cannot be cached. For oversized `.MOV` documents, Hermes must preserve both:

   - the cache path, when caching succeeds;
   - the local Bot API source path, when `getFile` returns a host-visible local file.

If the adapter emits only `event.text == ""` without a `video_document` attachment, the agent receives an empty user turn and answers as if no video was sent.

## Minimal regression test

Add an adapter-level test in Hermes:

```python
@pytest.mark.asyncio
async def test_oversized_mov_document_raw_download_preserves_local_path(adapter):
    """Local Bot API .MOV documents must reach the agent as video attachments, not empty text."""
    mov_bytes = b"ftypqt  fake mov bytes"
    local_path = "/host/telegram-bot-api/token/documents/file_54.MOV"
    doc = _make_document(
        file_name="file_54.MOV",
        mime_type="video/quicktime",
        file_size=25 * 1024 * 1024,
    )
    msg = _make_message(document=doc)
    update = _make_update(msg)

    with patch.object(
        adapter,
        "_download_telegram_file_raw",
        AsyncMock(return_value=(mov_bytes, local_path)),
    ) as raw_mock:
        await adapter._handle_media_message(update, MagicMock())

    raw_mock.assert_awaited_once_with("telegram-file-id-123")
    doc.get_file.assert_not_awaited()
    event = adapter.handle_message.call_args[0][0]
    assert event.text == ""
    assert event.message_type == MessageType.VIDEO
    assert event.media_urls and event.media_urls[0].endswith(".mov")
    assert event.media_types == ["video/quicktime"]
    assert event.attachments
    attachment = event.attachments[0]
    assert attachment["type"] == "video_document"
    assert attachment["filename"] == "file_54.MOV"
    assert attachment["mime_type"] == "video/quicktime"
    assert attachment["cache_path"] == event.media_urls[0]
    assert attachment["local_path"] == local_path
    assert attachment["path"] == event.media_urls[0]
```

This test fails against the buggy implementation because `attachment["local_path"]` is `None`.

## Fix shape

In `gateway/platforms/telegram.py`, make the oversized document path call the lower-level raw downloader directly so the source path is retained:

```python
source_path = None
try:
    raw_bytes, source_path = await self._download_telegram_file_raw(file_id)
except Exception as dl_err:
    ...
```

When the oversized document is recognized as a video and cached, pass `source_path` into the attachment metadata:

```python
self._set_telegram_video_attachment(
    event,
    doc,
    media_kind="video_document",
    filename=original_filename,
    mime_type=event.media_types[0],
    cache_path=cached_path,
    source_path=source_path,
)
```

In `gateway/run.py`, make the inbound log include media/attachment counts so `msg=''` is not misread as an empty user message:

```text
inbound message: platform=telegram user=... chat=... msg='' media=1 attachments=1 attachment_types=['video_document']
```

## Verification

Run the focused regression suite from the Hermes source checkout:

```bash
cd ~/.hermes/hermes-agent
python -m pytest \
  tests/gateway/test_telegram_documents.py \
  tests/gateway/test_inbound_media_text.py \
  tests/gateway/test_session_race_guard.py \
  -o 'addopts=' -q
```

Expected result from the fix session:

```text
74 passed
```

Also verify the specific red/green test:

```bash
python -m pytest \
  tests/gateway/test_telegram_documents.py::TestDocumentDownloadBlock::test_oversized_mov_document_raw_download_preserves_local_path \
  -o 'addopts=' -q
```

Expected after the fix:

```text
1 passed
```

## Operational checks

Check for real local Bot API files without exposing the token:

```bash
python - <<'PY'
from pathlib import Path
root = Path.home() / '.hermes/telegram-bot-api'
for f in sorted(root.rglob('documents/file_*.MOV'), key=lambda p: p.stat().st_mtime, reverse=True)[:5]:
    redacted = str(f).replace(next(part for part in str(f).split('/') if ':' in part and part[0].isdigit()), '<bot-token>')
    print(redacted, f.stat().st_size)
PY
```

Probe the newest file:

```bash
ffprobe -v error \
  -show_entries format=duration,size:stream=codec_type,codec_name,width,height,duration \
  -of json /path/to/redacted/documents/file_54.MOV
```

After deploying code changes, restart the gateway so the long-running process loads the new code:

```bash
systemctl --user restart hermes-gateway.service
systemctl --user status hermes-gateway.service --no-pager
```

Then send a video-only Telegram message. The log should no longer make it look like a bare empty message; it should show a nonzero media or attachment count.

## Pitfalls

- Do not rely only on `event.text` for Telegram media messages. Pure video messages often have no caption.
- Do not drop metadata when byte caching fails. The agent still needs file id, filename, MIME type, size, duration, dimensions, and any local path.
- Restart the gateway after code changes. A systemd Hermes gateway can keep running old Python code for days.
- Redact bot tokens and token-bearing local paths before sharing logs.
