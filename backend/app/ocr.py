from __future__ import annotations

import logging
import shutil
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageOps

from .classification import infer_category
from .database import DATA_DIR, connect, init_db, utc_now
from .sample_data import sample_ocr_text
from .scanner import IMAGE_EXTENSIONS, configure_logging
from .test_assets import test_asset_ocr_text


logger = logging.getLogger("drive_research")


@dataclass
class OcrOptions:
    mode: str = "screenshot"
    source_id: int | None = None
    max_items: int = 50
    retry_errors: bool = False
    reprocess_done: bool = False
    language: str = "jpn+eng"


@dataclass
class OcrState:
    running: bool = False
    cancel_requested: bool = False
    processed: int = 0
    succeeded: int = 0
    skipped: int = 0
    errors: int = 0
    target_count: int = 0
    current_item_id: int | None = None
    current_file_name: str | None = None
    engine: str | None = None
    language: str | None = None
    started_at: str | None = None
    finished_at: str | None = None
    last_message: str = "待機中"
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def reset_for_start(self, engine: str | None, language: str | None) -> None:
        with self.lock:
            self.running = True
            self.cancel_requested = False
            self.processed = 0
            self.succeeded = 0
            self.skipped = 0
            self.errors = 0
            self.target_count = 0
            self.current_item_id = None
            self.current_file_name = None
            self.engine = engine
            self.language = language
            self.started_at = utc_now()
            self.finished_at = None
            self.last_message = "OCRを開始しました"

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
                "processed": self.processed,
                "succeeded": self.succeeded,
                "skipped": self.skipped,
                "errors": self.errors,
                "target_count": self.target_count,
                "current_item_id": self.current_item_id,
                "current_file_name": self.current_file_name,
                "engine": self.engine,
                "language": self.language,
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


ocr_state = OcrState()


def find_tesseract() -> str | None:
    found = shutil.which("tesseract")
    if found:
        return found
    for candidate in (
        Path("C:/Program Files/Tesseract-OCR/tesseract.exe"),
        Path("C:/Program Files (x86)/Tesseract-OCR/tesseract.exe"),
    ):
        if candidate.exists():
            return str(candidate)
    return None


def local_tessdata_dir() -> Path | None:
    candidate = DATA_DIR / "tessdata"
    if candidate.exists() and any(candidate.glob("*.traineddata")):
        return candidate
    return None


def _with_tessdata_dir(command: list[str], tessdata_dir: Path | None) -> list[str]:
    if tessdata_dir:
        return command + ["--tessdata-dir", str(tessdata_dir)]
    return command


def list_tesseract_languages(executable: str | None) -> list[str]:
    if not executable:
        return []
    tessdata_dir = local_tessdata_dir()
    try:
        result = subprocess.run(
            _with_tessdata_dir([executable, "--list-langs"], tessdata_dir),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
    except Exception:
        return []
    text = "\n".join(part for part in (result.stdout, result.stderr) if part)
    languages = []
    for line in text.splitlines():
        item = line.strip()
        if not item or item.lower().startswith("list of available languages"):
            continue
        if " " in item or "\t" in item:
            continue
        languages.append(item)
    return sorted(set(languages))


def normalize_ocr_language(language: str | None) -> str:
    selected = (language or "jpn+eng").strip().lower().replace(" ", "")
    if selected in {"eng", "jpn", "jpn+eng"}:
        return selected
    return "jpn+eng"


def ocr_capabilities() -> dict:
    executable = find_tesseract()
    tessdata_dir = local_tessdata_dir()
    languages = list_tesseract_languages(executable)
    has_eng = "eng" in languages
    has_jpn = "jpn" in languages
    recommended = "jpn+eng" if has_eng and has_jpn else "eng" if has_eng else "jpn" if has_jpn else "jpn+eng"
    if executable and has_eng and has_jpn:
        message = "Tesseract OCR と日本語/英語データを利用できます"
    elif executable and has_eng:
        message = "Tesseract OCR は利用できます。日本語データ jpn は未検出です"
    elif executable:
        message = "Tesseract OCR は検出しましたが、言語データを確認してください"
    else:
        message = "Tesseract OCR は未検出です。実写真OCRにはTesseract本体と日本語データ jpn の導入が必要です"
    return {
        "tesseract_available": bool(executable),
        "tesseract_path": executable,
        "tessdata_dir": str(tessdata_dir) if tessdata_dir else None,
        "available_languages": languages,
        "eng_available": has_eng,
        "jpn_available": has_jpn,
        "jpn_eng_available": has_eng and has_jpn,
        "recommended_language": recommended,
        "sample_fallback_available": True,
        "test_asset_fallback_available": True,
        "engine": "tesseract" if executable else "sample_fallback",
        "message": message,
        "install_hint": "実写真OCRには Tesseract OCR 本体、英語 eng、日本語 jpn の言語データを導入してください。test_assets のmanifestフォールバックはテスト画像専用です。",
    }


def _prepare_image(path: Path, target: Path) -> None:
    with Image.open(path) as image:
        image = ImageOps.exif_transpose(image)
        if image.mode not in ("RGB", "L"):
            bg = Image.new("RGB", image.size, "white")
            if "A" in image.getbands():
                bg.paste(image, mask=image.getchannel("A"))
                image = bg
            else:
                image = image.convert("RGB")
        image.save(target, format="PNG")


def _tesseract_text(path: Path, executable: str, language: str) -> tuple[str, str]:
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_image = Path(temp_dir) / "ocr.png"
        _prepare_image(path, temp_image)
        selected = normalize_ocr_language(language)
        tessdata_dir = local_tessdata_dir()
        languages = [selected]
        if selected == "jpn+eng":
            languages.append("eng")
        last_error = ""
        for lang in languages:
            command = _with_tessdata_dir([executable, str(temp_image), "stdout", "-l", lang, "--psm", "6"], tessdata_dir)
            result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
            if result.returncode == 0:
                return result.stdout.strip(), lang
            last_error = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(last_error or "tesseract failed")


def extract_text(path: Path, executable: str | None, language: str = "jpn+eng") -> tuple[str, str, str | None]:
    if executable:
        text, actual_language = _tesseract_text(path, executable, language)
        return text, "tesseract", actual_language
    fallback = sample_ocr_text(path)
    if fallback:
        return fallback, "sample_fallback", None
    fallback = test_asset_ocr_text(path)
    if fallback:
        return fallback, "test_asset_fallback", None
    raise RuntimeError("OCR engine is not available. Install Tesseract OCR for real photos.")


def _screenshot_clause() -> str:
    return "(lower(file_name) LIKE '%screenshot%' OR lower(file_name) LIKE '%screen shot%' OR file_name LIKE '%スクリーンショット%' OR file_name LIKE '%スクショ%' OR lower(parent_dir) LIKE '%screenshot%' OR (height >= 1200 AND width >= 600 AND CAST(height AS REAL) / width >= 1.65))"


def select_ocr_items(options: OcrOptions) -> list[dict]:
    where = ["media_type = 'image'", "lower(extension) IN (%s)" % ",".join("?" for _ in IMAGE_EXTENSIONS)]
    params: list = sorted(IMAGE_EXTENSIONS)
    if options.mode == "screenshot":
        where.append(_screenshot_clause())
    elif options.mode == "unprocessed":
        where.append("(ocr_status IS NULL OR ocr_status = 'pending')")
    if options.source_id:
        where.append("source_id = ?")
        params.append(options.source_id)
    if options.mode == "errors":
        where.append("ocr_status = 'error'")
    elif options.reprocess_done:
        pass
    elif options.retry_errors:
        where.append("(ocr_status IS NULL OR ocr_status IN ('pending', 'error'))")
    else:
        where.append("(ocr_status IS NULL OR ocr_status IN ('pending', 'skipped'))")
    limit = max(1, min(int(options.max_items or 50), 10000))
    with connect() as conn:
        rows = conn.execute(
            f"""
            SELECT *
            FROM media_items
            WHERE {' AND '.join(where)}
            ORDER BY
              CASE WHEN {_screenshot_clause()} THEN 0 ELSE 1 END,
              id DESC
            LIMIT ?
            """,
            params + [limit],
        ).fetchall()
    return [dict(row) for row in rows]


def run_ocr(options: OcrOptions) -> None:
    configure_logging()
    init_db()
    executable = find_tesseract()
    language = normalize_ocr_language(options.language)
    ocr_state.reset_for_start("tesseract" if executable else "sample_fallback", language if executable else None)
    try:
        items = select_ocr_items(options)
        ocr_state.update(target_count=len(items))
        if not items:
            ocr_state.update(last_message="OCR対象がありません")
            return
        for item in items:
            if ocr_state.as_dict()["cancel_requested"]:
                ocr_state.update(last_message="OCRをキャンセルしました")
                break
            ocr_state.update(current_item_id=item["id"], current_file_name=item["file_name"], last_message=f"OCR処理中: {item['file_name']}")
            path = Path(item["file_path"])
            now = utc_now()
            with connect() as conn:
                conn.execute("UPDATE media_items SET ocr_status = 'processing', ocr_error = NULL WHERE id = ?", (item["id"],))
                conn.commit()
            try:
                if not path.exists() or not path.is_file():
                    raise RuntimeError("file is missing")
                text, engine, actual_language = extract_text(path, executable, language)
                ocr_state.update(engine=engine, language=actual_language)
                inferred_category = infer_category({**item, "ocr_text": text})
                with connect() as conn:
                    conn.execute(
                        """
                        UPDATE media_items
                        SET ocr_text = ?, ocr_status = 'done', ocr_error = NULL, ocr_engine = ?, ocr_language = ?, ocr_indexed_at = ?, inferred_category = ?
                        WHERE id = ?
                        """,
                        (text, engine, actual_language, now, inferred_category, item["id"]),
                    )
                    conn.commit()
                ocr_state.inc("succeeded")
            except Exception as exc:
                logger.warning("ocr failed: %s (%s)", path, exc)
                ocr_state.update(engine="tesseract" if executable else "sample_fallback", language=language if executable else None)
                with connect() as conn:
                    conn.execute(
                        """
                        UPDATE media_items
                        SET ocr_status = 'error', ocr_error = ?, ocr_engine = ?, ocr_language = ?, ocr_indexed_at = ?
                        WHERE id = ?
                        """,
                        (str(exc), "tesseract" if executable else "sample_fallback", language if executable else None, now, item["id"]),
                    )
                    conn.commit()
                ocr_state.inc("errors")
            finally:
                ocr_state.inc("processed")
        state = ocr_state.as_dict()
        if state["cancel_requested"]:
            ocr_state.update(last_message="OCRをキャンセルしました")
        else:
            ocr_state.update(last_message="OCRが完了しました")
    finally:
        ocr_state.update(running=False, finished_at=utc_now(), current_item_id=None, current_file_name=None)


class OcrManager:
    def __init__(self) -> None:
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def start(self, options: OcrOptions) -> dict:
        with self._lock:
            if self._thread and self._thread.is_alive():
                return {"started": False, "message": "OCRはすでに実行中です", "status": ocr_state.as_dict()}
            self._thread = threading.Thread(target=run_ocr, args=(options,), daemon=True)
            self._thread.start()
            return {"started": True, "message": "OCRを開始しました", "status": ocr_state.as_dict()}

    def cancel(self) -> dict:
        ocr_state.update(cancel_requested=True, last_message="OCRキャンセル要求を受け付けました")
        return ocr_state.as_dict()

    def status(self) -> dict:
        return ocr_state.as_dict()
