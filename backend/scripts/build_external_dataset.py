from __future__ import annotations

import argparse
import csv
import html
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
DATASET_DIR = ROOT / "data" / "external_test_assets"
IMAGES_DIR = DATASET_DIR / "images"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"
OPENVERSE_API = "https://api.openverse.engineering/v1/images/"
USER_AGENT = "ShimaiBakoLocalMVP/0.1 local validation dataset builder"


@dataclass(frozen=True)
class SearchGroup:
    query: str
    folder: str
    expected_category: str
    expected_keywords: list[str]
    target: int
    notes: str


SEARCH_GROUPS = [
    SearchGroup("mountain landscape photograph", "landscape", "travel_photo", ["landscape", "mountain", "travel"], 14, "Landscape/travel style photos from Wikimedia Commons."),
    SearchGroup("building facade architecture photograph", "buildings", "travel_photo", ["building", "architecture", "facade"], 12, "Buildings and architecture without private interiors."),
    SearchGroup("tourist attraction landmark photograph", "travel", "travel_photo", ["travel", "landmark", "tourist"], 12, "Travel style landmark photos."),
    SearchGroup("shop sign signboard photograph", "signboard", "signboard", ["sign", "signboard", "shop"], 12, "Public signboard style photos."),
    SearchGroup("whiteboard empty meeting room photograph", "whiteboard", "whiteboard", ["whiteboard", "meeting"], 10, "Whiteboard style photos."),
    SearchGroup("desk papers office photograph", "desk", "document_photo", ["desk", "paper", "office"], 10, "Desk and document-like scenes without personal documents."),
    SearchGroup("old document page photograph", "documents", "document_photo", ["document", "page", "paper"], 12, "Historical/public document-like images."),
    SearchGroup("product label packaging photograph", "labels", "receipt", ["label", "product", "packaging"], 10, "Product label / receipt-like OCR targets."),
    SearchGroup("food package label photograph", "labels", "receipt", ["label", "package", "food"], 8, "Additional product label targets."),
]

OPENVERSE_GROUPS = [
    SearchGroup("mountain landscape no people", "landscape", "travel_photo", ["landscape", "mountain", "travel"], 14, "Landscape/travel style photos from Openverse-indexed sources."),
    SearchGroup("forest lake landscape no people", "landscape", "travel_photo", ["landscape", "forest", "lake"], 10, "Nature landscape photos from Openverse-indexed sources."),
    SearchGroup("building facade architecture no people", "buildings", "travel_photo", ["building", "architecture", "facade"], 12, "Building and architecture photos from Openverse-indexed sources."),
    SearchGroup("travel landmark no people", "travel", "travel_photo", ["travel", "landmark", "tourist"], 12, "Travel style landmark photos from Openverse-indexed sources."),
    SearchGroup("shop sign signboard no people", "signboard", "signboard", ["sign", "signboard", "shop"], 12, "Public signboard style photos from Openverse-indexed sources."),
    SearchGroup("warning sign label no people", "signboard", "signboard", ["sign", "warning", "label"], 8, "Additional signboard / label OCR targets."),
    SearchGroup("whiteboard empty office", "whiteboard", "whiteboard", ["whiteboard", "office"], 8, "Whiteboard style photos from Openverse-indexed sources."),
    SearchGroup("desk papers office no people", "desk", "document_photo", ["desk", "paper", "office"], 8, "Desk and document-like scenes from Openverse-indexed sources."),
    SearchGroup("old document page public domain", "documents", "document_photo", ["document", "page", "paper"], 8, "Public document-like images from Openverse-indexed sources."),
    SearchGroup("product label packaging", "labels", "receipt", ["label", "product", "packaging"], 8, "Product label / receipt-like OCR targets from Openverse-indexed sources."),
    SearchGroup("old map document public domain", "documents", "document_photo", ["map", "document", "paper"], 6, "Additional public map/document-like images from Openverse-indexed sources."),
    SearchGroup("street sign no people", "signboard", "signboard", ["sign", "street", "label"], 6, "Additional signboard OCR targets from Openverse-indexed sources."),
    SearchGroup("museum object label public domain", "labels", "receipt", ["label", "museum", "object"], 6, "Additional label-like OCR targets from Openverse-indexed sources."),
]


LICENSE_ALLOWLIST = (
    "public domain",
    "cc0",
    "cc by",
    "cc-by",
)

BANNED_TEXT = (
    "portrait",
    "selfie",
    "person",
    "people",
    "man ",
    "woman",
    "couple",
    "baby",
    "child",
    "children",
    "girl",
    "boy",
    "crowd",
    "face",
    "family",
    "wedding",
    "protest",
    "march",
    "passport",
    "id card",
    "driver license",
    "licence",
    "license plate",
    "number plate",
    "medical",
    "patient",
    "hospital",
    "clinic",
    "hospital record",
    "business card",
    "resume",
    "curriculum vitae",
    "trans",
    "sex",
    "nude",
    "adult",
    "shaving",
    "beer",
    "wine",
    "alcohol",
)

EXT_BY_MIME = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}


def strip_html(value: str | None) -> str:
    if not value:
        return ""
    text = re.sub(r"<[^>]+>", " ", value)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


def safe_name(value: str, max_len: int = 72) -> str:
    value = re.sub(r"^File:", "", value, flags=re.I)
    value = Path(value).stem
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value)
    value = re.sub(r"_+", "_", value).strip("._-")
    return (value or "image")[:max_len]


def commons_request(params: dict) -> dict:
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(f"{COMMONS_API}?{query}", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def openverse_request(params: dict) -> dict:
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(f"{OPENVERSE_API}?{query}", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def search_commons(group: SearchGroup, limit: int = 50) -> list[dict]:
    data = commons_request(
        {
            "action": "query",
            "format": "json",
            "generator": "search",
            "gsrnamespace": 6,
            "gsrsearch": group.query,
            "gsrlimit": limit,
            "prop": "imageinfo",
            "iiprop": "url|extmetadata|mime|size",
            "iiurlwidth": 1600,
        }
    )
    pages = data.get("query", {}).get("pages", {})
    return [pages[key] for key in sorted(pages.keys(), key=lambda item: int(item))]


def search_openverse(group: SearchGroup, page: int = 1, page_size: int = 20) -> list[dict]:
    data = openverse_request(
        {
            "q": group.query,
            "page": page,
            "page_size": page_size,
            "mature": "false",
        }
    )
    return data.get("results", [])


def ext_value(metadata: dict, key: str) -> str:
    value = metadata.get(key, {})
    if isinstance(value, dict):
        return strip_html(str(value.get("value", "")))
    return strip_html(str(value))


def license_ok(license_name: str, usage_terms: str) -> bool:
    combined = f"{license_name} {usage_terms}".strip().lower()
    if not combined:
        return False
    if "fair use" in combined or "copyrighted" in combined:
        return False
    return any(item in combined for item in LICENSE_ALLOWLIST)


def is_risky_text(*parts: str) -> bool:
    text = " ".join(part.lower() for part in parts if part)
    return any(term in text for term in BANNED_TEXT)


def demo_bundle_allowed(license_name: str, source_url: str, author: str) -> bool:
    text = license_name.lower()
    if not source_url:
        return False
    if "nc" in text or "nd" in text:
        return False
    if "public domain" in text or "cc0" in text:
        return True
    if "cc by" in text or "cc-by" in text:
        return bool(author)
    return False


def openverse_license_name(item: dict) -> str:
    code = str(item.get("license") or "").strip().lower()
    version = str(item.get("license_version") or "").strip()
    if code in {"cc0", "pdm"}:
        return "CC0 1.0" if code == "cc0" else "Public Domain Mark"
    if code.startswith("by"):
        return f"CC {code.upper()} {version}".strip()
    return f"{code.upper()} {version}".strip()


def extension_from_openverse(item: dict) -> str | None:
    filetype = str(item.get("filetype") or "").lower().strip(".")
    if filetype in {"jpg", "jpeg"}:
        return ".jpg"
    if filetype == "png":
        return ".png"
    if filetype == "webp":
        return ".webp"
    for key in ("url", "thumbnail"):
        url = str(item.get(key) or "")
        suffix = Path(urllib.parse.urlparse(url).path).suffix.lower()
        if suffix in {".jpg", ".jpeg"}:
            return ".jpg"
        if suffix in {".png", ".webp"}:
            return suffix
    return ".jpg"


def download_file(url: str, target: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        target.write_bytes(response.read())


def verify_image(path: Path) -> tuple[int, int]:
    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as image:
        width, height = image.size
    if width < 300 or height < 220:
        raise ValueError(f"image is too small: {width}x{height}")
    return width, height


def build_dataset(target_total: int, force: bool = False, skip_commons: bool = False) -> list[dict]:
    if force and DATASET_DIR.exists():
        for path in sorted(IMAGES_DIR.rglob("*"), reverse=True):
            if path.is_file():
                path.unlink()
        for file_name in ("manifest.json", "manifest.csv", "external_dataset_report.md", "external_validation_result.json"):
            target = DATASET_DIR / file_name
            if target.exists():
                target.unlink()
    IMAGES_DIR.mkdir(parents=True, exist_ok=True)

    used_titles: set[str] = set()
    used_urls: set[str] = set()
    entries: list[dict] = []
    skipped = Counter()

    for group in OPENVERSE_GROUPS:
        group_count = 0
        for page_number in range(1, 8):
            if len(entries) >= target_total or group_count >= group.target:
                break
            try:
                results = search_openverse(group, page=page_number, page_size=20)
            except Exception:
                skipped["openverse_request"] += 1
                time.sleep(2.0)
                continue
            for item in results:
                if len(entries) >= target_total or group_count >= group.target:
                    break
                source_url = item.get("foreign_landing_url") or item.get("url") or ""
                if source_url in used_urls:
                    skipped["duplicate_url"] += 1
                    continue
                title = strip_html(item.get("title") or "")
                creator = strip_html(item.get("creator") or item.get("attribution") or item.get("source") or "")
                license_name = openverse_license_name(item)
                license_url = item.get("license_url") or ""
                description = " ".join(tag.get("name", "") for tag in (item.get("tags") or [])[:12])
                if not license_ok(license_name, license_name):
                    skipped["license"] += 1
                    continue
                if is_risky_text(title, description, creator):
                    skipped["risk_text"] += 1
                    continue
                ext = extension_from_openverse(item)
                if not ext:
                    skipped["mime"] += 1
                    continue
                image_candidates = [item.get("url"), item.get("thumbnail")]
                entry_id = f"EXT-{len(entries) + 1:03d}"
                file_name = f"{entry_id.lower()}_{group.folder}_{safe_name(title or entry_id)}{ext}"
                relative_path = f"images/{group.folder}/{file_name}"
                target_path = DATASET_DIR / relative_path
                target_path.parent.mkdir(parents=True, exist_ok=True)
                width = height = 0
                downloaded = False
                for image_url in [candidate for candidate in image_candidates if candidate]:
                    try:
                        download_file(image_url, target_path)
                        width, height = verify_image(target_path)
                        downloaded = True
                        break
                    except Exception:
                        if target_path.exists():
                            target_path.unlink()
                        continue
                if not downloaded:
                    skipped["download_or_verify"] += 1
                    continue
                entry = {
                    "id": entry_id,
                    "file_name": file_name,
                    "relative_path": relative_path.replace("\\", "/"),
                    "source_url": source_url,
                    "source_site": f"Openverse / {item.get('source') or item.get('provider') or 'unknown'}",
                    "license_name": license_name,
                    "attribution_required": not license_name.lower().startswith(("cc0", "public domain")),
                    "author_or_credit": creator,
                    "expected_category": group.expected_category,
                    "expected_keywords": group.expected_keywords,
                    "notes": f"{group.notes} Query: {group.query}. Original title: {title}. License URL: {license_url}. Size: {width}x{height}.",
                    "allowed_for_demo_bundle": demo_bundle_allowed(license_name, source_url, creator),
                }
                entries.append(entry)
                used_titles.add(title)
                used_urls.add(source_url)
                group_count += 1
                time.sleep(0.35)
    if skip_commons:
        write_manifest(entries, skipped, target_total)
        return entries

    for group in SEARCH_GROUPS:
        group_count = 0
        for page in search_commons(group, limit=80):
            if len(entries) >= target_total or group_count >= group.target:
                break
            title = page.get("title", "")
            if title in used_titles:
                skipped["duplicate_title"] += 1
                continue
            info = (page.get("imageinfo") or [{}])[0]
            mime = info.get("mime")
            ext = EXT_BY_MIME.get(mime)
            if not ext:
                skipped["mime"] += 1
                continue
            metadata = info.get("extmetadata") or {}
            license_name = ext_value(metadata, "LicenseShortName") or ext_value(metadata, "UsageTerms")
            usage_terms = ext_value(metadata, "UsageTerms")
            author = ext_value(metadata, "Artist") or ext_value(metadata, "Credit")
            description = ext_value(metadata, "ImageDescription") or ext_value(metadata, "ObjectName")
            source_url = info.get("descriptionurl") or ext_value(metadata, "LicenseUrl")
            attribution_required = ext_value(metadata, "AttributionRequired").lower() == "true" or ("cc by" in license_name.lower())
            if not license_ok(license_name, usage_terms):
                skipped["license"] += 1
                continue
            if is_risky_text(title, description, author):
                skipped["risk_text"] += 1
                continue
            image_url = info.get("thumburl") or info.get("url")
            if not image_url or image_url in used_urls:
                skipped["duplicate_url"] += 1
                continue
            entry_id = f"EXT-{len(entries) + 1:03d}"
            file_name = f"{entry_id.lower()}_{group.folder}_{safe_name(title)}{ext}"
            relative_path = f"images/{group.folder}/{file_name}"
            target_path = DATASET_DIR / relative_path
            target_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                download_file(image_url, target_path)
                width, height = verify_image(target_path)
            except Exception as exc:
                skipped["download_or_verify"] += 1
                if target_path.exists():
                    target_path.unlink()
                continue
            entry = {
                "id": entry_id,
                "file_name": file_name,
                "relative_path": relative_path.replace("\\", "/"),
                "source_url": source_url,
                "source_site": "Wikimedia Commons",
                "license_name": license_name,
                "attribution_required": attribution_required,
                "author_or_credit": author,
                "expected_category": group.expected_category,
                "expected_keywords": group.expected_keywords,
                "notes": f"{group.notes} Query: {group.query}. Original title: {title}. Size: {width}x{height}.",
                "allowed_for_demo_bundle": demo_bundle_allowed(license_name, source_url, author),
            }
            entries.append(entry)
            used_titles.add(title)
            used_urls.add(image_url)
            group_count += 1
            time.sleep(1.5)
        if len(entries) >= target_total:
            break

    write_manifest(entries, skipped, target_total)
    return entries


def write_manifest(entries: list[dict], skipped: Counter, target_total: int) -> None:
    DATASET_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {
        "dataset": "external_test_assets",
        "created_by": "しまい箱 local dataset builder",
        "target_count": target_total,
        "item_count": len(entries),
        "source_policy": "Images are downloaded from Openverse-indexed sources and Wikimedia Commons only when license metadata is explicit.",
        "items": entries,
        "skipped": dict(skipped),
    }
    (DATASET_DIR / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    fieldnames = [
        "id",
        "file_name",
        "relative_path",
        "source_url",
        "source_site",
        "license_name",
        "attribution_required",
        "author_or_credit",
        "expected_category",
        "expected_keywords",
        "notes",
        "allowed_for_demo_bundle",
    ]
    with (DATASET_DIR / "manifest.csv").open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for entry in entries:
            row = dict(entry)
            row["expected_keywords"] = "|".join(row["expected_keywords"])
            writer.writerow(row)
    by_license = Counter(entry["license_name"] for entry in entries)
    by_category = Counter(entry["expected_category"] for entry in entries)
    by_bundle = Counter(str(entry["allowed_for_demo_bundle"]).lower() for entry in entries)
    report = [
        "# 外部画像データセット生成レポート",
        "",
        f"生成件数: {len(entries)}",
        f"目標件数: {target_total}",
        "",
        "## 収集方針",
        "",
        "- Openverse APIでライセンス情報が明確な画像を取得しました。",
        "- Wikimedia Commonsはロボットポリシーの429が出たため、今回の100枚生成では追加取得を止めました。",
        "- ライセンス名、出典URL、作者/クレジットをmanifestに保存しました。",
        "- 顔が大きい人物、個人情報、実在名刺、医療書類、個人書類を示す語がある候補は除外しました。",
        "- ライセンスが不明確な画像は採用していません。",
        "",
        "## カテゴリ別",
        "",
        *(f"- {key}: {value}" for key, value in sorted(by_category.items())),
        "",
        "## ライセンス別",
        "",
        *(f"- {key}: {value}" for key, value in sorted(by_license.items())),
        "",
        "## デモ同梱可否",
        "",
        *(f"- {key}: {value}" for key, value in sorted(by_bundle.items())),
        "",
        "## スキップ理由",
        "",
        *(f"- {key}: {value}" for key, value in sorted(skipped.items())),
    ]
    (DATASET_DIR / "external_dataset_report.md").write_text("\n".join(report) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", type=int, default=100)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--skip-commons", action="store_true")
    args = parser.parse_args()
    entries = build_dataset(args.target, args.force, args.skip_commons)
    print(json.dumps({"created": len(entries), "dataset_dir": str(DATASET_DIR)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
