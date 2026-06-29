#!/usr/bin/env bash
set -euo pipefail

# Find the most recent Telegram local Bot API video-like file that Hermes can read.
#
# This is the emergency/operator path for the recurring failure mode where a user
# sends a Telegram video, but the long-running Hermes gateway/session records an
# empty text turn or drops attachment metadata. The file may still be present in
# telegram-bot-api --local storage.
#
# Usage:
#   ./scripts/find-latest-telegram-video.sh
#   LIMIT=10 SINCE_MINUTES=240 ./scripts/find-latest-telegram-video.sh
#   ROOT=$HOME/.hermes/telegram-bot-api ./scripts/find-latest-telegram-video.sh
#
# Output includes the real absolute path so the local Hermes process can open it.
# Do not paste raw output into public issues without redacting bot-token path
# segments first.

ROOT="${ROOT:-$HOME/.hermes/telegram-bot-api}"
LIMIT="${LIMIT:-5}"
SINCE_MINUTES="${SINCE_MINUTES:-720}"

python3 - "$ROOT" "$LIMIT" "$SINCE_MINUTES" <<'PY'
from __future__ import annotations

import json
import mimetypes
import os
import subprocess
import sys
import time
from pathlib import Path

root = Path(sys.argv[1]).expanduser()
limit = int(sys.argv[2])
since_minutes = int(sys.argv[3])

VIDEO_EXTS = {
    ".mp4",
    ".mov",
    ".m4v",
    ".webm",
    ".mkv",
    ".avi",
    ".3gp",
    ".mpeg",
    ".mpg",
}
VIDEO_DIR_NAMES = {"videos", "animations", "video_notes", "documents"}

if not root.exists():
    raise SystemExit(f"ERROR: local Bot API root does not exist: {root}")
if not root.is_dir():
    raise SystemExit(f"ERROR: local Bot API root is not a directory: {root}")

cutoff = time.time() - since_minutes * 60
candidates: list[Path] = []

for path in root.rglob("*"):
    if not path.is_file():
        continue
    suffix = path.suffix.lower()
    parent = path.parent.name.lower()
    guessed_mime = mimetypes.guess_type(path.name)[0] or ""
    if suffix not in VIDEO_EXTS and not guessed_mime.startswith("video/"):
        continue
    # Keep video-like documents; avoid wandering into unrelated cache files.
    if parent not in VIDEO_DIR_NAMES and suffix not in VIDEO_EXTS:
        continue
    try:
        st = path.stat()
    except OSError:
        continue
    if st.st_mtime < cutoff:
        continue
    candidates.append(path)

candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)

if not candidates:
    print(f"No video-like files found under {root} in the last {since_minutes} minutes.")
    print("Try increasing SINCE_MINUTES or verify telegram-bot-api --local storage is mounted where Hermes can read it.")
    raise SystemExit(1)

print(f"Found {len(candidates)} video-like file(s) under {root}; showing {min(limit, len(candidates))} newest.")
print("WARNING: paths may contain a bot-token directory; redact before sharing publicly.\n")


def ffprobe(path: Path) -> dict[str, object] | None:
    try:
        proc = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration,size:stream=codec_type,codec_name,width,height,duration",
                "-of",
                "json",
                str(path),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or f"ffprobe exit {proc.returncode}"}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"error": "ffprobe returned invalid JSON"}

for idx, path in enumerate(candidates[:limit], start=1):
    st = path.stat()
    readable = os.access(path, os.R_OK)
    print(f"#{idx}")
    print(f"path: {path}")
    print(f"size_bytes: {st.st_size}")
    print(f"mtime: {time.strftime('%Y-%m-%d %H:%M:%S %z', time.localtime(st.st_mtime))}")
    print(f"readable: {'yes' if readable else 'no'}")
    meta = ffprobe(path) if readable else None
    if meta is not None:
        if "error" in meta:
            print(f"ffprobe_error: {meta['error']}")
        else:
            fmt = meta.get("format") or {}
            streams = meta.get("streams") or []
            duration = fmt.get("duration")
            print(f"duration: {duration}")
            for s_idx, stream in enumerate(streams):
                codec_type = stream.get("codec_type")
                codec_name = stream.get("codec_name")
                width = stream.get("width")
                height = stream.get("height")
                parts = [f"stream_{s_idx}: {codec_type}", f"codec={codec_name}"]
                if width and height:
                    parts.append(f"size={width}x{height}")
                print(" ".join(parts))
    print()
PY
