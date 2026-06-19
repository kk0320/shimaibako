# 全数OCR開始フロー診断

## 目的

全数OCR開始後に写真画面で `activeSnapshot: nil`、`activeJob: none` のままになる場合、ジョブ作成、永続保存、snapshot publish、View購読のどこで止まっているかを切り分ける。

元写真・元動画、写真アプリ側のアセット、OCR結果、手動分類は削除・変更しない。

## 正常な開始順序

1. 確認画面で開始をタップする
2. `OCRJobRunner` がtraceIDを作る
3. `OCRJob(state=preparing)` をSQLiteへ保存する
4. 同じStoreからjobIDで再取得する
5. active jobとして検出する
6. `OCRProgressStore.activeSnapshot` に `preparing` snapshotをpublishする
7. 確認画面を閉じる
8. ワーカーが対象抽出とJobItem作成を開始する

対象抽出や28,000件規模のfilter/sortは、手順6より前に実行しない。

## DEBUGログの見方

- `step=tapped` だけ: ボタンからrunnerへ渡っていない可能性がある
- `step=coordinatorReceived` まで: 端末状態、既存ジョブ、validationでblockedになっている可能性がある
- `step=jobInserted` まで: SQLite保存で失敗している可能性がある
- `step=contextSaved` まで: 再取得predicateまたはStore違いの可能性がある
- `step=jobVerified` まで: active job検出に失敗している可能性がある
- `step=snapshotPublished` まで: 写真画面が別の `OCRProgressStore` を見ている可能性がある
- `step=workerStarted` まで: 対象抽出ワーカーの起動で止まっている可能性がある
- `step=heartbeat` が出る: OCRジョブは動いており、表示購読側を確認する

## DEBUG表示で見るID

写真画面のDEBUG行では次を確認する。

- `store`
- `coordinator`
- `repository`
- `lastStartTappedAt`
- `lastStartPlan`
- `lastStartResult`
- `lastCreatedJobID`
- `lastPersistedJobID`
- `lastTerminalState`
- `lastError`
- `lastWorkerStartAt`

開始側ログと写真画面のStore/Coordinator/Repository IDが異なる場合は、インスタンス共有の問題として修正する。同じ場合は、保存・再取得・publishの結果を見る。

## UI表示条件

`activeSnapshot == nil` の場合は `スマート全数OCRを開始` を表示する。`activeSnapshot != nil` の場合だけ `全数OCRを管理` を表示する。

`preparing`、`total = 0`、`completed = 0` は有効な進捗状態であり、非表示にしない。
