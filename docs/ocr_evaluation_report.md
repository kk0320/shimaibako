# OCR評価レポート

## 対象

- データセット: `data/test_assets`
- manifest件数: 100
- DB登録件数: 100

## 判定

Tesseract OCRによる実OCR評価です。

## Tesseract環境

- 導入: `winget install --id tesseract-ocr.tesseract -e --source winget`
- バージョン: `tesseract v5.5.0.20241111`
- 実行ファイル: `C:\Program Files\Tesseract-OCR\tesseract.exe`
- PATH: 現在のPowerShell / User / Machine PATH には未登録
- アプリ検出: 標準インストール先から検出
- 言語データフォルダ: `data/tessdata`
- 利用可能言語: `eng`, `jpn`, `osd`
- OCR言語: `jpn+eng`

## 結果

- OCR済み: 100/100
- 実OCR(tesseract): 100
- テスト/サンプル用フォールバック: 0
- OCRキーワードヒット画像: 100/100
- OCRキーワード一致数: 413/500
- 分類一致: 100/100
- 重複期待一致: 2/2
- スクショ期待一致: 12/12

## フォールバック基準との比較

| 項目 | 実OCR | test_assetsフォールバック |
| --- | ---: | ---: |
| OCR済み | 100/100 | 100/100 |
| 実OCR(tesseract) | 100 | 0 |
| フォールバック | 0 | 100 |
| OCRキーワードヒット画像 | 100/100 | 100/100 |
| OCRキーワード一致数 | 413/500 | 448/500 |
| 分類一致 | 100/100 | 100/100 |

## OCR方式別

- `tesseract`: 100

## 注意

- `test_asset_fallback` は `data/test_assets` 専用です。
- 実写真OCRの評価にはTesseract OCR本体と必要な言語データが必要です。
- 実写真を試す場合は、元写真ではなくコピーした小規模フォルダをデータソースにしてください。
- `data/real_test_photos` には現在READMEのみがあり、実写真コピーは未配置です。

