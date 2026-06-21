# Batch OCR対象抽出検証レポート

## 概要

- 対象ブランチ: `feature/persistent-batch-ocr`
- 検証対象: 読取結果キャッシュ削除なしのBatchOCR対象抽出
- 実行方法: Simulator DEBUG起動引数 `-ShimaiBakoOpenReadTab -ShimaiBakoRunBatchOCRTargetSelectionValidation`
- 保存先: `evidence/batch_ocr_target_selection_validation/`

## 結果

| 項目 | 結果 | 上限 | 今回対象 | 検索データのみ候補 | 古い状態を候補へ戻す | 読取済み除外 | 文字なし除外 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 検索データのみ写真の対象化テスト | PASS | 500 | 500 | 2,000 | 0 | 0 | 0 |
| キャッシュ削除なし500件対象抽出テスト | PASS | 500 | 500 | 2,380 | 5 | 12 | 3 |
| キャッシュ削除なし2,000件対象抽出テスト | PASS | 2,000 | 2,000 | 3,125 | 15 | 40 | 20 |
| 0件対象テスト | PASS | 500 | 0 | 0 | 0 | 50 | 50 |

## 確認内容

- SearchDocumentやPhotoIndexRecordが存在するだけでは読取済み扱いしない。
- OCR本文あり、または文字なし判定済みの結果だけを読取済みとして除外する。
- OCRメタデータのない古い空のcompleted状態は、未読取候補として扱う。
- 500件 / 2,000件は上限で止まり、2,000件を超えて自動継続しない。
- 対象0件ではジョブを作らず、読取済みまたは文字なし判定済みである理由を表示する。

## 証跡

- `batch_ocr_target_selection_validation_report.json`
- `batch_ocr_target_selection_read_tab.png`
