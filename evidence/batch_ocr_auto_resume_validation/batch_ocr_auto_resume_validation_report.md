# Batch OCR 自動再開検証レポート

検証日時: 2026-06-21

対象ブランチ: `feature/persistent-batch-ocr`

## 検証目的

端末状態による一時停止後、条件が回復した場合にBatchOCRJobが自動再開できることを確認する。

ユーザー操作による一時停止は自動再開しない。

## 検証結果

| 項目 | 結果 |
| --- | --- |
| バッテリー50%未満では待機 | PASS |
| バッテリー50%以上で再開 | PASS |
| thermal seriousでは待機 | PASS |
| thermal normal/fairで再開 | PASS |
| low power ONでは待機 | PASS |
| low power OFFで再開 | PASS |
| user pauseでは再開しない | PASS |
| device pauseでは次Batchへ再開 | PASS |

## 確認した判断ログ

検証JSONに `AUTO_RESUME check` の判断ログを保存した。

主な確認内容:

- `lowBattery` は条件回復まで待機する
- `lowPowerMode` は低電力モード解除まで待機する
- `thermal` は serious では待機し、normal/fair では再開できる
- `user` は自動再開しない
- `deviceCondition` は条件回復後に次の2,000件BatchOCRJobを作成できる

## 証跡

- `batch_ocr_auto_resume_validation_report.json`

## 安全確認

- 元写真・元動画は削除・変更しない
- PhotoKit書き込み/削除APIは追加しない
- 既存OCR結果、検索データ、分類、不要候補、メモ、タグを削除しない
- 全数OCRは通常UIへ戻さない
