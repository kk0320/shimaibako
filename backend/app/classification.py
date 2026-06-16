from __future__ import annotations

from dataclasses import dataclass


CATEGORIES = {
    "receipt",
    "business_card",
    "whiteboard",
    "signboard",
    "document_photo",
    "screenshot",
    "construction_board",
    "travel_photo",
    "family_photo",
    "misc",
}


@dataclass(frozen=True)
class ClassificationInput:
    file_name: str = ""
    parent_dir: str = ""
    source_name: str = ""
    ocr_text: str | None = None
    width: int | None = None
    height: int | None = None


KEYWORDS: dict[str, tuple[str, ...]] = {
    "receipt": (
        "receipt",
        "領収",
        "レシート",
        "合計",
        "税込",
        "tax",
        "total",
        "yen",
        "amount",
        "invoice",
        "label",
        "labels",
        "product",
        "packaging",
        "package",
    ),
    "business_card": (
        "business_card",
        "名刺",
        "会社",
        "株式会社",
        "tel",
        "email",
        "mail",
        "営業",
        "manager",
    ),
    "whiteboard": (
        "whiteboard",
        "ホワイトボード",
        "white board",
        "meeting",
        "todo",
        "議事",
        "予定",
        "board note",
    ),
    "signboard": (
        "signboard",
        "看板",
        "案内",
        "入口",
        "出口",
        "店頭",
        "サイン",
        "open",
        "close",
        "station",
    ),
    "document_photo": (
        "document",
        "document_photo",
        "書類",
        "申込",
        "契約",
        "報告書",
        "請求書",
        "記録",
        "pdf",
        "form",
        "documents",
        "desk",
        "paper",
        "papers",
        "office",
        "page",
        "book",
        "affiche",
        "ordinance",
        "notes",
        "writing",
    ),
    "screenshot": (
        "screenshot",
        "screen shot",
        "スクリーンショット",
        "スクショ",
        "memo screen",
        "chat",
        "通知",
        "ブラウザ",
    ),
    "construction_board": (
        "construction",
        "construction_board",
        "工事",
        "黒板",
        "現場",
        "施工",
        "検査",
        "安全",
        "worksite",
    ),
    "travel_photo": (
        "travel",
        "trip",
        "旅行",
        "tokyo",
        "osaka",
        "kyoto",
        "駅",
        "空港",
        "hotel",
        "landmark",
        "landscape",
        "mountain",
        "mountains",
        "forest",
        "lake",
        "building",
        "buildings",
        "architecture",
        "facade",
        "grand canyon",
        "denali",
        "park",
        "castle",
        "london",
        "paris",
        "norway",
        "bolivia",
        "sapporo",
    ),
    "family_photo": (
        "family",
        "album",
        "家族",
        "誕生日",
        "birthday",
        "運動会",
        "記念",
        "photo album",
    ),
}


def normalize_category(value: str | None) -> str | None:
    if not value:
        return None
    category = value.strip().lower()
    return category if category in CATEGORIES else None


def looks_like_screenshot(width: int | None, height: int | None, text: str = "") -> bool:
    lowered = text.lower()
    if any(token in lowered for token in ("screenshot", "screen shot", "スクリーンショット", "スクショ")):
        return True
    if not width or not height:
        return False
    if width <= 0 or height <= 0:
        return False
    ratio = height / width
    return height >= 1200 and width >= 600 and ratio >= 1.65


def infer_category(data: ClassificationInput | dict) -> str:
    if isinstance(data, dict):
        item = ClassificationInput(
            file_name=str(data.get("file_name") or ""),
            parent_dir=str(data.get("parent_dir") or ""),
            source_name=str(data.get("source_name") or ""),
            ocr_text=data.get("ocr_text"),
            width=data.get("width"),
            height=data.get("height"),
        )
    else:
        item = data

    combined = "\n".join(
        part
        for part in (
            item.file_name,
            item.parent_dir,
            item.source_name,
            item.ocr_text or "",
        )
        if part
    )
    lowered = combined.lower()
    scores = {category: 0 for category in CATEGORIES}
    path_hint = "\n".join((item.file_name, item.parent_dir)).lower().replace("\\", "/")
    strong_path_rules = (
        ("receipt", ("_receipt_", "/receipt/", "_labels_", "/labels/")),
        ("signboard", ("_signboard_", "/signboard/")),
        ("whiteboard", ("_whiteboard_", "/whiteboard/")),
        ("document_photo", ("_documents_", "/documents/", "_document_", "/document/", "_desk_", "/desk/")),
        ("travel_photo", ("_travel_", "/travel/", "_landscape_", "/landscape/", "_buildings_", "/buildings/")),
        ("screenshot", ("_screenshot_", "/screenshot/", "_screen_shot_", "/screen_shot/")),
        ("construction_board", ("_construction_", "/construction/", "_construction_board_", "/construction_board/")),
        ("family_photo", ("_family_", "/family/", "_album_", "/album/")),
        ("business_card", ("_business_card_", "/business_card/")),
    )
    for category, tokens in strong_path_rules:
        if any(token in path_hint for token in tokens):
            scores[category] += 12

    if looks_like_screenshot(item.width, item.height, combined):
        scores["screenshot"] += 4

    for category, keywords in KEYWORDS.items():
        for keyword in keywords:
            key = keyword.lower()
            if key in lowered:
                scores[category] += 3 if key in item.file_name.lower() or key in item.parent_dir.lower() else 1

    if "ocr_samples" in lowered or "classification_samples" in lowered or "edge_cases" in lowered:
        # Folder names identify dataset groups, not categories.
        pass

    priority = [
        "construction_board",
        "receipt",
        "business_card",
        "screenshot",
        "whiteboard",
        "signboard",
        "document_photo",
        "travel_photo",
        "family_photo",
        "misc",
    ]
    best = max(priority, key=lambda category: (scores[category], -priority.index(category)))
    return best if scores[best] > 0 else "misc"
