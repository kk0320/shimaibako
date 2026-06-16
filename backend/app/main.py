from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .auth import access_mode, auth_required, require_auth, verify_pin
from .classification import CATEGORIES, normalize_category
from .database import DATA_DIR, DB_PATH, LOG_DIR, SAMPLES_DIR, connect, init_db, row_to_dict, rows_to_dicts, utc_now
from .detection import detect_source_candidates, ensure_sample_source
from .ocr import OcrManager, OcrOptions, normalize_ocr_language, ocr_capabilities
from .sample_data import generate_samples
from .scanner import ScanManager, heif_status, load_scan_options, scan_state, ensure_placeholders


app = FastAPI(title="しまい箱", version="0.1.0")
scan_manager = ScanManager()
ocr_manager = OcrManager()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def auth_middleware(request, call_next):
    public_paths = {"/api/health", "/api/auth/login"}
    if request.url.path.startswith("/api/") and request.url.path not in public_paths:
        try:
            await require_auth(request)
        except HTTPException as exc:
            return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
    return await call_next(request)


class SettingsPayload(BaseModel):
    settings: dict[str, Any] = Field(default_factory=dict)


class AuthLoginPayload(BaseModel):
    pin: str


class SourceCreate(BaseModel):
    name: str | None = None
    path: str
    source_type: str = "folder"
    enabled: bool = True


class SourcePatch(BaseModel):
    name: str | None = None
    path: str | None = None
    source_type: str | None = None
    enabled: bool | None = None
    hidden: bool | None = None


class ScanStartPayload(BaseModel):
    source_ids: list[int] | None = None
    include_disabled: bool = False
    max_items: int | None = None
    exclude_dirs: list[str] | None = None
    exclude_extensions: list[str] | None = None
    regenerate_thumbnails: bool | None = None
    hash_mode: str | None = None
    dry_run: bool = False


class OcrStartPayload(BaseModel):
    mode: str = "screenshot"
    source_id: int | None = None
    max_items: int = 50
    retry_errors: bool = False
    reprocess_done: bool = False
    language: str = "jpn+eng"


class ResetPayload(BaseModel):
    confirm: bool = False
    keep_sources: bool = True


def source_display_name(path: Path, source_type: str, supplied: str | None = None) -> str:
    if supplied and supplied.strip():
        return supplied.strip()
    if source_type == "icloud":
        return "iCloud写真"
    if source_type == "onedrive":
        return "OneDrive写真"
    if source_type == "sample":
        return "サンプル写真"
    return path.name or str(path)


def source_row(source_id: int) -> dict:
    with connect() as conn:
        row = conn.execute("SELECT * FROM sources WHERE id = ?", (source_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Source not found")
    return row_to_dict(row)


@app.on_event("startup")
def startup() -> None:
    init_db()
    ensure_placeholders()
    if any(SAMPLES_DIR.glob("*")):
        ensure_sample_source()


@app.get("/api/health")
def health() -> dict:
    return {
        "ok": True,
        "access_mode": access_mode(),
        "auth_required": auth_required(),
        "app": "しまい箱",
    }


@app.post("/api/auth/login")
def auth_login(payload: AuthLoginPayload) -> dict:
    token = verify_pin(payload.pin)
    return {"token": token, "access_mode": access_mode(), "auth_required": auth_required()}


@app.get("/api/settings")
def get_settings() -> dict:
    with connect() as conn:
        rows = conn.execute("SELECT key, value, updated_at FROM settings ORDER BY key").fetchall()
    settings = {}
    updated_at = {}
    for row in rows:
        try:
            settings[row["key"]] = json.loads(row["value"])
        except json.JSONDecodeError:
            settings[row["key"]] = row["value"]
        updated_at[row["key"]] = row["updated_at"]
    return {"settings": settings, "updated_at": updated_at}


@app.post("/api/settings")
def post_settings(payload: SettingsPayload) -> dict:
    now = utc_now()
    with connect() as conn:
        for key, value in payload.settings.items():
            conn.execute(
                """
                INSERT INTO settings(key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """,
                (key, json.dumps(value, ensure_ascii=False), now),
            )
        conn.commit()
    return get_settings()


@app.get("/api/sources")
def get_sources(include_hidden: bool = False) -> dict:
    where = "" if include_hidden else "WHERE hidden = 0"
    with connect() as conn:
        rows = conn.execute(f"SELECT * FROM sources {where} ORDER BY id").fetchall()
    return {"sources": rows_to_dicts(rows)}


@app.post("/api/sources")
def create_source(payload: SourceCreate) -> dict:
    path = Path(payload.path).expanduser()
    if not path.exists() or not path.is_dir():
        raise HTTPException(status_code=400, detail="Folder does not exist")
    now = utc_now()
    name = source_display_name(path, payload.source_type, payload.name)
    with connect() as conn:
        existing = conn.execute(
            "SELECT * FROM sources WHERE lower(path) = lower(?) AND hidden = 0",
            (str(path),),
        ).fetchone()
        if existing:
            return {"source": row_to_dict(existing), "created": False}
        cur = conn.execute(
            """
            INSERT INTO sources(name, path, source_type, enabled, hidden, created_at, updated_at)
            VALUES (?, ?, ?, ?, 0, ?, ?)
            """,
            (name, str(path), payload.source_type, 1 if payload.enabled else 0, now, now),
        )
        conn.commit()
        created = conn.execute("SELECT * FROM sources WHERE id = ?", (cur.lastrowid,)).fetchone()
    return {"source": row_to_dict(created), "created": True}


@app.patch("/api/sources/{source_id}")
def patch_source(source_id: int, payload: SourcePatch) -> dict:
    current = source_row(source_id)
    fields = []
    params: list[Any] = []
    if payload.path is not None:
        path = Path(payload.path).expanduser()
        if not path.exists() or not path.is_dir():
            raise HTTPException(status_code=400, detail="Folder does not exist")
        fields.append("path = ?")
        params.append(str(path))
    if payload.name is not None:
        fields.append("name = ?")
        params.append(payload.name.strip() or current["name"])
    if payload.source_type is not None:
        fields.append("source_type = ?")
        params.append(payload.source_type)
    if payload.enabled is not None:
        fields.append("enabled = ?")
        params.append(1 if payload.enabled else 0)
    if payload.hidden is not None:
        fields.append("hidden = ?")
        params.append(1 if payload.hidden else 0)
    if not fields:
        return {"source": current}
    fields.append("updated_at = ?")
    params.append(utc_now())
    params.append(source_id)
    with connect() as conn:
        conn.execute(f"UPDATE sources SET {', '.join(fields)} WHERE id = ?", params)
        conn.commit()
        row = conn.execute("SELECT * FROM sources WHERE id = ?", (source_id,)).fetchone()
    return {"source": row_to_dict(row)}


@app.delete("/api/sources/{source_id}")
def delete_source(source_id: int) -> dict:
    source_row(source_id)
    with connect() as conn:
        conn.execute("DELETE FROM sources WHERE id = ?", (source_id,))
        conn.commit()
    return {"deleted": True, "message": "DB上の登録だけを削除しました。元フォルダや元ファイルは変更していません。"}


@app.post("/api/sources/detect")
def detect_sources() -> dict:
    return {"candidates": detect_source_candidates()}


@app.post("/api/scan/start")
def scan_start(payload: ScanStartPayload = ScanStartPayload()) -> dict:
    options = load_scan_options(
        source_ids=payload.source_ids,
        include_disabled=payload.include_disabled,
        max_items=payload.max_items,
        exclude_dirs=payload.exclude_dirs,
        exclude_extensions=payload.exclude_extensions,
        regenerate_thumbnails=payload.regenerate_thumbnails,
        hash_mode=payload.hash_mode,
        dry_run=payload.dry_run,
    )
    return scan_manager.start(options)


@app.post("/api/scan/estimate")
def scan_estimate(payload: ScanStartPayload = ScanStartPayload()) -> dict:
    payload.dry_run = True
    return scan_start(payload)


@app.post("/api/scan/cancel")
def scan_cancel() -> dict:
    return scan_manager.cancel()


@app.get("/api/scan/status")
def scan_status() -> dict:
    return scan_manager.status()


@app.post("/api/ocr/start")
def ocr_start(payload: OcrStartPayload = OcrStartPayload()) -> dict:
    mode = payload.mode if payload.mode in {"all", "screenshot", "image", "unprocessed", "errors"} else "screenshot"
    max_items = max(1, min(int(payload.max_items or 50), 10000))
    language = normalize_ocr_language(payload.language)
    return ocr_manager.start(
        OcrOptions(
            mode=mode,
            source_id=payload.source_id,
            max_items=max_items,
            retry_errors=payload.retry_errors,
            reprocess_done=payload.reprocess_done,
            language=language,
        )
    )


@app.get("/api/ocr/status")
def ocr_status() -> dict:
    return ocr_manager.status()


@app.post("/api/ocr/cancel")
def ocr_cancel() -> dict:
    return ocr_manager.cancel()


@app.get("/api/ocr/items/{item_id}")
def ocr_item(item_id: int) -> dict:
    with connect() as conn:
        row = conn.execute(
            "SELECT id, file_name, file_path, ocr_text, ocr_status, ocr_error, ocr_engine, ocr_language, ocr_indexed_at FROM media_items WHERE id = ?",
            (item_id,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Item not found")
    return {"ocr": row_to_dict(row)}


def _search_where(
    q: str | None,
    source_id: int | None,
    date_from: str | None,
    date_to: str | None,
    media_type: str | None,
    extension: str | None,
    screenshot: bool,
    category: str | None,
    duplicates: bool,
    missing_thumbnail: bool,
    has_error: bool,
    ocr_status: str | None,
    ocr_error: bool,
) -> tuple[str, list[Any]]:
    where = ["s.hidden = 0"]
    params: list[Any] = []
    if q:
        like = f"%{q.strip()}%"
        where.append("(m.file_name LIKE ? OR m.parent_dir LIKE ? OR m.source_name LIKE ? OR m.extension LIKE ? OR COALESCE(m.ocr_text, '') LIKE ? OR COALESCE(m.inferred_category, '') LIKE ?)")
        params.extend([like, like, like, like, like, like])
    if source_id:
        where.append("m.source_id = ?")
        params.append(source_id)
    if date_from:
        where.append("COALESCE(m.taken_at, m.created_at, m.modified_at) >= ?")
        params.append(f"{date_from}T00:00:00")
    if date_to:
        where.append("COALESCE(m.taken_at, m.created_at, m.modified_at) <= ?")
        params.append(f"{date_to}T23:59:59")
    if media_type in {"image", "video"}:
        where.append("m.media_type = ?")
        params.append(media_type)
    if extension:
        extensions = [item.strip().lower().lstrip(".") for item in extension.split(",") if item.strip()]
        if extensions:
            where.append(f"m.extension IN ({','.join('?' for _ in extensions)})")
            params.extend(extensions)
    if screenshot:
        where.append(
            "(lower(m.file_name) LIKE '%screenshot%' OR lower(m.file_name) LIKE '%screen shot%' OR m.file_name LIKE '%スクリーンショット%' OR m.file_name LIKE '%スクショ%' OR lower(m.parent_dir) LIKE '%screenshot%' OR (m.height >= 1200 AND m.width >= 600 AND CAST(m.height AS REAL) / m.width >= 1.65))"
        )
    normalized_category = normalize_category(category)
    if normalized_category:
        where.append("COALESCE(m.inferred_category, 'misc') = ?")
        params.append(normalized_category)
    if duplicates:
        where.append(
            "m.file_hash IN (SELECT file_hash FROM media_items WHERE file_hash IS NOT NULL GROUP BY file_hash HAVING COUNT(*) > 1)"
        )
    if missing_thumbnail:
        where.append("(m.thumbnail_path IS NULL OR m.thumbnail_path = '')")
    if has_error:
        where.append("(m.scan_status <> 'indexed' OR m.error_message IS NOT NULL)")
    if ocr_status in {"pending", "processing", "done", "error", "skipped"}:
        where.append("COALESCE(m.ocr_status, 'pending') = ?")
        params.append(ocr_status)
    if ocr_error:
        where.append("COALESCE(m.ocr_status, 'pending') = 'error'")
    return " AND ".join(where), params


@app.get("/api/search")
def search(
    q: str | None = None,
    source_id: int | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    media_type: str | None = None,
    extension: str | None = None,
    screenshot: bool = False,
    category: str | None = None,
    duplicates: bool = False,
    missing_thumbnail: bool = False,
    has_error: bool = False,
    ocr_status: str | None = None,
    ocr_error: bool = False,
    limit: int = Query(60, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> dict:
    where, params = _search_where(q, source_id, date_from, date_to, media_type, extension, screenshot, category, duplicates, missing_thumbnail, has_error, ocr_status, ocr_error)
    with connect() as conn:
        total = conn.execute(
            f"SELECT COUNT(*) AS count FROM media_items m JOIN sources s ON s.id = m.source_id WHERE {where}",
            params,
        ).fetchone()["count"]
        rows = conn.execute(
            f"""
            SELECT m.*
            FROM media_items m
            JOIN sources s ON s.id = m.source_id
            WHERE {where}
            ORDER BY COALESCE(m.taken_at, m.created_at, m.modified_at) DESC, m.id DESC
            LIMIT ? OFFSET ?
            """,
            params + [limit, offset],
        ).fetchall()
    return {"items": rows_to_dicts(rows), "total": total, "limit": limit, "offset": offset}


@app.get("/api/items/{item_id}")
def get_item(item_id: int) -> dict:
    with connect() as conn:
        row = conn.execute(
            """
            SELECT m.*, s.path AS source_path, s.source_type
            FROM media_items m
            JOIN sources s ON s.id = m.source_id
            WHERE m.id = ?
            """,
            (item_id,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Item not found")
    return {"item": row_to_dict(row)}


def _safe_data_file(relative_path: str | None, fallback: str = "image") -> Path:
    ensure_placeholders()
    if relative_path:
        candidate = (DATA_DIR / relative_path).resolve()
        data_root = DATA_DIR.resolve()
        if str(candidate).lower().startswith(str(data_root).lower()) and candidate.exists() and candidate.is_file():
            return candidate
    return DATA_DIR / "thumbnails" / f"_placeholder_{fallback}.jpg"


@app.get("/api/items/{item_id}/thumbnail")
def get_thumbnail(item_id: int) -> FileResponse:
    with connect() as conn:
        row = conn.execute("SELECT thumbnail_path, media_type, scan_status FROM media_items WHERE id = ?", (item_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Item not found")
    fallback = "video" if row["media_type"] == "video" else "error" if row["scan_status"] != "indexed" else "image"
    path = _safe_data_file(row["thumbnail_path"], fallback)
    return FileResponse(path, media_type="image/jpeg")


@app.get("/api/duplicates")
def duplicates(limit: int = Query(50, ge=1, le=200)) -> dict:
    with connect() as conn:
        hashes = conn.execute(
            """
            SELECT file_hash, COUNT(*) AS count, SUM(size_bytes) AS total_size
            FROM media_items
            WHERE file_hash IS NOT NULL
            GROUP BY file_hash
            HAVING COUNT(*) > 1
            ORDER BY count DESC, total_size DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        groups = []
        for row in hashes:
            items = conn.execute(
                """
                SELECT *
                FROM media_items
                WHERE file_hash = ?
                ORDER BY source_name, file_name
                """,
                (row["file_hash"],),
            ).fetchall()
            groups.append(
                {
                    "file_hash": row["file_hash"],
                    "count": row["count"],
                    "total_size": row["total_size"],
                    "items": rows_to_dicts(items),
                }
            )
    return {"groups": groups}


@app.get("/api/stats")
def stats() -> dict:
    with connect() as conn:
        total = conn.execute("SELECT COUNT(*) AS count FROM media_items").fetchone()["count"]
        errors = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE scan_status <> 'indexed' OR error_message IS NOT NULL").fetchone()["count"]
        thumbnails = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE thumbnail_path IS NOT NULL AND thumbnail_path <> ''").fetchone()["count"]
        ocr_done = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE ocr_status = 'done'").fetchone()["count"]
        ocr_pending = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE COALESCE(ocr_status, 'pending') = 'pending'").fetchone()["count"]
        ocr_errors = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE ocr_status = 'error'").fetchone()["count"]
        ocr_real_done = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE ocr_status = 'done' AND ocr_engine = 'tesseract'").fetchone()["count"]
        ocr_test_fallback_done = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE ocr_status = 'done' AND ocr_engine = 'test_asset_fallback'").fetchone()["count"]
        ocr_sample_fallback_done = conn.execute("SELECT COUNT(*) AS count FROM media_items WHERE ocr_status = 'done' AND ocr_engine = 'sample_fallback'").fetchone()["count"]
        sources = conn.execute(
            """
            SELECT s.*, COUNT(m.id) AS item_count
            FROM sources s
            LEFT JOIN media_items m ON m.source_id = s.id
            WHERE s.hidden = 0
            GROUP BY s.id
            ORDER BY s.id
            """
        ).fetchall()
        by_type = conn.execute("SELECT media_type, COUNT(*) AS count FROM media_items GROUP BY media_type ORDER BY media_type").fetchall()
        by_ext = conn.execute("SELECT extension, COUNT(*) AS count FROM media_items GROUP BY extension ORDER BY count DESC, extension").fetchall()
        by_category = conn.execute("SELECT COALESCE(inferred_category, 'misc') AS inferred_category, COUNT(*) AS count FROM media_items GROUP BY COALESCE(inferred_category, 'misc') ORDER BY count DESC, inferred_category").fetchall()
        by_ocr_engine = conn.execute("SELECT COALESCE(ocr_engine, 'not_processed') AS ocr_engine, COUNT(*) AS count FROM media_items GROUP BY COALESCE(ocr_engine, 'not_processed') ORDER BY count DESC, ocr_engine").fetchall()
        by_ocr_language = conn.execute("SELECT COALESCE(ocr_language, '-') AS ocr_language, COUNT(*) AS count FROM media_items WHERE ocr_engine = 'tesseract' GROUP BY COALESCE(ocr_language, '-') ORDER BY count DESC, ocr_language").fetchall()
        duplicate_groups = conn.execute(
            "SELECT COUNT(*) AS count FROM (SELECT file_hash FROM media_items WHERE file_hash IS NOT NULL GROUP BY file_hash HAVING COUNT(*) > 1)"
        ).fetchone()["count"]
    return {
        "total_items": total,
        "errors": errors,
        "thumbnails": thumbnails,
        "duplicate_groups": duplicate_groups,
        "ocr_done": ocr_done,
        "ocr_pending": ocr_pending,
        "ocr_errors": ocr_errors,
        "ocr_real_done": ocr_real_done,
        "ocr_test_fallback_done": ocr_test_fallback_done,
        "ocr_sample_fallback_done": ocr_sample_fallback_done,
        "ocr_fallback_done": ocr_test_fallback_done + ocr_sample_fallback_done,
        "ocr_capabilities": ocr_capabilities(),
        "heif": heif_status(),
        "sources": rows_to_dicts(sources),
        "by_type": rows_to_dicts(by_type),
        "by_extension": rows_to_dicts(by_ext),
        "by_category": rows_to_dicts(by_category),
        "by_ocr_engine": rows_to_dicts(by_ocr_engine),
        "by_ocr_language": rows_to_dicts(by_ocr_language),
        "categories": sorted(CATEGORIES),
    }


def _backup_db_file() -> Path:
    backups_dir = DATA_DIR / "backups"
    backups_dir.mkdir(parents=True, exist_ok=True)
    target = backups_dir / f"app-{datetime_safe_stamp()}.db"
    if DB_PATH.exists():
        shutil.copy2(DB_PATH, target)
    else:
        init_db()
        shutil.copy2(DB_PATH, target)
    return target


def datetime_safe_stamp() -> str:
    return utc_now().replace(":", "").replace("+", "_").replace("-", "")


@app.post("/api/db/backup")
def db_backup() -> dict:
    target = _backup_db_file()
    return {"backup_path": str(target), "message": "DBバックアップを作成しました。元写真は変更していません。"}


@app.post("/api/db/reset")
def db_reset(payload: ResetPayload) -> dict:
    if not payload.confirm:
        raise HTTPException(status_code=400, detail="confirm=true が必要です")
    backup = _backup_db_file()
    with connect() as conn:
        conn.execute("DELETE FROM media_items")
        if not payload.keep_sources:
            conn.execute("DELETE FROM sources")
        conn.commit()
    ensure_sample_source()
    return {
        "reset": True,
        "backup_path": str(backup),
        "message": "DBの検索インデックスをリセットしました。元写真、元動画、元フォルダは変更していません。",
    }


@app.get("/api/logs")
def get_logs(lines: int = Query(120, ge=1, le=1000)) -> dict:
    log_files = [
        LOG_DIR / "backend.log",
        LOG_DIR / "backend_start.log",
        LOG_DIR / "frontend_start.log",
        LOG_DIR / "backend_live.err.log",
        LOG_DIR / "frontend_live.log",
    ]
    result: dict[str, list[str]] = {}
    for path in log_files:
        if not path.exists():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        result[path.name] = text[-lines:]
    return {"logs": result}


@app.post("/api/samples/generate")
def generate_sample_images() -> dict:
    created = generate_samples()
    source = ensure_sample_source()
    return {"created": [str(path) for path in created], "source": source}
