from __future__ import annotations

import json
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT_DIR / "data"
THUMBNAIL_DIR = DATA_DIR / "thumbnails"
SAMPLES_DIR = DATA_DIR / "samples"
LOG_DIR = ROOT_DIR / "logs"
DB_PATH = DATA_DIR / "app.db"


def utc_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def ensure_directories() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    THUMBNAIL_DIR.mkdir(parents=True, exist_ok=True)
    SAMPLES_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def connect() -> sqlite3.Connection:
    ensure_directories()
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    return conn


def init_db() -> None:
    ensure_directories()
    with connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sources (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                source_type TEXT NOT NULL DEFAULT 'folder',
                enabled INTEGER NOT NULL DEFAULT 1,
                hidden INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_scan_at TEXT
            );

            CREATE TABLE IF NOT EXISTS media_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id INTEGER NOT NULL,
                source_name TEXT NOT NULL,
                file_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                parent_dir TEXT NOT NULL,
                extension TEXT NOT NULL,
                media_type TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                created_at TEXT,
                modified_at TEXT,
                taken_at TEXT,
                width INTEGER,
                height INTEGER,
                file_hash TEXT,
                thumbnail_path TEXT,
                scan_status TEXT NOT NULL,
                error_message TEXT,
                indexed_at TEXT NOT NULL,
                created_ts REAL,
                modified_ts REAL,
                ocr_text TEXT,
                ocr_status TEXT NOT NULL DEFAULT 'pending',
                ocr_error TEXT,
                ocr_engine TEXT,
                ocr_language TEXT,
                ocr_indexed_at TEXT,
                inferred_category TEXT NOT NULL DEFAULT 'misc',
                FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE,
                UNIQUE (source_id, file_path)
            );

            CREATE INDEX IF NOT EXISTS idx_media_source ON media_items(source_id);
            CREATE INDEX IF NOT EXISTS idx_media_file_name ON media_items(file_name);
            CREATE INDEX IF NOT EXISTS idx_media_ext ON media_items(extension);
            CREATE INDEX IF NOT EXISTS idx_media_type ON media_items(media_type);
            CREATE INDEX IF NOT EXISTS idx_media_taken ON media_items(taken_at);
            CREATE INDEX IF NOT EXISTS idx_media_hash ON media_items(file_hash);
            CREATE INDEX IF NOT EXISTS idx_sources_path ON sources(path);
            """
        )
        migrate_db(conn)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_media_ocr_status ON media_items(ocr_status)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_media_category ON media_items(inferred_category)")
        set_default_settings(conn)
        conn.commit()


def set_default_settings(conn: sqlite3.Connection) -> None:
    defaults = {
        "thumbnail_long_edge": 300,
        "scan_read_only": True,
        "allow_external_cloud_api": False,
        "app_name": "しまい箱",
        "scan_max_items": 0,
        "ocr_max_items": 50,
        "exclude_dirs": [".git", "node_modules", ".venv", "__pycache__", "data/thumbnails"],
        "exclude_extensions": [],
        "regenerate_thumbnails": False,
        "hash_mode": "full",
        "ocr_enabled_by_default": False,
    }
    now = utc_now()
    for key, value in defaults.items():
        conn.execute(
            """
            INSERT OR IGNORE INTO settings(key, value, updated_at)
            VALUES (?, ?, ?)
            """,
            (key, json.dumps(value, ensure_ascii=False), now),
        )


def migrate_db(conn: sqlite3.Connection) -> None:
    existing = {row["name"] for row in conn.execute("PRAGMA table_info(media_items)").fetchall()}
    columns = {
        "ocr_text": "TEXT",
        "ocr_status": "TEXT NOT NULL DEFAULT 'pending'",
        "ocr_error": "TEXT",
        "ocr_engine": "TEXT",
        "ocr_language": "TEXT",
        "ocr_indexed_at": "TEXT",
        "inferred_category": "TEXT NOT NULL DEFAULT 'misc'",
    }
    for name, definition in columns.items():
        if name not in existing:
            conn.execute(f"ALTER TABLE media_items ADD COLUMN {name} {definition}")


def row_to_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return {key: row[key] for key in row.keys()}


def rows_to_dicts(rows: list[sqlite3.Row]) -> list[dict[str, Any]]:
    return [{key: row[key] for key in row.keys()} for row in rows]
