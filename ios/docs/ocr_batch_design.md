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

P1では `20件`、`50件`、`100件` を同じ `BatchOCRJob` で動かす。処理の違いは `requestedLimit` だけにする。

`500件` と `2,000件（長時間）` はP3で有効化する。通常UIには選択肢として表示してもよいが、P1では準備中として重い処理を開始しない。

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

P1では次の状態になったitem数が `plannedCount` に達したら完了とする。

- `completedText`
- `completedNoText`
- `failedRetryable`
- `failedPermanent`
- `skippedAlreadyOCRed`

`completedNoText` は失敗ではない。文字が見つからない写真を毎回再処理しないため、明示的に保存する。

`failedRetryable` は再試行可能な失敗として残す。P1ではジョブ完了表示の処理済み数に含め、失敗分再試行は次段階で扱う。

## バックグラウンド移行

初回リリースではバックグラウンドで読取を続けない。

P1ではバックグラウンドへ移行したら、実行中ジョブを一時停止予定状態にして保存する。`processing` 中のitemは将来再開しやすいよう `pending` に戻す。

復帰後は読取タブで次のように表示する。

```text
文字読取は一時停止中です
84 / 500件完了
残り416件
[続きから再開]
[この処理を終了]
```

「この処理を終了」は未処理分を破棄するだけで、完了済みOCR結果は残す。

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
