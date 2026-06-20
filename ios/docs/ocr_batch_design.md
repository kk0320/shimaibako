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

2,000件を超えて自動継続しない。対象候補が2,000件を超える場合も、開始時に固定する対象は最大2,000件までにする。

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

`2,000件（長時間）` は開始前に確認を表示する。2,000件を超えて自動継続しない。ライブラリ全体を対象にした全数読取は通常UIに戻さない。

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
