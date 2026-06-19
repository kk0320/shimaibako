# 全数OCR Simulator検証レポート

## 確認日時

2026-06-19 23:16 JST

## ブランチ

`feature/persistent-full-ocr`

## 確認内容

- Debug buildをiPhone 17 Pro Simulatorへインストール
- 起動引数で写真アクセスをDebug許可扱いにした
- 起動引数で30,000件のDebug用インデックスデータを作成
- 起動引数で30,000件のダミー全数OCRを開始
- 写真タブでDebugプレースホルダーセル、表示状態チップ、OCR進捗カードを確認
- 元写真・元動画はPhotoKitへ作成せず、写真アプリ側に書き込んでいない

## 起動引数

```bash
-ShimaiBakoAssumePhotosAuthorized
-ShimaiBakoCreateLargeLibraryFixture
-ShimaiBakoLargeLibraryFixtureCount 30000
-ShimaiBakoStartDummyFullOCR
-ShimaiBakoDummyFullOCRCount 30000
-ShimaiBakoDummyFullOCRDelayMilliseconds 1
```

## 確認結果

### 写真タブ

- 30,000件規模のDebugデータ作成後、表示状態チップに `通常 28760`、`不要候補 620`、`非表示 310` が表示された
- 実PHAssetがないDebugレコードはプレースホルダーセルとして表示された
- 写真タブは白画面にならず、写真グリッド領域が表示された
- 全数OCR進捗カードが表示された
- ダミーOCRは30,000件ジョブとして開始し、約9%進行状態まで確認した
- 一時停止 / このまま終了ボタンが画面内に表示された

### 検索インデックス準備

- 起動時に無条件で `検索インデックスを準備しています` を出す処理を削除した
- SQLiteに `search_index_preparation_state` を追加し、完了済みなら再実行しない設計にした
- 古い `running` / `preparing` 状態はstale判定で `paused` へ戻す

### 制約

この環境の `simctl` ではタップ操作を直接自動化できなかったため、検索タブ・設定タブへの自動遷移スクリーンショットは未実施。今後はXCUITestまたは手動操作で補完する。

30,000件ダミーOCRの完走待ちは未実施。進捗カード、件数増加、ボタン表示、写真タブ操作可能状態を優先確認した。

## スナップショット

保存先: `evidence/full_ocr_simulator_snapshots/`

- `mobile_photo_initial_debug.png`
- `mobile_photo_running_debug.png`
- `mobile_photo_after_fixture_wait.png`
- `mobile_photo_completed_debug.png`
- `mobile_settings_debug.png`
- `mobile_search_debug.png`
- `mobile_photo_return_debug.png`

`mobile_settings_debug.png`、`mobile_search_debug.png`、`mobile_photo_return_debug.png` はタップ自動化失敗により写真タブのまま保存されている。ファイル名は証跡取得時の意図を示す。

## 問題点

- Debug診断行が写真タブに表示されるため、実機デバッグ時には有用だがスクリーンショット上はやや場所を取る。本番ビルドには出ない。
- 30,000件ダミーOCRはDB保存を伴うため、完走まで時間がかかる。完走UI確認用には小さい件数またはXCUITestで状態固定を検討する。
- 検索タブ・設定タブの自動操作は未実装。

## 次の確認

- XCUITestでタブ移動、検索入力、OCR詳細開閉、一時停止/再開を自動化する
- K Phoneで検索インデックス準備が起動ごとに再実行されないか確認する
- 30,000件ダミーOCRの完了カードを短縮ジョブで確認する
- 実機では発熱、iCloud、Vision OCR速度を別途確認する
