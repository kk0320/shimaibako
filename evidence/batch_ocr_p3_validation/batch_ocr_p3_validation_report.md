# Batch OCR P3検証レポート

## 概要

- 対象ブランチ: `feature/persistent-batch-ocr`
- 検証対象: BatchOCRJob P3 500件 / 2,000件対応
- 実行方法: Simulator DEBUG起動引数 `-ShimaiBakoOpenReadTab -ShimaiBakoRunBatchOCRP3Validation`
- 保存先: `evidence/batch_ocr_p3_validation/`

## 結果

| 項目 | 結果 | 状態 | requested | planned | processed | pending | processing | 文字あり | 文字なし | 失敗 | メモ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| P3: 500件読取検証 | PASS | completed | 500 | 500 | 500 | 0 | 0 | 400 | 100 | 0 | 500件読取PASS |
| P3: 2000件読取検証 | PASS | completed | 2000 | 2000 | 2000 | 0 | 0 | 1600 | 400 | 0 | 2000件読取PASS |
| P3: 500件中断・再開検証 | PASS | completed | 500 | 500 | 500 | 0 | 0 | 400 | 100 | 0 | 500件中断・再開PASS |
| P3: 2000件中断・再開検証 | PASS | completed | 2000 | 2000 | 2000 | 0 | 0 | 1600 | 400 | 0 | 2000件中断・再開PASS |

## 確認内容

- 500件と2,000件が同じBatchOCRJobで処理されることを確認した。
- 2,000件を超える自動継続は行わず、requestedLimitとplannedCountの範囲内で完了することを確認した。
- 500件と2,000件の中断・再開がP2と同じ仕組みで動くことを確認した。
- 検証は合成IDだけを使い、写真本体や元動画を変更しない。

## 証跡

- `batch_ocr_p3_validation_report.json`
- `batch_ocr_jobs.json`
- `batch_ocr_p3_read_tab.png`
