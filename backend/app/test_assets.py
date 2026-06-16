from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from .database import DATA_DIR


TEST_ASSETS_DIR = DATA_DIR / "test_assets"
MANIFEST_JSON = TEST_ASSETS_DIR / "manifest.json"


@lru_cache(maxsize=1)
def load_manifest_entries() -> list[dict[str, Any]]:
    if not MANIFEST_JSON.exists():
        return []
    try:
        data = json.loads(MANIFEST_JSON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    entries = data.get("items") if isinstance(data, dict) else data
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]


@lru_cache(maxsize=1)
def manifest_by_relative_path() -> dict[str, dict[str, Any]]:
    return {str(entry.get("relative_path", "")).replace("\\", "/"): entry for entry in load_manifest_entries()}


def clear_manifest_cache() -> None:
    load_manifest_entries.cache_clear()
    manifest_by_relative_path.cache_clear()


def relative_to_test_assets(path: Path) -> str | None:
    try:
        return str(path.resolve().relative_to(TEST_ASSETS_DIR.resolve())).replace("\\", "/")
    except ValueError:
        return None


def test_asset_ocr_text(path: Path) -> str | None:
    relative = relative_to_test_assets(path)
    if not relative:
        return None
    entry = manifest_by_relative_path().get(relative)
    if not entry:
        return None
    text = str(entry.get("expected_ocr_text") or "").strip()
    return text or None
