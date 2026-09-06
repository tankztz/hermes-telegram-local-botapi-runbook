#!/usr/bin/env python3
"""Idempotently restore local Bot API path mapping for Hermes small media."""

from __future__ import annotations

import argparse
import py_compile
import sys
from pathlib import Path

ADAPTER_PATHS = (
    Path("plugins/platforms/telegram/adapter.py"),
    Path("gateway/platforms/telegram.py"),
)
MARKER = "async def _download_telegram_file_bytes(self, file_obj: Any) -> bytes:"
DIRECT_DOWNLOAD = "await file_obj.download_as_bytearray()"
MAPPED_DOWNLOAD = "await self._download_telegram_file_bytes(file_obj)"
ANCHOR = '''    @staticmethod
    def _append_observed_note(existing: Optional[str], note: str) -> str:
        if not note:
            return existing or ""
        if not existing:
            return note
        return f"{existing}\\n\\n{note}"
'''
HELPER = '''
    async def _download_telegram_file_bytes(self, file_obj: Any) -> bytes:
        """Read Telegram media through configured local Bot API path mappings."""
        raw_path = getattr(file_obj, "file_path", None)
        mappings = self.config.extra.get("local_path_prefixes", {})
        if isinstance(raw_path, str) and isinstance(mappings, dict):
            for remote_prefix, local_prefix in mappings.items():
                if not isinstance(remote_prefix, str) or not isinstance(local_prefix, str):
                    continue
                index = raw_path.find(remote_prefix)
                if index < 0:
                    continue
                suffix = raw_path[index + len(remote_prefix):].lstrip("/\\\\")
                local_root = os.path.realpath(os.path.expanduser(local_prefix))
                candidate = os.path.realpath(os.path.join(local_root, suffix))
                try:
                    if os.path.commonpath((local_root, candidate)) != local_root:
                        continue
                except ValueError:
                    continue
                if os.path.isfile(candidate) and os.access(candidate, os.R_OK):
                    with open(candidate, "rb") as handle:
                        return handle.read()

        return bytes(await file_obj.download_as_bytearray())
'''


def find_adapter(root: Path) -> Path:
    for rel in ADAPTER_PATHS:
        candidate = root / rel
        if candidate.is_file():
            return candidate
    raise SystemExit(f"ERROR: Telegram adapter not found under {root}")


def status(text: str) -> str:
    if MARKER in text:
        direct_count = text.count(DIRECT_DOWNLOAD)
        mapped_count = text.count(MAPPED_DOWNLOAD)
        if direct_count == 1 and mapped_count >= 2:
            return "patched"
        return f"incomplete (direct={direct_count}, mapped={mapped_count})"
    if DIRECT_DOWNLOAD in text:
        return "missing"
    return "upstream-changed"


def apply_patch(path: Path) -> bool:
    original = path.read_text(encoding="utf-8")
    state = status(original)
    if state == "patched":
        print(f"OK: already patched: {path}")
        return False
    if state == "upstream-changed":
        raise SystemExit(
            "ERROR: upstream download code changed; inspect before patching rather than guessing"
        )
    if state.startswith("incomplete"):
        raise SystemExit(f"ERROR: existing helper is incomplete: {state}")
    if original.count(ANCHOR) == 1:
        updated = original.replace(ANCHOR, ANCHOR + HELPER, 1)
    else:
        # Newer adapters moved _append_observed_note to a mixin.
        init_anchor = "    def __init__(self, config: PlatformConfig):\n"
        if original.count(init_anchor) != 1:
            raise SystemExit("ERROR: insertion anchor missing or ambiguous; no files changed")
        updated = original.replace(init_anchor, HELPER + "\n" + init_anchor, 1)
    updated = updated.replace(DIRECT_DOWNLOAD, MAPPED_DOWNLOAD)
    helper_recursive = "return bytes(await self._download_telegram_file_bytes(file_obj))"
    helper_fallback = "return bytes(await file_obj.download_as_bytearray())"
    if updated.count(helper_recursive) != 1:
        raise SystemExit("ERROR: helper fallback replacement was not unique; no files changed")
    updated = updated.replace(helper_recursive, helper_fallback, 1)

    if status(updated) != "patched":
        raise SystemExit(f"ERROR: post-patch validation failed: {status(updated)}")
    path.write_text(updated, encoding="utf-8")
    py_compile.compile(str(path), doraise=True)
    print(f"PATCHED: {path}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.home() / ".hermes" / "hermes-agent",
        help="Hermes source checkout",
    )
    parser.add_argument("--check", action="store_true", help="check only; do not modify")
    args = parser.parse_args()

    adapter = find_adapter(args.root.expanduser().resolve())
    current = status(adapter.read_text(encoding="utf-8"))
    print(f"status={current} adapter={adapter}")
    if args.check:
        return 0 if current == "patched" else 1
    apply_patch(adapter)
    return 0


if __name__ == "__main__":
    sys.exit(main())
