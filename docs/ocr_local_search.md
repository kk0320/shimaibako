# ローカルOCR検索

## 目的

スクショ、書類写真、看板、領収書、名刺、メモ写真など、画像内の文字を検索できるようにします。OCR結果はSQLiteに保存し、通常のキーワード検索対象に含めます。

## 外部送信しない方針

OCRはローカル処理だけで行います。写真本体、サムネイル、OCRテキスト、ファイルパスを外部送信しません。外部OCR API、有料API、クラウドOCRは使いません。

## OCR方式

優先方式:

- Windows上の `tesseract.exe` を検出できる場合、Tesseract OCRを使います。
- OCR言語は `eng`、`jpn`、`jpn+eng` から選べます。
- `/api/stats` と統計画面には、Tesseract本体、日本語データ `jpn`、英語データ `eng` の検出状況を表示します。

フォールバック:

- `tesseract.exe` が未検出の場合、実写真OCRはエラーとして記録します。
- サンプル画像だけは、ローカル生成時の既知テキストを使うデモ用フォールバックでOCR検索を確認できます。
- `data/test_assets` の100枚テスト画像は、`manifest.json` の `expected_ocr_text` を使うデモ用フォールバックでOCR検索を確認できます。
- `test_asset_fallback` は `data/test_assets` 専用です。実写真OCRの評価結果として扱わないでください。

現在の検証環境では `winget` で `tesseract-ocr.tesseract` 5.5.0 を導入し、`C:\Program Files\Tesseract-OCR\tesseract.exe` を検出できることを確認しました。PowerShellの `PATH` には未登録ですが、アプリは標準インストール先を直接検出します。

言語データ:

- `eng`: インストール済みデータを `data/tessdata/eng.traineddata` にコピー
- `jpn`: 公式Tesseract言語データを `data/tessdata/jpn.traineddata` に配置
- `osd`: インストール済みデータを `data/tessdata/osd.traineddata` にコピー

確認コマンド:

```powershell
& "C:\Program Files\Tesseract-OCR\tesseract.exe" --version
& "C:\Program Files\Tesseract-OCR\tesseract.exe" --list-langs --tessdata-dir .\data\tessdata
```

## 対象ファイル

OCR対象は画像のみです。動画は対象外です。

対象拡張子:

- jpg
- jpeg
- png
- heic
- heif
- webp
- gif
- bmp
- tiff
- tif

## 使い方

1. 写真フォルダをスキャンします。
2. `OCR` 画面を開きます。
3. 対象を選びます。
   - スクショのみ
   - 全件
   - 画像のみ
   - 未処理のみ
   - エラー再処理
4. 必要ならデータソース、最大件数、OCR言語を指定します。
5. Tesseract導入後に再確認する場合は `OCR済みも再処理する` をONにします。
6. `OCR開始` を押します。
7. 検索画面で文字を検索します。
8. 詳細画面でOCRテキスト、OCR方式、OCR言語を確認できます。

## 実写真小規模検証

実写真は、元写真フォルダを直接対象にせず、コピーした検証用フォルダだけで確認してください。

推奨:

- `data/real_test_photos/` に写真をコピーする。
- スキャン最大件数を100〜300件にする。
- OCR最大件数も100〜300件にする。
- 最初は領収書、書類、看板、スクショなど、文字が読みやすい写真から試す。
- 検証後、必要なら件数を増やす。

## テストデータセットでの確認

`data/test_assets` をデータソースに登録してスキャンした後、OCR画面で対象を `全件`、最大件数を `120` 程度にして実行します。Tesseract未導入環境でも、テスト画像はmanifestの正解OCRテキストで検索検証できます。

今回の検証では次を確認しました。

- テスト画像100枚をスキャン
- サムネイル100件生成
- Tesseract実OCR100件成功
- OCRキーワードヒット 100/100
- OCRキーワード一致数 413/500
- `shimai` 検索がOCRテキストにヒット
- OCR方式は `tesseract`
- OCR言語は `jpn+eng`

比較用に、Tesseract導入前の `test_asset_fallback` では OCRキーワード一致数 448/500 でした。これはmanifest正解テキストを使うテスト用結果であり、実OCR精度ではありません。

## 外部検証画像での確認

`data/external_test_assets` は、利用条件が明確な外部画像だけを使った実写真風の検証データセットです。スマホ写真を使わずに、風景、建物、旅行写真風、看板、書類っぽい写真、机の上、ホワイトボード、商品ラベル風の画像を確認できます。

今回の検証では次を確認しました。

- 外部検証画像100枚を生成
- manifest JSON/CSV各100件
- サムネイル100件生成
- Tesseract `jpn+eng` でOCR済み100/100
- OCRエラー0
- OCRテキストあり86/100
- 分類一致100/100
- 外部画像データセット内の重複ハッシュグループ0

外部画像の `expected_keywords` は検索/分類用の期待語です。外部画像内の可視文字を人手で転記したOCR正解ではないため、OCRキーワード一致率は実OCR精度の主指標として扱いません。OCRの成功/失敗例は [external_image_evaluation_report.md](external_image_evaluation_report.md) に記録しています。

## 制限

- Tesseract OCRが未導入の場合、実写真OCRはできません。
- 日本語OCRには日本語言語データが必要です。
- Tesseract本体があっても `jpn` が無い場合、日本語OCR精度は確認できません。
- HEIC/HEIFは `pillow-heif` と実ファイル互換性に依存します。
- 手書き文字、低解像度、傾き、暗い写真、反射のある写真は精度が落ちます。
- OCRテキストはローカルDBに保存されるため、DBバックアップにも含まれます。

## トラブル対応

### OCRがすべてエラーになる

`tesseract.exe` が見つからない可能性があります。Tesseract OCRをWindowsへ導入し、PATHに追加してください。

### 日本語が読めない

Tesseractの日本語言語データが不足している可能性があります。日本語データを追加してください。

### OCRが遅い

最大件数を小さくし、まず `スクショのみ` や `未処理のみ` で実行してください。

## 大量写真処理時の注意

- 最初は最大件数を 20 から 100 程度にしてください。
- 全件OCRは時間がかかります。
- 家庭内LANで使い、公共Wi-Fiでは使わないでください。
- OCR前にDBバックアップを作成すると戻しやすくなります。

