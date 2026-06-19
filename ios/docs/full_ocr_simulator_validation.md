# 全数OCR Simulator検証

## 目的

実機だけに頼らず、SimulatorとDebug buildで30,000件規模の写真タブ、検索、全数OCR進捗、完了カード、レイアウトを確認する。

この検証はPhotoKitへ写真を追加しない。Debug用の `PhotoIndexRecord` をローカルDBへ作成し、元写真・元動画は削除・変更しない。

## Debug用30,000件データ

Debug buildでは設定画面に `Debug Large Library` を表示する。

- `30,000件のテストデータを作成`
- `テストデータを削除`
- `ダミー全数OCRを開始`
- `ダミー検索インデックスを再構築`

内訳は次を目安にする。

- スクリーンショット: 約12,000件
- 書類・領収書・名刺・白板・看板候補: 約10,000件
- 一般写真候補・未分類: 約8,000件
- OCR済み、文字なし、未処理、失敗を混在

本番ビルドにはDebugメニューを出さない。

## 起動引数

Simulator自動確認では次の起動引数を使える。

```bash
-ShimaiBakoAssumePhotosAuthorized
-ShimaiBakoCreateLargeLibraryFixture
-ShimaiBakoLargeLibraryFixtureCount 30000
-ShimaiBakoStartDummyFullOCR
-ShimaiBakoDummyFullOCRCount 30000
-ShimaiBakoDummyFullOCRDelayMilliseconds 25
```

`-ShimaiBakoAssumePhotosAuthorized` はDebug検証用に写真権限を擬似的に許可扱いにする。PhotoKitへ書き込まない。

## ダミー全数OCR

ダミー全数OCRはVision OCRや画像取得を使わない。OCRジョブDB、進捗カード、pause/resume/stop、完了カード、レイアウトを確認するための状態遷移だけを流す。

- 対象件数: 任意、標準30,000件
- フェーズ: 対象確認、画像読み込み、文字認識、結果保存、検索反映
- 結果比率: 文字あり約75%、文字なし約24.9%、失敗約0.1%
- 進捗publish: 既存の進捗間引きに従う
- 写真一覧の実画像や元写真・元動画には触れない

## 進捗停止検出

Simulator検証では `ocr_jobs.sqlite` の処理済み件数を直接確認する。heartbeatだけでは正常とみなさず、`processedCount` が60秒以上増えない場合は停止として扱う。

- ワーカー応答: `last_heartbeat_at` で確認する
- 進捗更新: `completed_count + failed_count` の増加で確認する
- 5% / 20% / 50% / 100% 到達時にスクリーンショットを保存する
- 完了状態と完了カード表示を別途確認する

写真画面のDebug診断行は通常のSimulator検証では非表示にする。必要な時だけ設定画面のDebugメニューから表示する。

## Simulatorで確認すること

- 30,000件規模の写真タブ表示
- 表示状態チップ、カテゴリチップ、検索欄、OCRカードの重なり
- 写真タブのスクロール
- 全数OCR preparing / running / throttled / paused / finalizing / completed のカード表示
- 完了カードが大きすぎないこと
- 検索タブと設定タブへ移動できること
- 検索インデックス準備が再起動ごとに毎回走らないこと

## 実機で確認すること

- 実PhotoKitの読み込み
- iCloud写真取得
- Vision OCRの実速度
- 発熱、低電力、メモリ圧迫
- 充電中・非充電時の長時間安定性

## 証跡

Simulatorスナップショットは `evidence/full_ocr_simulator_snapshots/` に保存する。

検証スクリプトは `ios/scripts/full_ocr_simulator_validation.sh` を使う。30,000件Debugデータ作成、ダミー全数OCRの5% / 20% / 50% / 100%到達、完了カード、検索インデックス再起動抑止をPASS/FAILで記録する。
