# Batch OCR P2検証レポート

## 概要

- 対象ブランチ: `feature/persistent-batch-ocr`
- 検証対象: BatchOCRJob P2 中断・再開
- 実行方法: Simulator DEBUG起動引数 `-ShimaiBakoOpenReadTab -ShimaiBakoRunBatchOCRP2Validation`
- 保存先: `evidence/batch_ocr_p2_validation/`

## 結果

| 項目 | 結果 | 状態 | planned | processed | pending | processing | 文字あり | 文字なし | 失敗 | メモ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| P2: pausedBackground | PASS | pausedBackground | 100 | 37 | 63 | 0 | 29 | 8 | 0 | 途中停止PASS |
| P2: 続き再開 | PASS | completed | 100 | 100 | 0 | 0 | 80 | 20 | 0 | 続き再開PASS |
| P2: processing復旧 | PASS | pausedBackground | 10 | 0 | 10 | 0 | 0 | 0 | 0 | processing復旧PASS |
| P2: この処理を終了 | PASS | completed | 100 | 25 | 75 | 0 | 20 | 5 | 0 | 終了検証PASS |

## 確認内容

- `pausedBackground` への中断で `processing` itemが `pending` に戻ることを確認した。
- `pausedBackground` からの続き再開で、残りのitemだけが処理されることを確認した。
- 起動時復旧相当の処理で、古い `running` ジョブと `processing` itemを安全に復旧できることを確認した。
- `この処理を終了` で未処理分だけを止め、完了済みOCR結果を保持することを確認した。
- 検証は合成IDだけを使い、写真本体や元動画を変更しない。

## 証跡

- `batch_ocr_p2_validation_report.json`
- `batch_ocr_jobs.json`
- `batch_ocr_p2_read_tab.png`
