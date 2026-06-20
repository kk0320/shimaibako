# BatchOCR自動継続検証レポート

## 確認日時

2026-06-20 16:30 JST

## 対象

- ブランチ: `feature/persistent-batch-ocr`
- 検証対象: 2,000件BatchOCRJobの任意自動継続
- 実行環境: iPhone 17 Pro Simulator / Debug build

## 検証結果

| 項目 | 結果 |
| --- | --- |
| 2,000件完了後に次の2,000件Jobを作る | PASS |
| 未読取0件で停止し、0件Jobを作らない | PASS |
| thermal seriousで一時停止する | PASS |
| low powerで一時停止する | PASS |
| 途中Jobがある場合は既存Jobを再開対象にする | PASS |

## 確認した仕様

- 自動継続は明示的にONにした場合のみ有効。
- 1つの `BatchOCRJob` は最大2,000件。
- 自動継続ONでも、2,000件を超える巨大Jobは作らない。
- 端末状態が悪い場合は `pausedDeviceCondition` として一時停止する。
- 未読取候補がない場合は `completedNoMoreTargets` とし、0件Jobを作らない。
- 元写真・元動画は削除・変更しない。

## 証跡

- `batch_ocr_auto_continue_validation_report.json`
