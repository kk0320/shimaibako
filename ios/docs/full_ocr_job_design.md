# フルOCRジョブ設計

## 位置づけ

この文書は `feature/persistent-full-ocr` ブランチで追加した永続OCRジョブの設計と、実機検証で見るべき点をまとめる。

全数OCRは重い処理のため、写真一覧や検索とは独立したジョブとして保存し、一時停止、再開、終了できる構成にする。`main` へmergeする前にK Phone実機で長時間動作を確認する。

## 目的

3万枚規模の写真ライブラリでも、端末を固めず、発熱やバッテリー消費を抑えながら、OCR済み写真を少しずつ増やす。

写真本体、元動画、写真アプリ側のアルバム、iCloud写真の原本は削除・変更しない。OCRは端末内で実行し、外部送信しない。

## OCRモード

### スマート全件OCR

初期実装で優先する全体OCRモード。検索に効きやすい写真から順に、端末内で少しずつOCRする。

- スクショ、書類写真候補、領収書候補、名刺候補、看板候補、ホワイトボード候補を優先する
- 一般写真は後回しにする
- OCR済み、処理中、`completedNoText` は既定で再処理しない
- iCloud上の写真は、設定がオフライン優先なら `cloudPending` として残す
- 1件ずつ処理し、端末状態が良い場合だけ将来2並列を検討する
- thermal fairでは停止せず減速し、thermal serious/criticalでは一時停止または停止する
- 低電力モード、メモリ警告、空き容量不足では一時停止する
- 完了分だけ保存し、未処理分は未処理のまま残す

目的は、検索に効きやすい写真から安全にOCR対象を広げることである。

### 全数高精度OCR

上級者向けモード。入口はメニューに置くが、主役にはしない。非常に時間がかかり、発熱とバッテリー消費が大きくなるため、通常はスマート全数OCRを推奨する。高めの画像サイズや再OCRを広く許可する本格的な高精度化は、実機でスマート全数OCRの安定性を確認した後に拡張する。

- すべての画像を対象にする
- OCR済みも必要に応じて再OCR対象にできる
- Visionの高精度設定、複数言語、必要なら高めの画像サイズを使う
- 充電中、低電力モードOFF、発熱なし、空き容量2GB以上、Wi-Fi推奨を必須に近い条件にする
- iCloud取得を許可した場合は通信量注意を強く表示する
- 実行前に推定件数、推定時間、注意事項を表示し、明示確認を必須にする

写真本体、元動画、写真アプリ側のアセットは削除・変更しない。

## メニュー構成案

OCRメニューは段階的に見せる。

1. `20件`
2. `50件`
3. `100件`
4. `現在の絞り込み結果すべて`
5. `スマート全件OCR`
6. `全件高精度OCR`

`20件`、`50件`、`100件` は従来どおり表示中候補からの小分けOCRで実行する。

`現在の絞り込み結果すべて` は、検索条件、表示状態、カテゴリ、スクショ細分類を固定した永続ジョブとして作る。処理開始時に対象IDを保存し、途中で画面の検索条件が変わってもジョブ対象は変えない。

`スマート全件OCR` と `全件高精度OCR` は、強い安全確認ゲートの奥に置く。開始前に長時間実行、発熱、iCloud取得、元写真・元動画を変更しないことを明示する。全数高精度OCRでは「スマート全数OCRに変更」導線を出し、重いモードを避けやすくする。

## OCRExecutionPlan

OCRの選択UI、確認画面、候補件数、端末状態判定、ジョブ作成は `OCRExecutionPlan` から決定する。まとめてOCRは `quick` 計画だけを使い、20/50/100件を超えない。全数OCRは `filteredAll`、`smartLibrary`、`accuracyReview` の専用計画から開始する。

クイックOCR確認画面には全数OCRの文言や大量処理向けの開始不可理由を混ぜない。Debug buildでは `OCR_PLAN kind=... workloadClass=... jobType=...` のログを出し、UI、端末状態判定、ジョブ種別が同じ計画から出ているか確認する。

開始ボタン押下後、Viewは計画を渡して確認画面を閉じる。対象抽出とジョブ作成は `OCRJobRunner` 側で行い、UIを長時間ブロックしない。

## データ構造案

### OCRJob

OCRジョブ全体の状態を保存する。

- `id`
- `scope`
  - `visibleLimit20`
  - `visibleLimit50`
  - `visibleLimit100`
  - `currentFilterAll`
  - `smartFull`
  - `fullAccurate`
- `qualityMode`
- `state`
  - `preparing`
  - `pending`
  - `running`
  - `throttled`
  - `paused`
  - `pausedThermal`
  - `pausedUser`
  - `cancelling`
  - `completed`
  - `cancelled`
  - `failed`
- `createdAt`
- `updatedAt`
- `currentPhase`
- `currentAssetIdentifier`
- `startedAt`
- `lastHeartbeatAt`
- `totalCount`
- `completedCount`
- `textFoundCount`
- `noTextCount`
- `skippedCount`
- `cloudPendingCount`
- `failedCount`
- `pausedReason`

`currentAssetIdentifier` はワーカー生存確認用の内部IDであり、UIには写真名やパスを表示しない。写真本体やサムネイルは保存しない。

### OCRProgressSnapshot

UIへはDBレコードを直接渡さず、`OCRProgressSnapshot` へ変換して渡す。

- `jobID`
- `state`
- `phase`
- `completed`
- `total`
- `textFound`
- `noText`
- `failed`
- `cloudPending`
- `skipped`
- `startedAt`
- `updatedAt`
- `lastHeartbeatAt`
- `itemsPerMinute`
- `estimatedRemainingSeconds`

分母の `total` はジョブ作成時点の対象件数で固定する。途中で写真が追加されても、実行中ジョブの分母は動かさない。

### OCRJobItem

1枚ごとのジョブ状態を保存する。

- `jobID`
- `assetIdentifier`
- `priority`
- `state`
  - `pending`
  - `fetchingImage`
  - `recognizing`
  - `completedText`
  - `completedNoText`
  - `cloudPending`
  - `retryableFailure`
  - `permanentFailure`
  - `skipped`
  - `cancelled`
- `attemptCount`
- `nextRetryAt`
- `sourceFingerprint`
- `lastErrorCode`
- `startedAt`
- `completedAt`

ジョブアイテムには写真本体、サムネイル本体、画像特徴量ベクトルを保存しない。

### OCRResult

OCR結果は既存の写真インデックスと同じ `localIdentifier` で参照できるようにする。

- `assetIdentifier`
- `rawText`
- `normalizedText`
- `resultState`
- `engineVersion`
- `recognitionProfileVersion`
- `sourceFingerprint`
- `updatedAt`

OCR本文は端末内のSQLiteと既存OCR保存経路に保存する。外部送信しない。

## OCR状態の扱い

### completedText

OCRが完了し、検索可能な文字列が得られた状態。

- `ocrText` を保存する
- `SearchDocument` にOCR本文を含める
- カテゴリとスクショ細分類を再判定する
- OCR済み件数に含める

### completedNoText

OCRは正常に終わったが、文字が見つからなかった状態。失敗ではない。

- `ocrText` は空で保存する
- `SearchDocument` にはカテゴリ、日付、メモ、タグなどの非OCR情報を維持する
- 既定では再OCR対象から除外する
- 高精度OCRや明示的な再OCRでは再処理できる

### cloudPending

iCloud上の写真を取得できなかった、またはオフライン優先のため取得しなかった状態。

- 失敗として扱わない
- iCloud取得を許可したジョブで再試行できる
- 検索インデックスには既存メタデータ、カテゴリ、メモ、タグだけを残す
- UIには「iCloud取得が必要」と分かる表示を出す

## 処理順序

スマート全件OCRでは次の優先順を使う。

1. スクショ
2. 書類写真候補
3. 領収書候補
4. 名刺候補
5. ホワイトボード候補
6. 看板候補
7. 工事写真候補
8. 未分類や一般写真
9. iCloud取得が必要な写真

iCloud写真は最後に回す。オフライン優先では `cloudPending` として残し、iCloud取得を許可した場合だけ再試行する。

## 並列数

初期実装は1並列にする。

2並列は次の条件を満たす場合だけ検討する。

- 充電中またはバッテリー50%以上
- 低電力モードOFF
- 発熱状態がnormalまたはfair
- メモリ警告が出ていない
- 空き容量2GB以上
- 実機でUIが固まらないことを確認済み

3並列以上は初期実装では行わない。

## サーマルバックオフ

発熱時は細かい中断通知を出さず、ジョブカード内に状態をまとめて表示する。

- thermal nominal: 通常実行する
- thermal fair: 停止せず、1件ごとに短い休みを入れて減速する。スマート全数OCRは短め、全数高精度OCRは長めに休む
- thermal serious: 現在処理中の1件を終えた後に一時停止し、続きから再開できる状態にする
- thermal critical: 端末保護のため停止し、進捗を保存する

同じ発熱理由のToastやAlertは連発しない。UI更新は最大で毎秒2回程度に間引き、進捗や発熱状態の変化が写真グリッド全体を再描画しないようにする。

## 一時停止条件

次を検知したらジョブを一時停止する。

- 低電力モードON
- バッテリー不足
- 発熱状態serious/critical
- メモリ警告
- 空き容量不足
- アプリのバックグラウンド移行
- ユーザーキャンセル

一時停止では完了済み結果を保存し、未開始分は `queued` のまま残す。写真本体、OCR結果、手動分類、不要候補、メモ、タグは削除しない。

## SearchDocument更新

OCR結果保存と検索文書更新は、同じ写真ID単位で小さく実行する。

- 1件完了ごとに `OCRResult` を保存する
- `completedText` の場合はOCR本文を `SearchDocument` へ反映する
- `completedNoText` の場合はOCR本文なしの状態として検索文書を更新する
- `cloudPending` の場合は既存検索文書を壊さない
- カテゴリ再判定は手動分類を上書きしない

検索文書更新の進捗は、写真グリッド全体の再描画につなげない。

## UI更新方針

OCRジョブ進捗は専用のジョブ状態として表示する。

- 状態
- 完了件数
- `completed / total`
- ProgressView
- パーセント
- 文字あり件数
- 文字なし件数
- iCloud待ち件数
- 失敗件数
- スキップ件数
- 現在のphase
- 処理速度
- 推定残り時間
- ワーカー生存状態
- 一時停止理由
- 最終更新時刻

写真グリッドは、現在表示中セルのOCRバッジだけ必要に応じて更新する。OCR進捗が進むたびに、写真一覧ページ、件数チップ、カテゴリチップを全更新しない。

OCR進捗は `OCRProgressStore` に小さな値型スナップショットとして流す。`PhotoGridView` の写真配列、件数チップ、カテゴリチップ、サムネイルパイプラインとは分離し、進捗カードだけが購読する。SwiftUIへのpublishは最大500msに1回程度に間引く。

写真画面では `OCRProgressStore.activeSnapshot` がある場合にコンパクト進捗カードを表示する。カードには状態、`completed / total`、ProgressView、パーセント、現在phase、Heartbeat、速度、残り時間、最低限の操作だけを出し、詳細は管理導線へ逃がす。`PhotoGridView` 本体は進捗storeを直接監視せず、OCRカードだけが進捗を購読する。

開始直後は、対象抽出より先に永続ジョブを `preparing` として作成し、`activeSnapshot` へpublishする。`totalCount` が0でもカードを表示し、「対象写真を確認しています」と出す。重い対象抽出やJobItem作成は、その後に進める。

全数OCRが準備中、実行中、減速中、一時停止中、終了処理中の場合、`全数OCRを管理` は有効にし、`まとめてOCR` は待機扱いにする。競合するOCR処理を同時に走らせない。

## Heartbeatと停止検出

OCRワーカーは数秒ごとに `lastHeartbeatAt`、`currentPhase`、`currentAssetIdentifier` を更新する。個人情報に近い写真名、写真パス、OCR本文、サムネイルはログやUIに出さない。

UI側の判定は次の通り。

- 5秒以内: 正常
- 5〜15秒: 現在の1件を処理中
- 15〜30秒: 処理状況を確認中
- 30秒以上: 進捗更新停止として表示

進捗更新停止時も完了済み結果は保存済みであり、元写真・元動画は削除・変更しない。ユーザーは再開、またはいったん終了を選べる。

Debug buildでは個人情報を含まない `OCR_JOB state=... completed=... total=... phase=... heartbeat=...` ログを出す。

設定画面ではOCR仕様と現在の全数OCRジョブ状態を確認できるようにする。

- クイックOCRは20/50/100件
- 現在の絞り込み結果すべてに対応
- スマート全数OCRは推奨モード
- 全数高精度OCRは上級者向け
- 全数OCRは長時間処理で、thermal fairでは減速し、thermal serious/critical、低電力モード、メモリ警告、空き容量不足では一時停止する
- OCR結果は端末内で扱い、元写真・元動画は削除・変更しない
- iCloud写真は、画像が端末上にない場合にiOSがAppleのiCloudから取得することがある

## 起動時復元

アプリ起動時に未完了ジョブを読み込み、古い `fetchingImage` / `recognizing` 相当のアイテムを `pending` に戻す。前回 `preparing` / `running` / `throttled` のまま終了したジョブは一時停止扱いにし、進捗カードで続きから再開できるようにする。

復元処理では写真本体、OCR結果、手動分類、不要候補、メモ、タグを削除しない。

復元後は `OCRProgressStore.activeSnapshot` を再作成する。写真画面とOCR runnerは同じ `OCRProgressStore` インスタンスを共有し、DEBUG buildではstore識別子とsnapshot状態をログで確認できる。

## やってはいけない実装

- 28,000件分のPHAssetやUIImageをメモリに保持する
- 全写真のPHAssetやUIImageをメモリに保持する
- 全件分のOCR対象をSwiftUI配列として公開する
- OCR進捗ごとにPhotoGrid全体を再描画する
- OCR全文を毎回全件正規化し直す
- 全件を一括トランザクションで保存する
- iCloud写真を無断で大量取得する
- 発熱、低電力、メモリ警告を無視して継続する
- 写真アプリ内の元写真・元動画を削除・変更する
- PhotoKit書き込み/削除APIを追加する

## 実装順序

1. `OCRJob` / `OCRJobItem` / `PersistentOCRResult` のSQLiteテーブルを追加する
2. アプリ起動時に古い `fetchingImage` / `recognizing` を `pending` へ戻す
3. `completedText` / `completedNoText` / `cloudPending` を保存する
4. `SearchDocument` 更新を1件単位で分離する
5. `現在の絞り込み結果すべて` を追加する
6. スマート全数OCRを安全確認ゲート付きで追加する
7. 一時停止、再開、終了、失敗分再試行、iCloud待ち再開を追加する
8. 実機で長時間確認する
9. 全数高精度OCRの本格拡張は実機結果を見て検討する
