from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.classification import looks_like_screenshot
from backend.app.database import connect
from backend.app.test_assets import TEST_ASSETS_DIR, load_manifest_entries


def norm(value: str | None) -> str:
    return (value or "").strip().lower()


def main() -> None:
    entries = load_manifest_entries()
    if not entries:
        raise SystemExit("manifest.json was not found or has no items")

    data_root = TEST_ASSETS_DIR.resolve()
    rows_by_relative: dict[str, dict] = {}
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT id, file_path, file_name, thumbnail_path, file_hash, inferred_category,
                   ocr_text, ocr_status, ocr_engine, ocr_language, width, height
            FROM media_items
            WHERE file_path LIKE ?
            """,
            (f"{str(data_root)}%",),
        ).fetchall()
        hash_counts = {
            row["file_hash"]: row["count"]
            for row in conn.execute(
                """
                SELECT file_hash, COUNT(*) AS count
                FROM media_items
                WHERE file_hash IS NOT NULL
                GROUP BY file_hash
                """
            ).fetchall()
        }

    for row in rows:
        path = Path(row["file_path"])
        try:
            relative = str(path.resolve().relative_to(data_root)).replace("\\", "/")
        except ValueError:
            continue
        rows_by_relative[relative] = dict(row)

    missing = []
    category_hits = 0
    keyword_hits = 0
    keyword_total = 0
    keyword_matched_total = 0
    ocr_done = 0
    thumbnails = 0
    duplicate_hits = 0
    screenshot_hits = 0
    evaluated_duplicates = 0
    engine_counts: dict[str, int] = {}
    language_counts: dict[str, int] = {}
    details = []
    for entry in entries:
        row = rows_by_relative.get(entry["relative_path"])
        if not row:
            missing.append(entry["relative_path"])
            continue
        expected_category = entry["expected_category"]
        category_ok = row.get("inferred_category") == expected_category
        category_hits += int(category_ok)
        text = row.get("ocr_text") or ""
        expected_keywords = entry.get("expected_keywords") or []
        hit_count = sum(1 for keyword in expected_keywords if norm(str(keyword)) in norm(text))
        keyword_total += len(expected_keywords)
        keyword_matched_total += hit_count
        keyword_ok = hit_count > 0
        keyword_hits += int(keyword_ok)
        ocr_done += int(row.get("ocr_status") == "done")
        engine = row.get("ocr_engine") or "not_processed"
        language = row.get("ocr_language") or "-"
        engine_counts[engine] = engine_counts.get(engine, 0) + 1
        language_counts[language] = language_counts.get(language, 0) + 1
        thumbnails += int(bool(row.get("thumbnail_path")))
        if entry.get("should_detect_as_duplicate"):
            evaluated_duplicates += 1
            duplicate_hits += int(hash_counts.get(row.get("file_hash"), 0) > 1)
        if entry.get("should_detect_as_screenshot"):
            screenshot_hits += int(looks_like_screenshot(row.get("width"), row.get("height"), row.get("file_name") or ""))
        details.append(
            {
                "id": entry["id"],
                "file_name": entry["file_name"],
                "expected_category": expected_category,
                "actual_category": row.get("inferred_category"),
                "category_ok": category_ok,
                "ocr_status": row.get("ocr_status"),
                "ocr_engine": engine,
                "ocr_language": language,
                "keyword_hit_count": hit_count,
            }
        )

    total = len(entries)
    scanned = len(rows_by_relative)
    screenshot_expected = sum(1 for entry in entries if entry.get("should_detect_as_screenshot"))
    real_ocr_count = engine_counts.get("tesseract", 0)
    fallback_count = engine_counts.get("test_asset_fallback", 0) + engine_counts.get("sample_fallback", 0)
    evaluation_note = (
        "Tesseract OCRによる実OCR評価です。"
        if real_ocr_count
        else "Tesseract OCR未導入または未使用のため、これは実OCR評価ではありません。test_assets専用manifestフォールバックの検証です。"
    )
    report = [
        "# テストデータセット検証レポート",
        "",
        evaluation_note,
        "",
        f"manifest件数: {total}",
        f"DB登録件数: {scanned}",
        f"未登録: {len(missing)}",
        f"サムネイルあり: {thumbnails}",
        f"OCR済み: {ocr_done}",
        f"実OCR(tesseract): {real_ocr_count}",
        f"テスト/サンプル用フォールバック: {fallback_count}",
        f"分類一致: {category_hits}/{total}",
        f"OCRキーワードヒット: {keyword_hits}/{total}",
        f"OCRキーワード一致数: {keyword_matched_total}/{keyword_total}",
        f"重複期待一致: {duplicate_hits}/{evaluated_duplicates}",
        f"スクショ期待一致: {screenshot_hits}/{screenshot_expected}",
        "",
        "## OCR方式別",
        "",
        *(f"- {key}: {value}" for key, value in sorted(engine_counts.items())),
        "",
        "## OCR言語別",
        "",
        *(f"- {key}: {value}" for key, value in sorted(language_counts.items())),
        "",
        "## 未登録ファイル",
        "",
        *(f"- {item}" for item in missing[:30]),
        "",
        "## 分類不一致サンプル",
        "",
    ]
    mismatches = [item for item in details if not item["category_ok"]]
    if mismatches:
        report.extend(
            f"- {item['id']} {item['file_name']}: expected={item['expected_category']} actual={item['actual_category']}"
            for item in mismatches[:30]
        )
    else:
        report.append("- なし")

    TEST_ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    (TEST_ASSETS_DIR / "validation_report.md").write_text("\n".join(report) + "\n", encoding="utf-8")
    (TEST_ASSETS_DIR / "validation_result.json").write_text(
        json.dumps(
            {
                "manifest_total": total,
                "db_registered": scanned,
                "missing": missing,
                "thumbnails": thumbnails,
                "ocr_done": ocr_done,
                "real_ocr_count": real_ocr_count,
                "fallback_count": fallback_count,
                "category_hits": category_hits,
                "keyword_hits": keyword_hits,
                "keyword_total": keyword_total,
                "keyword_matched_total": keyword_matched_total,
                "duplicate_hits": duplicate_hits,
                "duplicate_expected": evaluated_duplicates,
                "screenshot_hits": screenshot_hits,
                "screenshot_expected": screenshot_expected,
                "engine_counts": engine_counts,
                "language_counts": language_counts,
                "evaluation_note": evaluation_note,
                "details": details,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    docs_dir = ROOT / "docs"
    docs_dir.mkdir(parents=True, exist_ok=True)
    fallback_baseline = None
    fallback_path = TEST_ASSETS_DIR / "validation_result_fallback_before_tesseract.json"
    if fallback_path.exists():
        try:
            fallback_baseline = json.loads(fallback_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            fallback_baseline = None
    docs_report = [
        "# OCR評価レポート",
        "",
        "## 対象",
        "",
        "- データセット: `data/test_assets`",
        f"- manifest件数: {total}",
        f"- DB登録件数: {scanned}",
        "",
        "## 判定",
        "",
        evaluation_note,
        "",
        "## 結果",
        "",
        f"- OCR済み: {ocr_done}/{total}",
        f"- 実OCR(tesseract): {real_ocr_count}",
        f"- テスト/サンプル用フォールバック: {fallback_count}",
        f"- OCRキーワードヒット画像: {keyword_hits}/{total}",
        f"- OCRキーワード一致数: {keyword_matched_total}/{keyword_total}",
        f"- 分類一致: {category_hits}/{total}",
        f"- 重複期待一致: {duplicate_hits}/{evaluated_duplicates}",
        f"- スクショ期待一致: {screenshot_hits}/{screenshot_expected}",
        "",
        "## フォールバック基準との比較",
        "",
    ]
    if fallback_baseline:
        docs_report.extend(
            [
                "| 項目 | 実OCR | test_assetsフォールバック |",
                "| --- | ---: | ---: |",
                f"| OCR済み | {ocr_done}/{total} | {fallback_baseline.get('ocr_done', '-')}/{fallback_baseline.get('manifest_total', '-')} |",
                f"| 実OCR(tesseract) | {real_ocr_count} | {fallback_baseline.get('real_ocr_count', '-')} |",
                f"| フォールバック | {fallback_count} | {fallback_baseline.get('fallback_count', '-')} |",
                f"| OCRキーワードヒット画像 | {keyword_hits}/{total} | {fallback_baseline.get('keyword_hits', '-')}/{fallback_baseline.get('manifest_total', '-')} |",
                f"| OCRキーワード一致数 | {keyword_matched_total}/{keyword_total} | {fallback_baseline.get('keyword_matched_total', '-')}/{fallback_baseline.get('keyword_total', '-')} |",
                f"| 分類一致 | {category_hits}/{total} | {fallback_baseline.get('category_hits', '-')}/{fallback_baseline.get('manifest_total', '-')} |",
            ]
        )
    else:
        docs_report.append("- フォールバック基準ファイルは未作成です。")
    docs_report.extend(
        [
            "",
        "## OCR方式別",
        "",
        *(f"- `{key}`: {value}" for key, value in sorted(engine_counts.items())),
        "",
        "## 注意",
        "",
        "- `test_asset_fallback` は `data/test_assets` 専用です。",
        "- 実写真OCRの評価にはTesseract OCR本体と必要な言語データが必要です。",
        "- 実写真を試す場合は、元写真ではなくコピーした小規模フォルダをデータソースにしてください。",
        ]
    )
    (docs_dir / "ocr_evaluation_report.md").write_text("\n".join(docs_report) + "\n", encoding="utf-8")
    print(f"registered={scanned}/{total} category={category_hits}/{total} keywords={keyword_hits}/{total}")


if __name__ == "__main__":
    main()
