from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from .database import SAMPLES_DIR, ensure_directories


SAMPLE_SPECS = [
    ("travel_tokyo_2024.jpg", "Tokyo travel", "#2f6f73", "#f4faf9", (1200, 800)),
    ("receipt_sample_2023.png", "Receipt 2023", "#4f4a45", "#fff8ed", (900, 1200)),
    ("screenshot_memo_2025.png", "Screenshot memo", "#2c3f8f", "#eef3ff", (1170, 2532)),
    ("construction_board_sample.jpg", "Construction board", "#4d6535", "#f4f7ec", (1300, 900)),
    ("family_album_sample.jpg", "Family album", "#8a4f66", "#fff1f5", (1200, 900)),
    ("document_photo_sample.jpg", "Document photo", "#3f4b59", "#f6f7f9", (1000, 1400)),
    ("onedrive_album_bridge_2022.jpg", "Bridge album", "#285f8f", "#eef7ff", (1100, 800)),
    ("icloud_flower_2024.webp", "iCloud flower", "#3c6f4f", "#eef9f0", (1000, 1000)),
    ("travel_osaka_night_2024.jpg", "Osaka night", "#1d2535", "#eff2ff", (1300, 850)),
    ("tax_document_photo_2023.png", "Tax document", "#57492f", "#fff9ec", (1000, 1300)),
    ("screenshot_recipe_2025.png", "Recipe screen", "#7a4f2a", "#fff5e8", (1170, 2532)),
    ("family_birthday_album_2021.jpg", "Birthday album", "#8f3f49", "#fff0f0", (1200, 800)),
    ("worksite_progress_2024.jpg", "Worksite progress", "#586b3e", "#f3f8ed", (1400, 900)),
    ("pet_album_sample_2024.jpg", "Pet album", "#5f4b8b", "#f5f0ff", (1200, 900)),
    ("garden_spring_2024.jpg", "Garden spring", "#2f7d5c", "#effaf4", (1200, 900)),
]

SAMPLE_OCR_TEXT = {filename: f"{title}\n{Path(filename).stem}" for filename, title, *_ in SAMPLE_SPECS}
SAMPLE_OCR_TEXT["duplicate_picnic_a.jpg"] = "Duplicate picnic\nduplicate_picnic_a"
SAMPLE_OCR_TEXT["duplicate_picnic_b.jpg"] = "Duplicate picnic\nduplicate_picnic_b"


def sample_ocr_text(path: Path) -> str | None:
    if path.parent.resolve() != SAMPLES_DIR.resolve():
        return None
    return SAMPLE_OCR_TEXT.get(path.name)


def _font(size: int) -> ImageFont.ImageFont:
    candidates = [
        "C:/Windows/Fonts/meiryo.ttc",
        "C:/Windows/Fonts/arial.ttf",
    ]
    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def _create_image(path: Path, title: str, accent: str, background: str, size: tuple[int, int]) -> None:
    image = Image.new("RGB", size, background)
    draw = ImageDraw.Draw(image)
    w, h = size
    draw.rectangle((0, 0, w, int(h * 0.2)), fill=accent)
    draw.rectangle((int(w * 0.06), int(h * 0.28), int(w * 0.94), int(h * 0.84)), outline=accent, width=max(4, w // 180))
    draw.ellipse((int(w * 0.68), int(h * 0.36), int(w * 0.86), int(h * 0.58)), fill=accent)
    draw.line((int(w * 0.1), int(h * 0.72), int(w * 0.34), int(h * 0.52), int(w * 0.52), int(h * 0.68), int(w * 0.72), int(h * 0.48)), fill=accent, width=max(6, w // 120))
    title_font = _font(max(32, w // 19))
    label_font = _font(max(22, w // 34))
    draw.text((int(w * 0.07), int(h * 0.055)), title, fill="white", font=title_font)
    draw.text((int(w * 0.08), int(h * 0.88)), path.stem, fill=accent, font=label_font)
    save_kwargs = {}
    if path.suffix.lower() in {".jpg", ".jpeg"}:
        save_kwargs = {"quality": 90}
    image.save(path, **save_kwargs)


def generate_samples(force: bool = False) -> list[Path]:
    ensure_directories()
    created: list[Path] = []
    for filename, title, accent, background, size in SAMPLE_SPECS:
        path = SAMPLES_DIR / filename
        if force or not path.exists():
            _create_image(path, title, accent, background, size)
            created.append(path)

    duplicate_a = SAMPLES_DIR / "duplicate_picnic_a.jpg"
    duplicate_b = SAMPLES_DIR / "duplicate_picnic_b.jpg"
    if force or not duplicate_a.exists():
        _create_image(duplicate_a, "Duplicate picnic", "#1f6f5b", "#effaf6", (1200, 850))
        created.append(duplicate_a)
    if force or not duplicate_b.exists():
        shutil.copyfile(duplicate_a, duplicate_b)
        created.append(duplicate_b)
    return created
