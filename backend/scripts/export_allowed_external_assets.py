from __future__ import annotations

import argparse
import csv
import json
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DATASET_DIR = ROOT / "data" / "external_test_assets"
DEFAULT_OUTPUT = ROOT / "release_candidate" / "external_allowed_assets"


def load_items() -> list[dict]:
    manifest_path = DATASET_DIR / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit("data/external_test_assets/manifest.json was not found")
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    return list(data.get("items", []))


def export_allowed(output_dir: Path, force: bool = False) -> dict:
    output_dir = output_dir.resolve()
    root = ROOT.resolve()
    if root not in output_dir.parents and output_dir != root:
        raise SystemExit("Output directory must be inside this project")
    if output_dir.exists():
        if not force:
            raise SystemExit(f"{output_dir} already exists. Use --force to replace it.")
        shutil.rmtree(output_dir)
    images_dir = output_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)

    exported = []
    for item in load_items():
        if not item.get("allowed_for_demo_bundle"):
            continue
        src = DATASET_DIR / item["relative_path"]
        if not src.exists() or not src.is_file():
            continue
        dest = images_dir / item["file_name"]
        shutil.copy2(src, dest)
        exported.append({**item, "exported_path": f"images/{item['file_name']}"})

    (output_dir / "manifest_allowed.json").write_text(json.dumps({"items": exported}, ensure_ascii=False, indent=2), encoding="utf-8")
    with (output_dir / "manifest_allowed.csv").open("w", encoding="utf-8-sig", newline="") as handle:
        fields = [
            "id",
            "file_name",
            "exported_path",
            "source_url",
            "source_site",
            "license_name",
            "attribution_required",
            "author_or_credit",
            "expected_category",
            "notes",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for item in exported:
            writer.writerow({field: item.get(field, "") for field in fields})

    attribution = [
        "# 外部検証画像 attribution",
        "",
        "この一覧は、外部検証画像をデモ同梱する必要がある場合だけ使用します。",
        "今回の標準デモZIPには外部検証画像を同梱しません。",
        "",
    ]
    for item in exported:
        attribution.extend(
            [
                f"## {item['file_name']}",
                "",
                f"- Source: {item['source_url']}",
                f"- Site: {item['source_site']}",
                f"- License: {item['license_name']}",
                f"- Credit: {item['author_or_credit'] or '-'}",
                "",
            ]
        )
    (output_dir / "ATTRIBUTION.md").write_text("\n".join(attribution), encoding="utf-8")
    return {"exported": len(exported), "output": str(output_dir)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    result = export_allowed(args.output, args.force)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
