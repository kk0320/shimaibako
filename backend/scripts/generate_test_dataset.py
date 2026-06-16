from __future__ import annotations

import argparse
import csv
import json
import random
import shutil
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from backend.app.test_assets import TEST_ASSETS_DIR, clear_manifest_cache


GROUP_DIRS = {
    "ocr": "ocr_samples",
    "classification": "classification_samples",
    "edge": "edge_cases",
}

CATEGORY_LABELS = {
    "receipt": "領収書",
    "business_card": "名刺",
    "signboard": "看板",
    "whiteboard": "ホワイトボード",
    "document_photo": "書類写真",
    "screenshot": "スクショ",
    "family_photo": "家族写真",
    "travel_photo": "旅行写真",
    "construction_board": "工事黒板",
    "misc": "その他",
}

SIZES = {
    "receipt": [(850, 1200), (900, 1250), (820, 1100)],
    "business_card": [(1050, 600), (1000, 620), (1100, 650)],
    "signboard": [(1200, 800), (1300, 850), (1000, 760)],
    "whiteboard": [(1300, 900), (1200, 850), (1400, 900)],
    "document_photo": [(1000, 1400), (1100, 1500), (950, 1300)],
    "screenshot": [(1170, 2532), (1080, 2340), (1125, 2436)],
    "family_photo": [(1300, 900), (1200, 900), (1400, 950)],
    "travel_photo": [(1400, 900), (1300, 850), (1200, 900)],
    "construction_board": [(1300, 900), (1400, 900), (1200, 850)],
    "misc": [(1000, 1000), (1200, 800), (900, 1200)],
}


@dataclass(frozen=True)
class ImageSpec:
    id: str
    group: str
    expected_category: str
    variant: str
    difficulty: str
    should_detect_as_screenshot: bool = False
    should_detect_as_duplicate: bool = False
    notes: str = ""

    @property
    def folder(self) -> str:
        if self.group == "edge":
            return f"{GROUP_DIRS[self.group]}/{self.variant}"
        return f"{GROUP_DIRS[self.group]}/{self.expected_category}"

    @property
    def extension(self) -> str:
        return "png" if self.expected_category == "screenshot" or self.should_detect_as_screenshot else "jpg"

    @property
    def file_name(self) -> str:
        return f"{self.id.lower()}_{self.variant}_{self.expected_category}.{self.extension}"

    @property
    def relative_path(self) -> str:
        return f"{self.folder}/{self.file_name}"


def font(size: int, bold: bool = False) -> ImageFont.ImageFont:
    candidates = [
        "C:/Windows/Fonts/meiryob.ttc" if bold else "C:/Windows/Fonts/meiryo.ttc",
        "C:/Windows/Fonts/YuGothB.ttc" if bold else "C:/Windows/Fonts/YuGothR.ttc",
        "C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf",
    ]
    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def specs() -> list[ImageSpec]:
    result: list[ImageSpec] = []
    ocr_counts = {
        "receipt": 7,
        "business_card": 7,
        "signboard": 7,
        "whiteboard": 7,
        "document_photo": 6,
        "screenshot": 6,
    }
    for category, count in ocr_counts.items():
        for i in range(1, count + 1):
            difficulty = "easy" if i <= 3 else "medium" if i <= 5 else "hard"
            result.append(
                ImageSpec(
                    id=f"OCR-{len(result) + 1:03d}",
                    group="ocr",
                    expected_category=category,
                    variant=f"{category}_{i:02d}",
                    difficulty=difficulty,
                    should_detect_as_screenshot=category == "screenshot",
                )
            )

    class_categories = [
        "receipt",
        "business_card",
        "whiteboard",
        "signboard",
        "document_photo",
        "screenshot",
        "family_photo",
        "travel_photo",
        "construction_board",
        "misc",
    ]
    for category in class_categories:
        for i in range(1, 5):
            difficulty = "easy" if i <= 2 else "medium"
            result.append(
                ImageSpec(
                    id=f"CLS-{len(result) - 39:03d}",
                    group="classification",
                    expected_category=category,
                    variant=f"{category}_{i:02d}",
                    difficulty=difficulty,
                    should_detect_as_screenshot=category == "screenshot",
                )
            )

    edge_items = [
        ("document_like_photo", "document_photo", "edge", False, False, "書類っぽい写真"),
        ("screenlike_real_photo", "screenshot", "edge", True, False, "スクショっぽい実写風"),
        ("cardlike_flyer", "business_card", "edge", False, False, "名刺っぽいチラシ"),
        ("signlike_whiteboard", "whiteboard", "edge", False, False, "看板っぽいホワイトボード"),
        ("ocr_difficult_dense", "document_photo", "hard", False, False, "OCR困難画像"),
        ("low_contrast_receipt", "receipt", "hard", False, False, "低コントラスト"),
        ("tilted_signboard", "signboard", "hard", False, False, "傾き"),
        ("blurred_business_card", "business_card", "hard", False, False, "ぼけ"),
        ("busy_text_background", "signboard", "hard", False, False, "文字多め背景"),
        ("short_receipt", "receipt", "medium", False, False, "文字少なめ領収書"),
        ("similar_filename_receipt_a", "receipt", "medium", False, False, "似たファイル名A"),
        ("similar_filename_receipt_b", "receipt", "medium", False, False, "似たファイル名B"),
        ("duplicate_family_a", "family_photo", "medium", False, True, "重複画像A"),
        ("duplicate_family_b", "family_photo", "medium", False, True, "重複画像B"),
        ("construction_board_small_text", "construction_board", "hard", False, False, "工事黒板の小さい文字"),
        ("travel_sign_mixed", "travel_photo", "edge", False, False, "旅行写真に看板文字"),
        ("family_album_caption", "family_photo", "easy", False, False, "家族写真に短いキャプション"),
        ("misc_label_box", "misc", "medium", False, False, "ラベルだけの箱"),
        ("document_shadow", "document_photo", "hard", False, False, "影あり書類"),
        ("screenshot_darkmode", "screenshot", "medium", True, False, "ダークモード画面"),
    ]
    for idx, (variant, category, difficulty, screenshot, duplicate, note) in enumerate(edge_items, start=1):
        result.append(
            ImageSpec(
                id=f"EDG-{idx:03d}",
                group="edge",
                expected_category=category,
                variant=variant,
                difficulty=difficulty,
                should_detect_as_screenshot=screenshot,
                should_detect_as_duplicate=duplicate,
                notes=note,
            )
        )
    return result


def category_text(spec: ImageSpec, index: int) -> tuple[list[str], list[str]]:
    area = ["東京", "大阪", "京都", "横浜", "札幌", "福岡"][index % 6]
    fake_company = ["しまい箱商店", "青葉デザイン", "港南メモ工房", "北町サンプル社"][index % 4]
    amount = 820 + index * 137
    day = date(2025, (index % 12) + 1, (index % 26) + 1).isoformat()
    category = spec.expected_category
    common = [f"ID {spec.id}", f"DATE {day}", f"AREA {area}"]
    if category == "receipt":
        lines = [fake_company, "領収書 Receipt", f"合計 Total {amount:,} yen", f"登録番号 T-{index:04d}", *common]
        keywords = ["receipt", "領収書", str(amount), area, fake_company]
    elif category == "business_card":
        lines = [fake_company, "営業企画部 Sample Manager", "山田 みなと", f"TEL 03-45{index:02d}-{1200 + index}", f"mail sample{index}@example.local", *common]
        keywords = ["名刺", fake_company, "TEL", "example.local", "営業"]
    elif category == "signboard":
        lines = [f"{area}中央案内", "SIGNBOARD / OPEN", "入口はこちら", f"Route {index:02d}", *common]
        keywords = ["signboard", "看板", "入口", area, "OPEN"]
    elif category == "whiteboard":
        lines = ["Whiteboard meeting", "TODO: scan / OCR / 分類", f"議事メモ {index:02d}", "次回 10:30", *common]
        keywords = ["whiteboard", "TODO", "議事", "OCR", "分類"]
    elif category == "document_photo":
        lines = ["業務報告書 Document", f"案件番号 DOC-{index:04d}", "確認欄 / 承認欄", "添付資料あり", *common]
        keywords = ["document", "報告書", "DOC", "承認", area]
    elif category == "screenshot":
        lines = ["Memo Screen", "通知: OCR検証", f"検索語 shimai-{index:03d}", "09:42  Wi-Fi", *common]
        keywords = ["screenshot", "Memo", "通知", "shimai", "Wi-Fi"]
    elif category == "construction_board":
        lines = ["工事黒板 Construction Board", f"現場 {area} 2丁目", "施工: 架空建設", "検査 OK / 安全確認", *common]
        keywords = ["construction", "工事", "黒板", "現場", "安全"]
    elif category == "travel_photo":
        lines = [f"{area} travel photo", "駅前広場 / landmark", "trip album", f"hotel note {index}", *common]
        keywords = ["travel", area, "駅", "trip", "hotel"]
    elif category == "family_photo":
        lines = ["Family album", "誕生日と記念写真", "home event", f"album {index:02d}", *common]
        keywords = ["family", "album", "誕生日", "記念", "home"]
    else:
        lines = ["Misc label", "しまい箱 No.42", "分類保留", f"box-{index:03d}", *common]
        keywords = ["misc", "しまい箱", "分類保留", "box", "label"]
    return lines, keywords


def draw_wrapped(draw: ImageDraw.ImageDraw, xy: tuple[int, int], lines: list[str], fill: str, size: int, bold: bool = False, spacing: int = 8) -> None:
    x, y = xy
    fnt = font(size, bold=bold)
    for line in lines:
        draw.text((x, y), line, fill=fill, font=fnt)
        bbox = draw.textbbox((x, y), line, font=fnt)
        y += (bbox[3] - bbox[1]) + spacing


def gradient_background(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGB", size, top)
    pixels = image.load()
    for y in range(height):
        ratio = y / max(1, height - 1)
        color = tuple(int(top[i] * (1 - ratio) + bottom[i] * ratio) for i in range(3))
        for x in range(width):
            pixels[x, y] = color
    return image


def draw_image(spec: ImageSpec, index: int) -> Image.Image:
    random.seed(9000 + index)
    size = SIZES[spec.expected_category][index % len(SIZES[spec.expected_category])]
    if spec.should_detect_as_screenshot:
        size = SIZES["screenshot"][index % len(SIZES["screenshot"])]
    lines, _ = category_text(spec, index)
    category = spec.expected_category

    if category == "screenshot":
        image = Image.new("RGB", size, "#f6f8fb")
        draw = ImageDraw.Draw(image)
        w, h = size
        if "darkmode" in spec.variant:
            image.paste("#17202a", (0, 0, w, h))
            fill, panel, accent = "#e9f0f4", "#243341", "#74b8ff"
        else:
            fill, panel, accent = "#17202a", "#ffffff", "#0f7f75"
        draw.rounded_rectangle((0, 0, w, 92), radius=0, fill=panel)
        draw.text((44, 28), "9:42    Wi-Fi", fill=fill, font=font(32, True))
        y = 140
        for block in range(7):
            draw.rounded_rectangle((48, y, w - 48, y + 190), radius=28, fill=panel, outline="#d7e0e5")
            draw.text((80, y + 35), lines[block % len(lines)], fill=fill, font=font(30 if block < 2 else 24, block < 2))
            draw.rectangle((80, y + 110, w - 150, y + 124), fill=accent)
            y += 230
        return image

    if category in {"travel_photo", "family_photo"}:
        image = gradient_background(size, (225, 237, 241), (248, 245, 228))
        draw = ImageDraw.Draw(image)
        w, h = size
        sky = "#b7dce9" if category == "travel_photo" else "#f2d6df"
        draw.rectangle((0, 0, w, int(h * 0.55)), fill=sky)
        draw.polygon([(0, h), (w * 0.28, h * 0.45), (w * 0.55, h), (w, h * 0.55), (w, h)], fill="#6d8f74")
        if category == "family_photo":
            for x in (int(w * 0.32), int(w * 0.5), int(w * 0.66)):
                draw.ellipse((x - 38, int(h * 0.38), x + 38, int(h * 0.48)), fill="#8b5a4a")
                draw.rounded_rectangle((x - 52, int(h * 0.48), x + 52, int(h * 0.72)), radius=30, fill="#2f6f73")
        else:
            draw.rectangle((int(w * 0.62), int(h * 0.33), int(w * 0.86), int(h * 0.68)), fill="#f2f2f2", outline="#345")
            draw.text((int(w * 0.65), int(h * 0.39)), "STATION", fill="#1c4f66", font=font(36, True))
        draw.rounded_rectangle((40, h - 220, w - 40, h - 40), radius=22, fill="#ffffff", outline="#d7d7d7")
        draw_wrapped(draw, (70, h - 195), lines[:4], "#1a3330", max(24, w // 42), bold=True, spacing=6)
        return image

    image = Image.new("RGB", size, "#f7f7f1")
    draw = ImageDraw.Draw(image)
    w, h = size
    margin = int(min(w, h) * 0.07)

    if category == "receipt":
        draw.rectangle((0, 0, w, h), fill="#f8f1df")
        draw.rectangle((margin, margin, w - margin, h - margin), fill="#fffdf5", outline="#d8c8a4", width=4)
        y = margin + 45
        for line in lines:
            draw.text((margin + 45, y), line, fill="#2c2a25", font=font(max(24, w // 32), "合計" in line or "Receipt" in line))
            y += max(42, h // 15)
        for row in range(5):
            y2 = int(h * 0.55) + row * 48
            draw.line((margin + 45, y2, w - margin - 45, y2), fill="#d9ceb6", width=2)
        return image

    if category == "business_card":
        draw.rounded_rectangle((margin, margin, w - margin, h - margin), radius=28, fill="#ffffff", outline="#1f6f73", width=5)
        draw.rectangle((margin, margin, w - margin, margin + 90), fill="#1f6f73")
        draw_wrapped(draw, (margin + 50, margin + 125), lines[:5], "#12312e", max(22, h // 18), bold=True, spacing=8)
        draw.text((margin + 45, margin + 28), "BUSINESS CARD", fill="white", font=font(32, True))
        return image

    if category == "whiteboard":
        draw.rectangle((0, 0, w, h), fill="#e9eceb")
        draw.rounded_rectangle((margin, margin, w - margin, h - margin), radius=18, fill="#fbffff", outline="#9fb4b5", width=8)
        colors = ["#0c615b", "#b44747", "#315fa6", "#51613a"]
        for i, line in enumerate(lines[:6]):
            draw.text((margin + 60, margin + 70 + i * 85), line, fill=colors[i % len(colors)], font=font(max(25, w // 34), i == 0))
        draw.line((margin + 60, h - margin - 100, w - margin - 80, h - margin - 180), fill="#b44747", width=8)
        return image

    if category == "signboard":
        draw.rectangle((0, 0, w, h), fill="#e8eef0")
        draw.rounded_rectangle((margin, margin, w - margin, h - margin), radius=20, fill="#245e61", outline="#143b3d", width=8)
        draw.rectangle((margin + 40, margin + 40, w - margin - 40, h - margin - 40), outline="#f6d66f", width=6)
        draw_wrapped(draw, (margin + 80, margin + 95), lines[:5], "#ffffff", max(32, w // 30), bold=True, spacing=18)
        return image

    if category == "construction_board":
        draw.rectangle((0, 0, w, h), fill="#dce4d4")
        draw.rounded_rectangle((margin, margin, w - margin, h - margin), radius=16, fill="#243d2d", outline="#111f17", width=8)
        draw.rectangle((margin + 45, margin + 45, w - margin - 45, h - margin - 45), outline="#ffffff", width=4)
        for i, line in enumerate(lines[:6]):
            draw.text((margin + 75, margin + 75 + i * 78), line, fill="#f4fff2", font=font(max(24, w // 38), i == 0))
        return image

    if category == "document_photo":
        draw.rectangle((0, 0, w, h), fill="#d8d5ce")
        shadow = (margin + 30, margin + 42, w - margin + 10, h - margin + 24)
        draw.rectangle(shadow, fill="#b8b3aa")
        draw.rectangle((margin, margin, w - margin, h - margin), fill="#ffffff", outline="#d7d7d7", width=3)
        draw_wrapped(draw, (margin + 60, margin + 65), lines[:6], "#1f2930", max(25, w // 34), bold=False, spacing=18)
        for row in range(7):
            y = int(h * 0.5) + row * 58
            draw.line((margin + 60, y, w - margin - 60, y), fill="#d9dde0", width=3)
        return image

    draw.rectangle((0, 0, w, h), fill="#eef2ec")
    draw.rounded_rectangle((margin, margin, w - margin, h - margin), radius=20, fill="#ffffff", outline="#9aa", width=4)
    draw_wrapped(draw, (margin + 55, margin + 75), lines[:5], "#213430", max(26, w // 34), bold=True, spacing=14)
    return image


def apply_difficulty(image: Image.Image, spec: ImageSpec, index: int) -> Image.Image:
    if "low_contrast" in spec.variant or spec.difficulty == "hard" and index % 5 == 0:
        image = ImageOps.autocontrast(image, cutoff=12)
        overlay = Image.new("RGB", image.size, "#f2f2ee")
        image = Image.blend(image, overlay, 0.42)
    if "blurred" in spec.variant or spec.difficulty == "hard" and index % 4 == 0:
        image = image.filter(ImageFilter.GaussianBlur(radius=1.4))
    if "tilted" in spec.variant or spec.difficulty == "hard" and index % 3 == 0:
        angle = -4 if index % 2 else 5
        image = image.rotate(angle, expand=True, fillcolor="#f4f2eb")
    if "busy_text_background" in spec.variant or spec.difficulty == "edge":
        draw = ImageDraw.Draw(image)
        w, h = image.size
        for i in range(18):
            draw.text((20 + (i * 47) % max(80, w - 120), 20 + (i * 83) % max(80, h - 80)), f"TEST {i}", fill="#c8d0cf", font=font(18))
    return image.convert("RGB")


def write_manifest(items: list[dict]) -> None:
    TEST_ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {
        "dataset_name": "しまい箱 local OCR and classification test assets",
        "version": "1.0",
        "total": len(items),
        "generated_at": date.today().isoformat(),
        "items": items,
    }
    (TEST_ASSETS_DIR / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    with (TEST_ASSETS_DIR / "manifest.csv").open("w", encoding="utf-8-sig", newline="") as handle:
        fieldnames = [
            "id",
            "file_name",
            "relative_path",
            "group",
            "expected_category",
            "expected_keywords",
            "expected_ocr_text",
            "difficulty",
            "should_detect_as_screenshot",
            "should_detect_as_duplicate",
            "notes",
        ]
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for item in items:
            row = dict(item)
            row["expected_keywords"] = "|".join(item["expected_keywords"])
            writer.writerow(row)


def write_generation_report(items: list[dict]) -> None:
    by_group: dict[str, int] = {}
    by_category: dict[str, int] = {}
    for item in items:
        by_group[item["group"]] = by_group.get(item["group"], 0) + 1
        by_category[item["expected_category"]] = by_category.get(item["expected_category"], 0) + 1
    lines = [
        "# テスト画像生成レポート",
        "",
        f"生成枚数: {len(items)}",
        "",
        "## グループ別",
        "",
        *[f"- {key}: {value}" for key, value in sorted(by_group.items())],
        "",
        "## 期待カテゴリ別",
        "",
        *[f"- {CATEGORY_LABELS.get(key, key)} ({key}): {value}" for key, value in sorted(by_category.items())],
        "",
        "## 方針",
        "",
        "- すべてPillowでローカル生成しています。",
        "- 外部画像素材、外部API、有料リソースは使っていません。",
        "- manifest.json / manifest.csv に正解ラベルと期待OCRテキストを保存しています。",
    ]
    (TEST_ASSETS_DIR / "generation_report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def generate_dataset(force: bool = False) -> list[dict]:
    items: list[dict] = []
    all_specs = specs()
    if len(all_specs) != 100:
        raise RuntimeError(f"expected 100 specs, got {len(all_specs)}")

    duplicate_source: Path | None = None
    for index, spec in enumerate(all_specs, start=1):
        relative_path = spec.relative_path
        target = TEST_ASSETS_DIR / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        lines, keywords = category_text(spec, index)
        expected_text = "\n".join(lines)
        if spec.variant == "duplicate_family_b" and duplicate_source and duplicate_source.exists():
            if force or not target.exists():
                shutil.copyfile(duplicate_source, target)
        else:
            if force or not target.exists():
                image = draw_image(spec, index)
                image = apply_difficulty(image, spec, index)
                save_kwargs = {"quality": 88, "optimize": True} if spec.extension == "jpg" else {}
                image.save(target, **save_kwargs)
            if spec.variant == "duplicate_family_a":
                duplicate_source = target
        items.append(
            {
                "id": spec.id,
                "file_name": spec.file_name,
                "relative_path": relative_path,
                "group": GROUP_DIRS[spec.group],
                "expected_category": spec.expected_category,
                "expected_keywords": keywords,
                "expected_ocr_text": expected_text,
                "difficulty": spec.difficulty,
                "should_detect_as_screenshot": spec.should_detect_as_screenshot,
                "should_detect_as_duplicate": spec.should_detect_as_duplicate,
                "notes": spec.notes,
            }
        )
    write_manifest(items)
    write_generation_report(items)
    clear_manifest_cache()
    return items


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="regenerate images that already exist")
    args = parser.parse_args()
    items = generate_dataset(force=args.force)
    print(f"Generated test dataset manifest with {len(items)} items at {TEST_ASSETS_DIR}")


if __name__ == "__main__":
    main()
