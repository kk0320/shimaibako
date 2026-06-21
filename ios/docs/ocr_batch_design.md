# まとめて読取設計

## 目的

大量写真ライブラリで、ライブラリ全体を一度にOCRしない。ユーザーが読取タブで件数上限を選び、端末状態を見ながら小分けに文字を読み取る。

ユーザー表示では `読取` を使う。内部コードや既存DBの互換では `OCR` という名前を使ってよい。

## 通常UIのメニュー

通常UIでは次の範囲だけを扱う。

- `20件`
- `50件`
- `100件`
- `500件`
- `2,000件（長時間）`

1つの `BatchOCRJob` は最大2,000件までにする。ユーザーが `自動で次の2,000件へ進む` を明示的にONにした場合だけ、2,000件完了後に端末状態を確認して次の2,000件ジョブを作る。28,000件などを1つの巨大ジョブとして作る全数読取は通常UIに戻さない。

## 置き場所

OCR操作は写真タブから外し、読取タブへ集約する。

写真タブ:

- 写真一覧
- カテゴリ/表示状態フィルター
- 写真詳細
- 不要候補、非表示、整理済み

読取タブ:

- 読取済み件数
- 未読取件数
- 文字あり件数
- 文字なし件数
- 失敗件数
- 検索データ状態
- 件数選択
- まとめて文字を読み取る
- 自動で次の2,000件へ進むON/OFF
- 中断中ジョブの再開
- 失敗分の再試行

設定タブ:

- OCR結果削除
- 検索インデックス修復
- ジョブ状態整理
- Debug項目
- 安全説明

## BatchOCRJob

P3では `20件`、`50件`、`100件`、`500件`、`2,000件（長時間）` を同じ `BatchOCRJob` で動かす。処理の違いは `requestedLimit` だけにする。

`2,000件（長時間）` は開始前に確認を表示する。自動継続OFFでは2,000件完了後に止まる。自動継続ONでは、完了後に端末状態、低電力モード、空き容量、アプリ状態、未読取候補を確認し、条件が良い場合だけ次の2,000件ジョブを作る。ライブラリ全体を対象にした全数読取は通常UIに戻さない。

保存する項目:

- `id`
- `state`
- `requestedLimit`
- `plannedCount`
- `processedCount`
- `completedTextCount`
- `completedNoTextCount`
- `failedCount`
- `createdAt`
- `startedAt`
- `updatedAt`
- `pausedReason`
- `filterSnapshot`
- `recognitionProfileVersion`

## BatchOCRSeries

2,000件ジョブを安全に連結するため、単発Jobとは別に `BatchOCRSeries` を持つ。

- `id`
- `state`
- `autoContinueEnabled`
- `batchLimit = 2000`
- `createdAt`
- `updatedAt`
- `lastJobID`
- `totalProcessedInSeries`
- `remainingEstimate`
- `pausedReason`

stateは `idle`、`running`、`waitingForNextBatch`、`pausedDeviceCondition`、`pausedUser`、`completedNoMoreTargets`、`failed` を使う。

自動継続は初期OFFとし、ONにする時は確認を出す。ONでも1つのJobは必ず2,000件以下に固定し、未読取候補が0件なら0件Jobを作らない。

## BatchOCRItem

対象は開始時に `asset localIdentifier` で固定する。

- `jobID`
- `assetIdentifier`
- `ordinal`
- `state`
- `attemptCount`
- `sourceRevision`
- `lastErrorCode`
- `updatedAt`

写真本体、サムネイル本体、元動画本体は保存しない。

## 状態

Job state:

- `preparing`
- `running`
- `pausing`
- `pausedBackground`
- `pausedUser`
- `cancelling`
- `completed`
- `failed`

Item state:

- `pending`
- `processing`
- `completedText`
- `completedNoText`
- `failedRetryable`
- `failedPermanent`
- `skippedAlreadyOCRed`

## 完了判定

表示上の処理済み数は、次の終端状態になったitem数で計算する。

- `completedText`
- `completedNoText`
- `failedPermanent`
- `skippedAlreadyOCRed`

`completedNoText` は失敗ではない。文字が見つからない写真を毎回再処理しないため、明示的に保存する。

`failedRetryable` は再試行可能な失敗として残し、処理済み数には含めない。再開時は `pending` と同じく再処理候補にできる。

```text
処理済み = completedText + completedNoText + failedPermanent + skippedAlreadyOCRed
残り = plannedCount - 処理済み
```

## バックグラウンド移行

初回リリースではバックグラウンドで読取を続けない。

P2ではバックグラウンドへ移行したら、実行中ジョブを安全に `pausedBackground` として保存する。`.inactive` では止めず、実際に `.background` へ移った場合だけ中断する。

```text
running
↓
pausing
↓
現在処理中のタスクを止める
↓
processing中のitemをpendingへ戻す
↓
pausedBackgroundとして保存
```

強制終了や再起動後に `running` / `pausing` の古いジョブが残っている場合も、起動時に `pausedBackground` へ復旧する。`processing` itemは `pending` に戻し、完了済みOCR結果は保持する。

復帰後は読取タブで次のように表示する。

```text
文字読取は一時停止中です
84 / 100件完了
残り16件
理由: アプリがバックグラウンドへ移行したため
[続きから再開]
[この処理を終了]
```

`続きから再開` は `pending` と `failedRetryable` のitemだけ処理する。`completedText`、`completedNoText`、`failedPermanent`、`skippedAlreadyOCRed` は再処理しない。

`この処理を終了` は未処理分を終了扱いにするだけで、完了済みOCR結果は残す。写真本体、元動画、検索インデックス、分類、不要候補、メモ、タグは削除しない。

## 自動継続と端末状態

自動継続の条件:

- 自動継続ON
- 現在の2,000件Jobが `completed`
- 未読取候補が残っている
- アプリがforeground / active
- 低電力モードOFF
- thermal state が `nominal` または `fair`
- 空き容量2GB以上を推奨

thermal `fair` では停止せず、1件ごとの休みを長めにして低速運転する。`serious` では現在の1件を保存後に一時停止し、`critical` では安全停止して続きから再開できる状態にする。

自動継続判定は、`BatchOCRJobService` がJobを `completed` に保存した直後に実行する。完了カード、読取タブ表示、View更新、ユーザーが画面を開いていることには依存しない。

`autoContinueEnabled` は設定値を基準に参照する。snapshotに古い `BatchOCRSeries.autoContinueEnabled` が残っていても、サービス起動時に設定値と同期し、UI上はONなのにサービス側ではOFFとして扱われる状態を避ける。

条件OKの場合は、手動2,000件開始と同じ未読取候補抽出を使って次の `BatchOCRJob` を作る。条件NGの場合は `pausedDeviceCondition` または `completedNoMoreTargets` として保存し、0件Jobは作らない。

DEBUGビルドでは `AUTO_CONTINUE decision` ログに、ON/OFF、完了Job ID、候補件数、thermal、低電力、空き容量、アプリ状態、既存Job状態、判断結果、理由を残す。

バックグラウンド移行時は自動継続を開始せず、`pausedBackground` または `pausedDeviceCondition` として保存する。次回起動後、ユーザーが `続きから再開` を押した場合だけ、未完了Jobを優先して再開し、未完了Jobがなければ次の2,000件Jobを作る。

## 端末状態からの自動再開

端末状態による一時停止は、安全のため維持する。ただし、条件が回復した場合は、ユーザーが放置していても進み続けられるように自動再開を試みる。

自動再開してよい停止理由:

- バッテリー50%未満
- 低電力モード
- thermal stateが高い
- 空き容量不足
- アプリが前面でない
- 端末状態による一時停止

自動再開しない停止理由:

- ユーザー操作による一時停止
- ユーザー操作による終了
- 恒久失敗
- キャンセル中

自動再開条件:

- `autoContinueEnabled == true`
- 一時停止理由が端末状態由来である
- アプリがforeground / active
- 低電力モードOFF
- バッテリー50%以上
- thermal state が `nominal` または `fair`
- 空き容量2GB以上を推奨
- 実行中の別Jobがない
- `pending` / `failedRetryable` item、または次Batch候補がある

thermal `fair` では再開してよいが、低速運転とする。`serious` / `critical` では自動再開しない。

自動再開の順序:

1. 未完了の `BatchOCRJob` があれば、その `pending` / `failedRetryable` だけ再開する
2. 未完了Jobがなく、2,000件自動継続の次Batch待ちなら、次の2,000件Jobを作る
3. 未読取候補がなければ `completedNoMoreTargets` とし、0件Jobは作らない

読取タブには「自動再開待機中」「最後の確認」「次の確認」を表示する。DEBUGビルドでは `AUTO_RESUME check` ログに、停止理由、バッテリー、低電力、thermal、空き容量、アプリ状態、判断結果、理由を残す。

## P2検証

DEBUGビルド限定でP2自己検証を用意する。

- 100件ジョブを途中で `pausedBackground` にする
- `processing` itemを `pending` へ戻す
- `pausedBackground` から続き再開し、残りだけ完了する
- `pausedUser` のジョブで「この処理を終了」し、完了済み結果を保持する
- 検証結果は `batch_ocr_p2_validation_report.json` に保存する
- 証跡は `evidence/batch_ocr_p2_validation/` に保存する

## P3検証

DEBUGビルド限定でP3自己検証を用意する。

- 500件読取を同じBatchOCRJobで完了できる
- 2,000件読取を同じBatchOCRJobで完了できる
- 500件読取の中断・再開がP2と同じ仕組みで動く
- 2,000件読取の中断・再開がP2と同じ仕組みで動く
- 検証結果は `batch_ocr_p3_validation_report.json` に保存する
- 証跡は `evidence/batch_ocr_p3_validation/` に保存する

自動継続はDEBUGビルド限定の検証で確認する。

- 2,000件完了後に次の2,000件Jobを作る
- 自動継続OFFでは次Jobを作らない
- thermal fairでは停止せず次の2,000件Jobを作る
- 未読取0件では0件Jobを作らない
- thermal seriousでは一時停止する
- 低電力モードでは一時停止する
- 途中Jobがある場合は新しいJobを作らず既存Jobを再開する
- 検証結果は `batch_ocr_auto_continue_validation_report.json` に保存する
- 証跡は `evidence/batch_ocr_auto_continue_validation/` に保存する

## 対象抽出と読取状態

BatchOCRの対象抽出では、読取結果キャッシュと検索インデックスを分けて扱う。

- 読取結果キャッシュ: OCR本文、文字なし判定、失敗情報
- 検索インデックス: OCR結果、分類、メモ、タグなどから作った検索用データ

除外してよいもの:

- OCR本文が保存されている写真
- 文字なし判定済みの写真
- 現在処理中の写真
- 進行中ジョブのpending/processing item

除外してはいけないもの:

- SearchDocumentだけが存在する写真
- PhotoIndexRecordだけが存在する写真
- カテゴリ分類だけがある写真
- メモやタグだけがある写真
- 旧JSON/SQLite移行済みというだけの写真

古い全数OCR実験などで、OCR本文も処理日時もない空の `completed` 状態が残っている場合はstale状態として扱い、未読取候補に戻す。既存のOCR本文や文字なし判定は削除しない。

対象0件時は、単にボタンを止めるだけでなく、読取済み/文字なし/処理中などの理由を表示する。

DEBUGビルド限定で対象抽出検証を用意する。

- 検索データのみ写真の対象化
- キャッシュ削除なし500件対象抽出
- キャッシュ削除なし2,000件対象抽出
- 0件対象

証跡は `evidence/batch_ocr_target_selection_validation/` に保存する。

## 検索インデックス連携

読取結果保存時に、対象写真の検索データだけを増分更新する。

- 読取本文
- 読取状態
- 文字あり/文字なし
- カテゴリ
- スクショ細分類
- メモ
- タグ

起動時に全件検索インデックス準備ジョブを走らせない。indexVersion変更時も、小分け更新または設定内の修復操作に寄せる。

## 安全方針

- 読取は端末内で実行する
- 写真は外部送信しない
- 写真アプリ内の元写真・元動画は削除・変更しない
- iCloud取得を許可している場合、iOSの写真機能がAppleのiCloudから画像を取得することがある
- 発熱、低電力モード、空き容量不足、アプリ状態変化では安全側に中断する
- 0件対象ではジョブを作らない
- 0/0 completed job は作らない、表示しない

## やってはいけないこと

- ライブラリ全体を対象にした読取を通常UIに戻す
- 2万件以上を一度に処理する読取ジョブを作る
- 全写真の画像本体をメモリに保持する
- 読取進捗ごとに写真一覧全体を再描画する
- iCloud写真を無断で大量取得する
- 写真アプリ内の元写真・元動画を削除・変更する
