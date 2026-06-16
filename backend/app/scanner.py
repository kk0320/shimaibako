from __future__ import annotations

import hashlib
import json
import logging
import os
import shutil
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFont, ImageOps, UnidentifiedImageError

try:
    from pillow_heif import register_heif_opener

    register_heif_opener()
    HEIF_AVAILABLE = True
except Exception:
    HEIF_AVAILABLE = False

from .classification import ClassificationInput, infer_category
from .database import DATA_DIR, LOG_DIR, THUMBNAIL_DIR, connect, init_db, utc_now


SUPPORTED_EXTENSIONS = {
    "jpg",
    "jpeg",
    "png",
    "heic",
    "heif",
    "webp",
    "gif",
    "bmp",
    "tiff",
    "tif",
    "mov",
    "mp4",
    "m4v",
}
IMAGE_EXTENSIONS = {"jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif"}
VIDEO_EXTENSIONS = {"mov", "mp4", "m4v"}


def configure_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("drive_research")
    if logger.handlers:
        return
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    file_handler = logging.FileHandler(LOG_DIR / "backend.log", encoding="utf-8")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)


logger = logging.getLogger("drive_research")


@dataclass
class ScanOptions:
    source_ids: list[int] | None = None
    include_disabled: bool = False
    max_items: int = 0
    exclude_dirs: list[str] = field(default_factory=list)
    exclude_extensions: list[str] = field(default_factory=list)
    regenerate_thumbnails: bool = False
    hash_mode: str = "full"
    dry_run: bool = False


@dataclass
class ScanState:
    running: bool = False
    cancel_requested: bool = False
    current_source: str | None = None
    current_source_id: int | None = None
    processed: int = 0
    indexed: int = 0
    skipped: int = 0
    errors: int = 0
    thumbnails: int = 0
    estimated: int = 0
    dry_run: bool = False
    started_at: str | None = None
    finished_at: str | None = None
    last_message: str = "待機中"
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def reset_for_start(self, dry_run: bool = False) -> None:
        with self.lock:
            self.running = True
            self.cancel_requested = False
            self.current_source = None
            self.current_source_id = None
            self.processed = 0
            self.indexed = 0
            self.skipped = 0
            self.errors = 0
            self.thumbnails = 0
            self.estimated = 0
            self.dry_run = dry_run
            self.started_at = utc_now()
            self.finished_at = None
            self.last_message = "見積もりを開始しました" if dry_run else "スキャンを開始しました"

    def as_dict(self) -> dict:
        with self.lock:
            elapsed_seconds = None
            if self.started_at:
                try:
                    start = datetime.fromisoformat(self.started_at)
                    end = datetime.fromisoformat(self.finished_at) if self.finished_at else datetime.now().astimezone()
                    elapsed_seconds = int((end - start).total_seconds())
                except Exception:
                    elapsed_seconds = None
            return {
                "running": self.running,
                "cancel_requested": self.cancel_requested,
                "current_source": self.current_source,
                "current_source_id": self.current_source_id,
                "processed": self.processed,
                "indexed": self.indexed,
                "skipped": self.skipped,
                "errors": self.errors,
                "thumbnails": self.thumbnails,
                "estimated": self.estimated,
                "dry_run": self.dry_run,
                "started_at": self.started_at,
                "finished_at": self.finished_at,
                "elapsed_seconds": elapsed_seconds,
                "last_message": self.last_message,
            }

    def update(self, **kwargs) -> None:
        with self.lock:
            for key, value in kwargs.items():
                setattr(self, key, value)

    def inc(self, key: str, amount: int = 1) -> None:
        with self.lock:
            setattr(self, key, getattr(self, key) + amount)


scan_state = ScanState()


def heif_status() -> dict:
    return {
        "pillow_heif_available": HEIF_AVAILABLE,
        "message": "HEIC/HEIF読み取りを試行できます" if HEIF_AVAILABLE else "pillow-heif が利用できないため HEIC/HEIF はプレースホルダーになります",
    }


def local_time(ts: float | None) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def _load_setting(conn, key: str, default):
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    if not row:
        return default
    try:
        return json.loads(row["value"])
    except Exception:
        return default


def load_scan_options(
    source_ids: list[int] | None = None,
    include_disabled: bool = False,
    max_items: int | None = None,
    exclude_dirs: list[str] | None = None,
    exclude_extensions: list[str] | None = None,
    regenerate_thumbnails: bool | None = None,
    hash_mode: str | None = None,
    dry_run: bool = False,
) -> ScanOptions:
    with connect() as conn:
        default_max = int(_load_setting(conn, "scan_max_items", 0) or 0)
        default_exclude_dirs = _load_setting(conn, "exclude_dirs", [])
        default_exclude_exts = _load_setting(conn, "exclude_extensions", [])
        default_regen = bool(_load_setting(conn, "regenerate_thumbnails", False))
        default_hash = str(_load_setting(conn, "hash_mode", "full") or "full")
    selected_hash = (hash_mode or default_hash).lower()
    if selected_hash not in {"full", "fast", "off"}:
        selected_hash = "full"
    return ScanOptions(
        source_ids=source_ids,
        include_disabled=include_disabled,
        max_items=int(max_items if max_items is not None else default_max or 0),
        exclude_dirs=exclude_dirs if exclude_dirs is not None else list(default_exclude_dirs or []),
        exclude_extensions=[item.lower().lstrip(".") for item in (exclude_extensions if exclude_extensions is not None else default_exclude_exts or [])],
        regenerate_thumbnails=bool(default_regen if regenerate_thumbnails is None else regenerate_thumbnails),
        hash_mode=selected_hash,
        dry_run=dry_run,
    )


def _is_excluded_dir(path: Path, root: Path, exclude_dirs: list[str]) -> bool:
    if not exclude_dirs:
        return False
    parts = {part.lower() for part in path.parts}
    try:
        relative = str(path.relative_to(root)).replace("\\", "/").lower()
    except ValueError:
        relative = str(path).replace("\\", "/").lower()
    for raw in exclude_dirs:
        item = str(raw).strip().replace("\\", "/").lower().strip("/")
        if not item:
            continue
        if item in parts or relative == item or relative.startswith(f"{item}/") or f"/{item}/" in f"/{relative}/":
            return True
    return False


def iter_files_readonly(root: Path, options: ScanOptions) -> Iterable[Path]:
    stack = [root]
    while stack:
        current = stack.pop()
        if _is_excluded_dir(current, root, options.exclude_dirs):
            continue
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            child = Path(entry.path)
                            if not _is_excluded_dir(child, root, options.exclude_dirs):
                                stack.append(child)
                        elif entry.is_file(follow_symlinks=False):
                            path = Path(entry.path)
                            ext = path.suffix.lower().lstrip(".")
                            if ext in SUPPORTED_EXTENSIONS and ext not in options.exclude_extensions:
                                yield path
                    except OSError as exc:
                        logger.warning("scan entry skipped: %s (%s)", entry.path, exc)
        except OSError as exc:
            logger.warning("scan folder skipped: %s (%s)", current, exc)
            scan_state.inc("errors")
            scan_state.update(last_message=f"フォルダを読み取れません: {current}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fast_hash_file(path: Path, stat_result: os.stat_result) -> str:
    digest = hashlib.sha256()
    digest.update(str(stat_result.st_size).encode("ascii"))
    digest.update(str(int(stat_result.st_mtime_ns)).encode("ascii"))
    with path.open("rb") as handle:
        digest.update(handle.read(1024 * 1024))
        if stat_result.st_size > 1024 * 1024:
            handle.seek(max(0, stat_result.st_size - 1024 * 1024))
            digest.update(handle.read(1024 * 1024))
    return "fast:" + digest.hexdigest()


def compute_hash(path: Path, stat_result: os.stat_result, mode: str) -> str | None:
    if mode == "off":
        return None
    if mode == "fast":
        return fast_hash_file(path, stat_result)
    return sha256_file(path)


def thumbnail_key(path: Path, stat_result: os.stat_result, file_hash: str | None) -> str:
    if file_hash:
        return hashlib.sha256(file_hash.encode("utf-8")).hexdigest()
    raw = f"{path}|{stat_result.st_size}|{stat_result.st_mtime_ns}"
    return hashlib.sha256(raw.encode("utf-8", errors="ignore")).hexdigest()


def _font(size: int) -> ImageFont.ImageFont:
    for candidate in ("C:/Windows/Fonts/meiryo.ttc", "C:/Windows/Fonts/arial.ttf"):
        p = Path(candidate)
        if p.exists():
            return ImageFont.truetype(str(p), size=size)
    return ImageFont.load_default()


def ensure_placeholders() -> dict[str, Path]:
    THUMBNAIL_DIR.mkdir(parents=True, exist_ok=True)
    placeholders = {
        "image": THUMBNAIL_DIR / "_placeholder_image.jpg",
        "video": THUMBNAIL_DIR / "_placeholder_video.jpg",
        "error": THUMBNAIL_DIR / "_placeholder_error.jpg",
    }
    styles = {
        "image": ("画像", "#3f6f73", "#eef9f8"),
        "video": ("動画", "#4f5f7f", "#eef2fb"),
        "error": ("表示不可", "#7a4a4a", "#fff1f1"),
    }
    for key, path in placeholders.items():
        if path.exists():
            continue
        title, accent, bg = styles[key]
        image = Image.new("RGB", (300, 300), bg)
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((42, 54, 258, 210), radius=18, outline=accent, width=6)
        if key == "video":
            draw.polygon([(128, 100), (128, 164), (182, 132)], fill=accent)
        else:
            draw.line((72, 174, 126, 126, 168, 158, 218, 106), fill=accent, width=8)
            draw.ellipse((190, 82, 218, 110), fill=accent)
        draw.text((76, 232), title, fill=accent, font=_font(34))
        image.save(path, quality=88)
    return placeholders


def data_relative(path: Path) -> str:
    return str(path.resolve().relative_to(DATA_DIR.resolve())).replace("\\", "/")


def extract_taken_at(image: Image.Image) -> str | None:
    try:
        exif = image.getexif()
    except Exception:
        return None
    for tag in (36867, 36868, 306):
        raw = exif.get(tag)
        if not raw:
            continue
        if isinstance(raw, bytes):
            raw = raw.decode(errors="ignore")
        text = str(raw).strip()
        for fmt in ("%Y:%m:%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
            try:
                return datetime.strptime(text, fmt).astimezone().isoformat(timespec="seconds")
            except Exception:
                continue
    return None


def _video_thumbnail(path: Path, key: str) -> tuple[str, str | None]:
    placeholders = ensure_placeholders()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return data_relative(placeholders["video"]), "ffmpeg is not installed; video placeholder was used"
    target_dir = THUMBNAIL_DIR / key[:2]
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"{key}.jpg"
    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            raw_target = Path(temp_dir) / "frame.jpg"
            subprocess.run(
                [ffmpeg, "-y", "-ss", "00:00:01", "-i", str(path), "-frames:v", "1", "-vf", "scale='min(300,iw)':-2", str(raw_target)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=20,
                check=True,
            )
            with Image.open(raw_target) as image:
                image = ImageOps.exif_transpose(image).convert("RGB")
                image.thumbnail((300, 300), Image.Resampling.LANCZOS)
                image.save(target, format="JPEG", quality=84, optimize=True)
        return data_relative(target), None
    except Exception as exc:
        logger.warning("video thumbnail failed: %s (%s)", path, exc)
        return data_relative(placeholders["video"]), f"video thumbnail failed: {exc}"


def make_thumbnail(
    path: Path,
    key: str,
    media_type: str,
    regenerate: bool = False,
) -> tuple[str | None, int | None, int | None, str | None, str | None]:
    placeholders = ensure_placeholders()
    target_dir = THUMBNAIL_DIR / key[:2]
    target = target_dir / f"{key}.jpg"
    if not regenerate and target.exists():
        return data_relative(target), None, None, None, None

    if media_type == "video":
        thumb, error = _video_thumbnail(path, key)
        return thumb, None, None, None, error

    try:
        with Image.open(path) as image:
            image = ImageOps.exif_transpose(image)
            width, height = image.size
            taken_at = extract_taken_at(image)
            if image.mode not in ("RGB", "L"):
                background = Image.new("RGB", image.size, "white")
                if "A" in image.getbands():
                    background.paste(image, mask=image.getchannel("A"))
                    image = background
                else:
                    image = image.convert("RGB")
            elif image.mode == "L":
                image = image.convert("RGB")
            image.thumbnail((300, 300), Image.Resampling.LANCZOS)
            target_dir.mkdir(parents=True, exist_ok=True)
            image.save(target, format="JPEG", quality=84, optimize=True)
            return data_relative(target), width, height, taken_at, None
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        reason = str(exc)
        if path.suffix.lower() in {".heic", ".heif"} and not HEIF_AVAILABLE:
            reason = "HEIC/HEIF support is not installed"
        logger.warning("thumbnail failed: %s (%s)", path, reason)
        return data_relative(placeholders["error"]), None, None, None, reason


def upsert_item(conn, source: dict, file_path: Path, stat_result: os.stat_result, options: ScanOptions) -> bool:
    extension = file_path.suffix.lower().lstrip(".")
    media_type = "video" if extension in VIDEO_EXTENSIONS else "image"
    file_path_text = str(file_path)
    existing = conn.execute(
        "SELECT id, size_bytes, modified_ts, thumbnail_path, scan_status FROM media_items WHERE source_id = ? AND file_path = ?",
        (source["id"], file_path_text),
    ).fetchone()
    if existing and existing["size_bytes"] == stat_result.st_size and abs((existing["modified_ts"] or 0) - stat_result.st_mtime) < 0.0001:
        thumbnail_path = existing["thumbnail_path"]
        thumb_ok = bool(thumbnail_path and (DATA_DIR / thumbnail_path).exists())
        if existing["scan_status"] == "indexed" and thumb_ok and not options.regenerate_thumbnails:
            scan_state.inc("skipped")
            return False

    now = utc_now()
    error_message = None
    scan_status = "indexed"
    width = None
    height = None
    taken_at = None
    thumbnail_path = None
    file_hash = None
    try:
        file_hash = compute_hash(file_path, stat_result, options.hash_mode)
    except OSError as exc:
        error_message = str(exc)
        scan_status = "error"
        logger.warning("hash failed: %s (%s)", file_path, exc)

    key = thumbnail_key(file_path, stat_result, file_hash)
    if scan_status != "error":
        thumbnail_path, width, height, taken_at, thumb_error = make_thumbnail(file_path, key, media_type, options.regenerate_thumbnails)
        if thumb_error and media_type != "video":
            error_message = thumb_error
            scan_status = "thumbnail_error"
        elif thumb_error:
            error_message = thumb_error
        if thumbnail_path:
            scan_state.inc("thumbnails")

    params = {
        "source_id": source["id"],
        "source_name": source["name"],
        "file_path": file_path_text,
        "file_name": file_path.name,
        "parent_dir": str(file_path.parent),
        "extension": extension,
        "media_type": media_type,
        "size_bytes": int(stat_result.st_size),
        "created_at": local_time(stat_result.st_ctime),
        "modified_at": local_time(stat_result.st_mtime),
        "taken_at": taken_at,
        "width": width,
        "height": height,
        "file_hash": file_hash,
        "thumbnail_path": thumbnail_path,
        "scan_status": scan_status,
        "error_message": error_message,
        "indexed_at": now,
        "created_ts": float(stat_result.st_ctime),
        "modified_ts": float(stat_result.st_mtime),
        "inferred_category": infer_category(
            ClassificationInput(
                file_name=file_path.name,
                parent_dir=str(file_path.parent),
                source_name=source["name"],
                width=width,
                height=height,
            )
        ),
    }
    conn.execute(
        """
        INSERT INTO media_items(
            source_id, source_name, file_path, file_name, parent_dir, extension,
            media_type, size_bytes, created_at, modified_at, taken_at, width,
            height, file_hash, thumbnail_path, scan_status, error_message,
            indexed_at, created_ts, modified_ts, ocr_status, ocr_text, ocr_error,
            ocr_engine, ocr_indexed_at, inferred_category
        )
        VALUES (
            :source_id, :source_name, :file_path, :file_name, :parent_dir, :extension,
            :media_type, :size_bytes, :created_at, :modified_at, :taken_at, :width,
            :height, :file_hash, :thumbnail_path, :scan_status, :error_message,
            :indexed_at, :created_ts, :modified_ts, 'pending', NULL, NULL, NULL, NULL,
            :inferred_category
        )
        ON CONFLICT(source_id, file_path) DO UPDATE SET
            source_name = excluded.source_name,
            file_name = excluded.file_name,
            parent_dir = excluded.parent_dir,
            extension = excluded.extension,
            media_type = excluded.media_type,
            size_bytes = excluded.size_bytes,
            created_at = excluded.created_at,
            modified_at = excluded.modified_at,
            taken_at = COALESCE(excluded.taken_at, media_items.taken_at),
            width = COALESCE(excluded.width, media_items.width),
            height = COALESCE(excluded.height, media_items.height),
            file_hash = excluded.file_hash,
            thumbnail_path = excluded.thumbnail_path,
            scan_status = excluded.scan_status,
            error_message = excluded.error_message,
            indexed_at = excluded.indexed_at,
            created_ts = excluded.created_ts,
            modified_ts = excluded.modified_ts,
            inferred_category = CASE
                WHEN media_items.size_bytes <> excluded.size_bytes OR media_items.modified_ts <> excluded.modified_ts THEN excluded.inferred_category
                WHEN media_items.ocr_text IS NOT NULL AND media_items.ocr_text <> '' THEN media_items.inferred_category
                ELSE excluded.inferred_category
            END,
            ocr_status = CASE
                WHEN media_items.size_bytes <> excluded.size_bytes OR media_items.modified_ts <> excluded.modified_ts THEN 'pending'
                ELSE media_items.ocr_status
            END,
            ocr_text = CASE
                WHEN media_items.size_bytes <> excluded.size_bytes OR media_items.modified_ts <> excluded.modified_ts THEN NULL
                ELSE media_items.ocr_text
            END,
            ocr_error = CASE
                WHEN media_items.size_bytes <> excluded.size_bytes OR media_items.modified_ts <> excluded.modified_ts THEN NULL
                ELSE media_items.ocr_error
            END,
            ocr_engine = CASE
                WHEN media_items.size_bytes <> excluded.size_bytes OR media_items.modified_ts <> excluded.modified_ts THEN NULL
                ELSE media_items.ocr_engine
            END,
            ocr_language = CASE
                WHEN media_items.size_bytes <> excluded.size_bytes OR media_items.modified_ts <> excluded.modified_ts THEN NULL
                ELSE media_items.ocr_language
            END,
            ocr_indexed_at = CASE
                WHEN media_items.size_bytes <> excluded.size_bytes OR media_items.modified_ts <> excluded.modified_ts THEN NULL
                ELSE media_items.ocr_indexed_at
            END
        """,
        params,
    )
    if scan_status == "indexed":
        scan_state.inc("indexed")
    else:
        scan_state.inc("errors")
    return True


def _selected_sources(options: ScanOptions) -> list[dict]:
    with connect() as conn:
        where = ["hidden = 0"]
        params: list = []
        if not options.include_disabled:
            where.append("enabled = 1")
        if options.source_ids:
            placeholders = ",".join("?" for _ in options.source_ids)
            where.append(f"id IN ({placeholders})")
            params.extend(options.source_ids)
        return [dict(row) for row in conn.execute(f"SELECT * FROM sources WHERE {' AND '.join(where)} ORDER BY id", params).fetchall()]


def scan_sources(options: ScanOptions | None = None) -> None:
    configure_logging()
    init_db()
    options = options or load_scan_options()
    scan_state.reset_for_start(dry_run=options.dry_run)
    try:
        sources = _selected_sources(options)

        if not sources:
            scan_state.update(last_message="有効なデータソースがありません")
            return

        limit_reached = False
        for source in sources:
            if scan_state.as_dict()["cancel_requested"] or limit_reached:
                scan_state.update(last_message="キャンセルされました" if scan_state.as_dict()["cancel_requested"] else "最大件数に達しました")
                break
            root = Path(source["path"])
            scan_state.update(current_source=source["name"], current_source_id=source["id"], last_message=f"{source['name']} を確認中")
            if not root.exists() or not root.is_dir():
                logger.warning("source missing: %s", root)
                scan_state.inc("errors")
                scan_state.update(last_message=f"フォルダが見つかりません: {root}")
                continue
            with connect() as conn:
                batch = 0
                for file_path in iter_files_readonly(root, options):
                    if scan_state.as_dict()["cancel_requested"]:
                        break
                    if options.max_items and scan_state.as_dict()["processed"] >= options.max_items:
                        limit_reached = True
                        break
                    scan_state.inc("processed")
                    if options.dry_run:
                        scan_state.inc("estimated")
                        if scan_state.as_dict()["processed"] % 100 == 0:
                            scan_state.update(last_message=f"{source['name']} を見積もり中: {scan_state.as_dict()['processed']}件")
                        continue
                    try:
                        stat_result = file_path.stat()
                        upsert_item(conn, source, file_path, stat_result, options)
                        batch += 1
                        if batch >= 25:
                            conn.commit()
                            batch = 0
                            state = scan_state.as_dict()
                            scan_state.update(last_message=f"{source['name']} を処理中: {state['processed']}件")
                    except Exception:
                        logger.exception("scan file failed: %s", file_path)
                        scan_state.inc("errors")
                        scan_state.update(last_message=f"エラーをスキップ: {file_path.name}")
                if not options.dry_run:
                    conn.commit()
                    conn.execute("UPDATE sources SET last_scan_at = ?, updated_at = ? WHERE id = ?", (utc_now(), utc_now(), source["id"]))
                    conn.commit()
        state = scan_state.as_dict()
        if state["cancel_requested"]:
            scan_state.update(last_message="キャンセルされました")
        elif options.dry_run:
            scan_state.update(last_message=f"見積もりが完了しました: {state['estimated']}件")
        elif limit_reached:
            scan_state.update(last_message="最大件数に達したため停止しました")
        else:
            scan_state.update(last_message="スキャンが完了しました")
    finally:
        scan_state.update(running=False, finished_at=utc_now(), current_source=None, current_source_id=None)


class ScanManager:
    def __init__(self) -> None:
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def start(self, options: ScanOptions | None = None) -> dict:
        with self._lock:
            if self._thread and self._thread.is_alive():
                return {"started": False, "message": "スキャンはすでに実行中です", "status": scan_state.as_dict()}
            self._thread = threading.Thread(target=scan_sources, args=(options,), daemon=True)
            self._thread.start()
            return {"started": True, "message": "スキャンを開始しました", "status": scan_state.as_dict()}

    def cancel(self) -> dict:
        scan_state.update(cancel_requested=True, last_message="キャンセル要求を受け付けました")
        return scan_state.as_dict()

    def status(self) -> dict:
        return scan_state.as_dict()
