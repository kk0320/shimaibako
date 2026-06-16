from __future__ import annotations

import os
from pathlib import Path

from .database import SAMPLES_DIR, connect, row_to_dict


def _candidate(path: Path, name: str, source_type: str) -> dict:
    resolved = path.expanduser()
    return {
        "name": name,
        "path": str(resolved),
        "source_type": source_type,
        "exists": resolved.exists() and resolved.is_dir(),
        "registered": False,
    }


def detect_source_candidates() -> list[dict]:
    home = Path.home()
    candidates: list[dict] = [
        _candidate(home / "Pictures" / "iCloud Photos" / "Photos", "iCloud写真", "icloud"),
        _candidate(home / "Pictures" / "iCloud Photos", "iCloud写真", "icloud"),
        _candidate(home / "iCloud Photos", "iCloud写真", "icloud"),
    ]

    onedrive_roots = []
    for key in ("OneDrive", "OneDriveConsumer", "OneDriveCommercial"):
        value = os.environ.get(key)
        if value:
            onedrive_roots.append(Path(value))
    onedrive_roots.append(home / "OneDrive")

    seen = set()
    for root in onedrive_roots:
        root_key = str(root).lower()
        if root_key in seen:
            continue
        seen.add(root_key)
        candidates.extend(
            [
                _candidate(root, "OneDrive", "onedrive"),
                _candidate(root / "Pictures", "OneDrive写真", "onedrive"),
                _candidate(root / "画像", "OneDrive画像", "onedrive"),
                _candidate(root / "写真", "OneDrive写真", "onedrive"),
            ]
        )

    candidates.append(_candidate(SAMPLES_DIR, "サンプル写真", "sample"))

    deduped: list[dict] = []
    paths = set()
    for candidate in candidates:
        key = candidate["path"].lower()
        if key not in paths:
            paths.add(key)
            deduped.append(candidate)

    with connect() as conn:
        rows = conn.execute("SELECT path FROM sources WHERE hidden = 0").fetchall()
        registered = {str(Path(row["path"])).lower() for row in rows}

    for candidate in deduped:
        candidate["registered"] = str(Path(candidate["path"])).lower() in registered
    return deduped


def ensure_sample_source() -> dict | None:
    if not SAMPLES_DIR.exists():
        return None
    now_name = "サンプル写真"
    with connect() as conn:
        existing = conn.execute(
            "SELECT * FROM sources WHERE lower(path) = lower(?) AND hidden = 0",
            (str(SAMPLES_DIR),),
        ).fetchone()
        if existing:
            return row_to_dict(existing)
        from .database import utc_now

        now = utc_now()
        cur = conn.execute(
            """
            INSERT INTO sources(name, path, source_type, enabled, hidden, created_at, updated_at)
            VALUES (?, ?, 'sample', 1, 0, ?, ?)
            """,
            (now_name, str(SAMPLES_DIR), now, now),
        )
        conn.commit()
        return row_to_dict(conn.execute("SELECT * FROM sources WHERE id = ?", (cur.lastrowid,)).fetchone())

