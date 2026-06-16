# テスト画像データセットガイド

## 目的

`data/test_assets` は、OCR診断、自動分類、検索UI確認のためのローカル生成データセットです。外部画像素材、外部API、有料サービスは使わず、Pillowで生成します。

実写真風の検証をスマホ写真なしで行う場合は、出典とライセンスをmanifestに残す `data/external_test_assets` も使えます。詳細は [external_test_dataset_guide.md](external_test_dataset_guide.md) を参照してください。

## データセット構成

- `ocr_samples/`: OCR診断用40枚
- `classification_samples/`: 自動認識振り分け用40枚
- `edge_cases/`: 境界/誤判定確認用20枚
- `manifest.json`: 正解ラベル付きmanifest
- `manifest.csv`: 表計算ソフトで確認しやすいCSV
- `generation_report.md`: 生成結果
- `validation_report.md`: DB照合結果
- `validation_result.json`: 検証結果JSON
- `docs/ocr_evaluation_report.md`: manifestとOCR結果の評価サマリ

合計100枚です。

## manifest項目

- `id`
- `file_name`
- `relative_path`
- `group`
- `expected_category`
- `expected_keywords`
- `expected_ocr_text`
- `difficulty`
- `should_detect_as_screenshot`
- `should_detect_as_duplicate`
- `notes`

`expected_category` は次のいずれかです。

- `receipt`
- `business_card`
- `whiteboard`
- `signboard`
- `document_photo`
- `screenshot`
- `construction_board`
- `travel_photo`
- `family_photo`
- `misc`

## 生成方法

PowerShellで次を実行します。

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\generate_test_dataset.py --force
```

再生成しても、元写真や任意フォルダのファイルには触りません。生成対象は `data/test_assets` 配下だけです。

## スキャン方法

1. `Start-ShimaiBako.cmd` で起動します。
2. `ソース` 画面で `data\test_assets` を任意フォルダとして追加します。
3. `スキャン` 画面で最大件数を `120` 程度にします。
4. `スキャン開始` を押します。
5. 統計画面で登録件数とサムネイル件数を確認します。

## OCR検証方法

1. `OCR` 画面を開きます。
2. OCR対象を `全件` にします。
3. データソースを `テスト画像100枚` にします。
4. 最大件数を `120` 程度にします。
5. Tesseract導入後に再評価する場合は、OCR言語を選び、`OCR済みも再処理する` をONにします。
6. `OCR開始` を押します。
7. 検索画面で `shimai`, `Receipt`, `DOC`, `construction` などを検索します。

Tesseract未導入環境では、テスト画像に限りmanifestの `expected_ocr_text` を使うデモ用フォールバックでOCR検索を確認できます。`test_asset_fallback` は `data/test_assets` 専用であり、実写真OCR精度の評価ではありません。

## 分類検証方法

検索画面の `推定カテゴリ` で絞り込みます。詳細画面には `推定カテゴリ` が表示されます。統計画面ではカテゴリ別件数を確認できます。

DBとmanifestの照合は次で実行します。

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\validate_test_dataset.py
```

結果は `data/test_assets/validation_report.md` と `data/test_assets/validation_result.json` に保存されます。
OCR評価サマリは `docs/ocr_evaluation_report.md` にも保存されます。

## 既知制限

- 自動分類はルールベースです。
- テスト画像での高い一致率は、実写真での分類精度を保証しません。
- テスト画像OCRフォールバックは検証用です。実写真OCRにはTesseract OCRが必要です。
- 実OCRのキーワードヒット率は、Tesseract導入後に `OCR済みも再処理する` で再評価してください。
- 手書き文字、反射、強い傾き、極端なぼけは実写真で追加検証が必要です。

## 追加テスト画像を増やす方法

`backend/scripts/generate_test_dataset.py` の `specs()` に項目を追加し、`category_text()` と描画関数を必要に応じて調整します。追加後は次を実行します。

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\generate_test_dataset.py --force
.\.venv\Scripts\python.exe .\backend\scripts\validate_test_dataset.py
```

追加時も外部画像素材は使わず、架空の会社名、電話番号、住所、メールだけを使ってください。

