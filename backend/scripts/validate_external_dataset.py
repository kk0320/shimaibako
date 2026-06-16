from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.database import connect


DATASET_DIR = ROOT / "data" / "external_test_assets"


def norm(value: str | None) -> str:
    return (value or "").strip().lower()


def load_manifest() -> list[dict]:
    path = DATASET_DIR / "manifest.json"
    if not path.exists():
        raise SystemExit("data/external_test_assets/manifest.json was not found")
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get("items", data if isinstance(data, list) else [])


def main() -> None:
    entries = load_manifest()
    data_root = DATASET_DIR.resolve()
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT id, file_path, file_name, thumbnail_path, file_hash, inferred_category,
                   ocr_text, ocr_status, ocr_engine, ocr_language, ocr_error, width, height
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
                WHERE file_path LIKE ? AND file_hash IS NOT NULL
                GROUP BY file_hash
                """,
                (f"{str(data_root)}%",),
            ).fetchall()
        }

    rows_by_relative: dict[str, dict] = {}
    for row in rows:
        path = Path(row["file_path"])
        try:
            relative = str(path.resolve().relative_to(data_root)).replace("\\", "/")
        except ValueError:
            continue
        rows_by_relative[relative] = dict(row)

    missing = []
    thumbnails = 0
    category_hits = 0
    ocr_done = 0
    ocr_errors = 0
    ocr_text_images = 0
    ocr_keyword_images = 0
    keyword_total = 0
    keyword_matched_total = 0
    duplicate_groups = sum(1 for count in hash_counts.values() if count > 1)
    engine_counts = Counter()
    language_counts = Counter()
    by_expected = Counter()
    by_actual = Counter()
    by_source = Counter()
    by_license = Counter()
    bundle_counts = Counter()
    details = []

    manifest_by_relative = {entry["relative_path"]: entry for entry in entries}
    for entry in entries:
        by_expected[entry["expected_category"]] += 1
        by_source[entry["source_site"]] += 1
        by_license[entry["license_name"]] += 1
        bundle_counts[str(entry["allowed_for_demo_bundle"]).lower()] += 1
        row = rows_by_relative.get(entry["relative_path"])
        if not row:
            missing.append(entry["relative_path"])
            continue
        text = row.get("ocr_text") or ""
        keywords = entry.get("expected_keywords") or []
        hit_count = sum(1 for keyword in keywords if norm(str(keyword)) in norm(text))
        keyword_total += len(keywords)
        keyword_matched_total += hit_count
        ocr_keyword_images += int(hit_count > 0)
        ocr_text_images += int(len(text.strip()) >= 10)
        ocr_done += int(row.get("ocr_status") == "done")
        ocr_errors += int(row.get("ocr_status") == "error")
        thumbnails += int(bool(row.get("thumbnail_path")))
        actual_category = row.get("inferred_category") or "misc"
        by_actual[actual_category] += 1
        category_hits += int(actual_category == entry["expected_category"])
        engine_counts[row.get("ocr_engine") or "not_processed"] += 1
        language_counts[row.get("ocr_language") or "-"] += 1
        details.append(
            {
                "id": entry["id"],
                "file_name": entry["file_name"],
                "expected_category": entry["expected_category"],
                "actual_category": actual_category,
                "ocr_status": row.get("ocr_status"),
                "ocr_engine": row.get("ocr_engine"),
                "ocr_language": row.get("ocr_language"),
                "ocr_text_length": len(text.strip()),
                "ocr_error": row.get("ocr_error"),
                "keyword_hit_count": hit_count,
                "source_url": entry["source_url"],
                "license_name": entry["license_name"],
                "allowed_for_demo_bundle": entry["allowed_for_demo_bundle"],
            }
        )

    success_examples = [
        item
        for item in sorted(details, key=lambda value: (value["keyword_hit_count"], value["ocr_text_length"]), reverse=True)
        if item["ocr_status"] == "done" and item["ocr_text_length"] >= 20
    ][:8]
    weak_examples = [
        item
        for item in sorted(details, key=lambda value: (value["keyword_hit_count"], value["ocr_text_length"]))
        if item["ocr_status"] != "done" or item["ocr_text_length"] < 10 or item["keyword_hit_count"] == 0
    ][:12]
    mismatches = [item for item in details if item["expected_category"] != item["actual_category"]]

    result = {
        "manifest_total": len(entries),
        "db_registered": len(rows_by_relative),
        "missing": missing,
        "thumbnails": thumbnails,
        "ocr_done": ocr_done,
        "ocr_errors": ocr_errors,
        "ocr_text_images": ocr_text_images,
        "ocr_keyword_images": ocr_keyword_images,
        "keyword_matched_total": keyword_matched_total,
        "keyword_total": keyword_total,
        "category_hits": category_hits,
        "duplicate_groups": duplicate_groups,
        "engine_counts": dict(engine_counts),
        "language_counts": dict(language_counts),
        "by_expected_category": dict(by_expected),
        "by_actual_category": dict(by_actual),
        "by_source": dict(by_source),
        "by_license": dict(by_license),
        "bundle_counts": dict(bundle_counts),
        "success_examples": success_examples,
        "weak_examples": weak_examples,
        "category_mismatches": mismatches[:30],
    }

    DATASET_DIR.mkdir(parents=True, exist_ok=True)
    (DATASET_DIR / "external_validation_result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    report = [
        "# 外部画像OCR・分類評価レポート",
        "",
        "## 対象",
        "",
        "- データセット: `data/external_test_assets`",
        f"- manifest件数: {len(entries)}",
        f"- DB登録件数: {len(rows_by_relative)}",
        f"- サムネイルあり: {thumbnails}",
        "",
        "## ライセンス管理",
        "",
        "- `manifest.json` と `manifest.csv` に出典URL、出典サイト、ライセンス名、作者/クレジット、同梱可否を保存しています。",
        "- NC/ND付きライセンスは、利用条件が複雑になりやすいため `allowed_for_demo_bundle=false` にしています。",
        "",
        "## 出典別",
        "",
        *(f"- {key}: {value}" for key, value in sorted(by_source.items())),
        "",
        "## ライセンス別",
        "",
        *(f"- {key}: {value}" for key, value in sorted(by_license.items())),
        "",
        "## デモ同梱可否",
        "",
        *(f"- {key}: {value}" for key, value in sorted(bundle_counts.items())),
        "",
        "## OCR結果",
        "",
        f"- OCR済み: {ocr_done}/{len(entries)}",
        f"- OCRエラー: {ocr_errors}",
        f"- OCRテキストあり: {ocr_text_images}/{len(entries)}",
        "- `expected_keywords` は検索/分類用の期待語です。外部写真の可視文字を人手で転記したOCR正解ではありません。",
        f"- 期待キーワードがOCRテキストに入った画像: {ocr_keyword_images}/{len(entries)}",
        f"- OCRキーワード一致数: {keyword_matched_total}/{keyword_total}",
        "",
        "## 分類結果",
        "",
        f"- 分類一致: {category_hits}/{len(entries)}",
        "",
        "### 期待カテゴリ",
        "",
        *(f"- {key}: {value}" for key, value in sorted(by_expected.items())),
        "",
        "### 推定カテゴリ",
        "",
        *(f"- {key}: {value}" for key, value in sorted(by_actual.items())),
        "",
        "## 重複候補",
        "",
        f"- 外部画像データセット内の重複ハッシュグループ: {duplicate_groups}",
        "",
        "## OCR成功例",
        "",
    ]
    if success_examples:
        report.extend(
            f"- {item['id']} {item['file_name']}: chars={item['ocr_text_length']} keywords={item['keyword_hit_count']} category={item['actual_category']}"
            for item in success_examples
        )
    else:
        report.append("- なし")
    report.extend(["", "## OCR弱い/失敗例", ""])
    if weak_examples:
        report.extend(
            f"- {item['id']} {item['file_name']}: status={item['ocr_status']} chars={item['ocr_text_length']} keywords={item['keyword_hit_count']} category={item['actual_category']}"
            for item in weak_examples
        )
    else:
        report.append("- なし")
    report.extend(["", "## 分類不一致例", ""])
    if mismatches:
        report.extend(
            f"- {item['id']} {item['file_name']}: expected={item['expected_category']} actual={item['actual_category']}"
            for item in mismatches[:20]
        )
    else:
        report.append("- なし")
    report.extend(
        [
            "",
            "## 注意",
            "",
            "- 画像は外部送信せず、ローカルスキャンとローカルOCRだけで評価しています。",
            "- Openverseはライセンス情報を持つ検索APIですが、最終的な利用可否は出典URLとライセンス条件を確認してください。",
            "- 人物や個人情報を示す語は除外していますが、完全な内容保証ではありません。デモ同梱前に代表画像を目視確認してください。",
        ]
    )
    docs_dir = ROOT / "docs"
    docs_dir.mkdir(parents=True, exist_ok=True)
    (docs_dir / "external_image_evaluation_report.md").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(json.dumps({key: result[key] for key in ("manifest_total", "db_registered", "ocr_done", "ocr_errors", "category_hits", "duplicate_groups")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
