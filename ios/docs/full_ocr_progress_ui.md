# 全数OCR進捗UI

## 目的

全数OCRが実行中か、止まっているか、端末状態により減速しているかを、写真一覧とは独立して確認できるようにする。

写真本体、元動画、写真アプリ側のアセットは削除・変更しない。OCR結果は端末内に保存する。

## 表示内容

写真画面では、全数OCRの状態をコンパクトカードとして表示する。通常の写真一覧を広く使えるように、詳細すぎる情報は `詳細` から確認する。

コンパクトカードには次を表示する。

- 状態
- `completed / total`
- ProgressView
- パーセント
- 文字あり、文字なし、失敗の要約
- 現在のphase
- 処理速度
- 推定残り時間
- Heartbeat状態
- 一時停止、再開、このまま終了、失敗分だけ再試行、iCloud取得を許可して再開

iCloud待ちやスキップ件数などの詳細は、管理メニューまたは詳細側で確認する。完了後は大きなカードを出し続けず、必要な確認に留める。

## activeSnapshot

写真画面の全数OCR表示は `OCRProgressStore.activeSnapshot` を購読する。`activeSnapshot` がある場合はコンパクト進捗カードを表示し、ない場合は通常のOCR開始導線だけを表示する。

`PhotoGridView` 本体は `OCRProgressStore` を直接監視しない。コンパクト進捗カードだけが `activeSnapshot` を購読し、進捗更新で写真一覧、カテゴリチップ、件数チップ、サムネイル再取得を誘発しない。

全数OCR開始時は、対象抽出や件数計算より先に `preparing` の `activeSnapshot` をpublishする。`total` が0の未確定状態でも、写真画面には「全数OCRを準備中」「対象写真を確認しています」と表示する。

DEBUG buildでは、写真画面に `jobDB` 状態、`ocr_jobs` / `ocr_job_items` の存在、`lastDBError`、`lastMigrationAt`、`activeSnapshot`、runner側のactive job、job state、observer状態、heartbeat、store識別子を表示する。個別写真名、写真パス、OCR本文、サムネイルは表示しない。

## OCRジョブDB状態

写真画面と全数OCR確認画面では、永続ジョブDBの準備状態をactive jobとは分けて扱う。

- `unknown`: まだ確認していない
- `preparing`: `CREATE TABLE IF NOT EXISTS` と不足列追加を実行中
- `ready`: `ocr_jobs` と `ocr_job_items` が存在し、開始可能
- `missingTable`: 必須テーブルがない、または作成確認に失敗
- `repairFailed`: DB準備処理に失敗

`no such table: ocr_jobs` は `activeJob: none` として扱わない。DB準備を再試行し、成功した場合だけ `jobDB: ready / activeJob: none` と表示する。この場合は「DBは正常で、未完了ジョブがない」状態である。

全数OCR確認画面では、DB準備中は開始ボタンを押せない。失敗時はエラー詳細と再試行ボタンを表示し、確認画面を閉じない。

## Heartbeat

ワーカーは数秒ごとに `lastHeartbeatAt`、`currentPhase`、`currentAssetIdentifier` を更新する。UIには写真名、写真パス、OCR本文、サムネイルは表示しない。

- 5秒以内: ワーカー正常
- 5〜15秒: 現在の1件を処理中
- 15〜30秒: 処理状況を確認中
- 30秒以上: 進捗更新停止

30秒以上更新がない場合でも、完了済みOCR結果は保存済みであり、元写真・元動画は削除・変更されない。ユーザーは再開またはいったん終了を選べる。

## 写真グリッドとの分離

OCR進捗は `OCRProgressStore` が持つ `OCRProgressSnapshot` だけを進捗カードへpublishする。写真グリッド、件数チップ、カテゴリチップ、サムネイルパイプラインとは分ける。

- 進捗publishは最大500msに1回程度
- 写真一覧配列を進捗更新で再生成しない
- カテゴリ件数を進捗更新で再計算しない
- Debugログは状態、件数、phase、heartbeatだけにする

## まとめてOCRとの関係

全数OCRが準備中、実行中、減速中、一時停止中、終了処理中の場合、写真画面の `まとめてOCR` は待機扱いにする。UIには「全数OCRを実行中のため、まとめてOCRは待機しています」と表示し、競合するOCRジョブを同時に開始しない。

将来的にクイックOCRを優先キューへ入れる場合も、全数OCRの永続進捗とは別の優先度制御として扱う。

## 再起動後

起動時に未完了OCRジョブを読み込み、処理中だったアイテムは再開可能な状態へ戻す。進捗カードに続きから再開できる状態を表示する。

復元対象は `preparing`、`running`、`throttled`、`pausedThermal`、`pausedUser`、`cancelling` を含む未完了ジョブである。復元時も `OCRProgressStore.activeSnapshot` を作り直し、写真画面のコンパクトカードを表示する。

`activeSnapshot` がnilのままの場合は、次を確認する。

- `OCRJobStore` に未完了ジョブがあるか
- `OCRProgressStore` が上位Viewから単一インスタンスとして渡されているか
- runner側のpublishが `OCRProgressStore.activeSnapshot` へ届いているか
- 写真画面の表示条件が `total > 0` や `state == running` に限定されていないか

## 開始直後の表示条件

全数OCRの開始は、確認画面で `started` が返るまで閉じない。開始処理はまず `OCRJob(state=preparing)` を保存し、同じ `OCRJobStore` から jobID で再取得して存在と状態を確認する。確認後に `OCRProgressStore.activeSnapshot` へ `preparing` snapshot をpublishする。

`preparing` snapshot は `total = 0`、`completed = 0` でも有効な進捗である。写真画面は `activeSnapshot != nil` だけでコンパクトカードを表示し、対象抽出や件数確定を待たない。

`activeSnapshot == nil` の場合は `全数OCRを管理` を出さず、`スマート全数OCRを開始` を表示する。`activeSnapshot != nil` の場合だけ管理メニューを表示する。

## DEBUG診断

DEBUG buildでは、開始経路にtraceID付きログを出す。

- `FULL_OCR trace=... step=tapped`
- `FULL_OCR trace=... step=coordinatorReceived`
- `FULL_OCR trace=... step=prepareDatabaseStarted`
- `FULL_OCR trace=... step=prepareDatabaseSucceeded`
- `FULL_OCR trace=... step=prepareDatabaseFailed`
- `FULL_OCR trace=... step=jobInserted`
- `FULL_OCR trace=... step=contextSaved`
- `FULL_OCR trace=... step=jobVerified`
- `FULL_OCR trace=... step=snapshotPublished`
- `FULL_OCR trace=... step=workerStarted`
- `FULL_OCR trace=... step=heartbeat`

写真画面のDEBUG表示には、Store ID、Coordinator ID、Repository ID、最後の開始時刻、開始plan、開始結果、作成jobID、再取得できたjobID、terminal state、エラー、worker開始時刻を表示する。個別写真名、写真パス、OCR全文は表示しない。
