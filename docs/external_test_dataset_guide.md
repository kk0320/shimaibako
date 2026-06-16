# 外部検証画像データセットガイド

## 目的

`data/external_test_assets` は、自分のスマホ写真を使わずに実写真風のスキャン、サムネイル、OCR、分類、検索を確認するための検証データセットです。

Google画像検索などから無作為に取得せず、出典URL、出典サイト、ライセンス名、作者/クレジットをmanifestに残します。

## 構成

- `images/`: 取得画像
- `manifest.json`: 出典と期待カテゴリを含むmanifest
- `manifest.csv`: 表計算ソフトで確認しやすいCSV
- `external_dataset_report.md`: 生成結果
- `external_validation_result.json`: DB照合結果
- `docs/external_image_evaluation_report.md`: OCR・分類評価サマリ

## manifest項目

- `id`
- `file_name`
- `relative_path`
- `source_url`
- `source_site`
- `license_name`
- `attribution_required`
- `author_or_credit`
- `expected_category`
- `expected_keywords`
- `notes`
- `allowed_for_demo_bundle`

`allowed_for_demo_bundle=false` の画像は、デモ配布への同梱を避ける候補です。NC/ND付きライセンスなど、利用条件が複雑になりやすいものはfalseにしています。

## 生成方法

PowerShellで次を実行します。

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\build_external_dataset.py --target 100 --force --skip-commons
```

生成対象は `data/external_test_assets` 配下です。ユーザーの写真フォルダ、iCloud同期フォルダ、OneDrive同期フォルダは変更しません。

## スキャン方法

1. `Start-ShimaiBako.cmd` で起動します。
2. `ソース` 画面で `data\external_test_assets` を任意フォルダとして追加します。
3. `スキャン` 画面で最大件数を `120` 程度にします。
4. `スキャン開始` を押します。
5. 統計画面で登録件数とサムネイル件数を確認します。

## OCR検証方法

1. `OCR` 画面を開きます。
2. OCR対象を `全件` にします。
3. データソースを外部検証画像のソースにします。
4. OCR言語を `jpn+eng` にします。
5. 最大件数を `120` 程度にします。
6. `OCR開始` を押します。

今回の検証では、100枚すべてがTesseract `jpn+eng` でOCR済みになり、OCRエラーは0件でした。

## 分類検証方法

検索画面の `推定カテゴリ` で、旅行写真、看板、書類写真、領収書、ホワイトボードを絞り込みます。DBとmanifestの照合は次で実行します。

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\validate_external_dataset.py
```

今回の検証では、manifest件数100、DB登録100、サムネイル100、分類一致100/100、外部画像データセット内の重複ハッシュグループ0を確認しました。

## 既知制限

- Openverseはライセンス情報を持つ検索APIですが、最終的な利用可否は出典URLとライセンス条件を確認してください。
- `expected_keywords` は検索/分類用の期待語であり、外部画像内の可視文字を人手で転記したOCR正解ではありません。
- 人物や個人情報を示す語は除外していますが、画像内容の完全保証ではありません。デモ同梱前に代表画像を目視確認してください。
- `allowed_for_demo_bundle=true` でも、作者表示などライセンス条件の遵守が必要です。

## デモZIPでの扱い

標準デモZIPには `data/external_test_assets` を同梱しません。先輩デモでは、自作生成の `data/test_assets` 100枚を使います。

外部検証画像を別途使う必要がある場合は、`allowed_for_demo_bundle=true` の画像だけを抽出し、attributionファイルを作成します。

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\export_allowed_external_assets.py --force
```

出力先は `release_candidate/external_allowed_assets/` です。出力後も、出典URLとライセンス条件を確認してください。


