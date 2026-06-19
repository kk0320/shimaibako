# Full OCR Simulator Validation Report

- 確認日時: 2026-06-20 00:05:33 +0900
- ブランチ: feature/persistent-full-ocr
- Simulator: platform=iOS Simulator,name=iPhone 17 Pro
- Mock件数: 30000
- ダミーOCR件数: 30000

## 結果

- 30,000件mock作成: PASS
- ダミーOCR 5%到達: PASS 2026-06-20 00:06:58 +0900
- ダミーOCR 20%到達: PASS 2026-06-20 00:06:59 +0900
- ダミーOCR 50%到達: PASS 2026-06-20 00:07:03 +0900
- ダミーOCR 100%到達: PASS 2026-06-20 00:07:09 +0900
- 完了カード表示: PASS 2026-06-20 00:07:10 +0900
- 進捗停止検出: PASS
- 検索インデックス再起動抑止: PASS
- DEBUG表示非表示: PASS
- 写真タブスクロール: PASS
- タブバー重なりなし: PASS

## 検索インデックス状態

- OCR完了直後: `0|1|1|notStarted|0|0|0||`
- 準備完了後: `30000|1|1|completed|30000|30000|1781881633.93114|完了|`
- 再起動後: `30000|1|1|completed|30000|30000|1781881633.93114|完了|`

## スナップショット

- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_005.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_020.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_050.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_100.png
- evidence/full_ocr_simulator_snapshots/dummy_full_ocr_completed.png

## 判定メモ

- heartbeatだけではなく、SQLite内の処理済み件数が増えることを監視しました。
- 60秒以上処理済み件数が増えない場合は失敗として終了します。
- 検索インデックスは準備完了後と再起動後の状態行が同一であることを確認しました。
- 検証用Debug診断行は初期状態では非表示です。
- 元写真・元動画を削除/変更する処理は使っていません。
