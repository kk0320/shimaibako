# BatchOCR P1 Validation Report

確認日時: 2026-06-20 10:24:08 JST

対象ブランチ: feature/persistent-batch-ocr

## 目的

読取タブのP1 BatchOCRJobが、手動タップに依存せず20件、50件、100件、0件対象の各ケースを検証できることを確認する。

## 検証方法

DEBUGビルド限定の起動引数 `-ShimaiBakoRunBatchOCRP1Validation` で、BatchOCRJobServiceのP1自己検証を実行した。

自己検証は合成IDのみを使い、写真アプリ内の元写真・元動画には触れない。

## 結果

| ケース | 結果 | requestedLimit | plannedCount | processedCount | 文字あり | 文字なし | 失敗 | OCR保存確認 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 0件対象 | PASS | 0 | 0 | 0 | 0 | 0 | 0 | 対象外 |
| 20件 | PASS | 20 | 20 | 20 | 16 | 4 | 0 | PASS |
| 50件 | PASS | 50 | 50 | 50 | 40 | 10 | 0 | PASS |
| 100件 | PASS | 100 | 100 | 100 | 80 | 20 | 0 | PASS |

## ジョブ作成確認

`batch_ocr_jobs.json` が作成され、最終ジョブは100件検証の完了状態になった。

- state: completed
- requestedLimit: 100
- plannedCount: 100
- processedCount: 100
- completedTextCount: 80
- completedNoTextCount: 20
- failedCount: 0

0件対象ではジョブを作成せず、`0/0 completed job` は作られなかった。

## OCR結果保存確認

20件、50件、100件の各ケースで、合成IDに対してOCR結果保存を確認した。検証後、合成IDのOCR結果は検証用クリーンアップで削除した。

写真本体、既存OCR結果、検索インデックス、分類、不要候補、メモ、タグは削除していない。

## 証跡

- `batch_ocr_p1_validation_report.json`
- `batch_ocr_jobs.json`
- `batch_ocr_p1_read_tab.png`
- `batch_ocr_20_result.png`
- `batch_ocr_50_result.png`
- `batch_ocr_100_result.png`

## 注意

K Phone実機ではCLIから画面タップできないため、手動読取ボタン押下の完全自動確認は未実施。K Phoneへのinstall / launchは別途確認する。

