# Batch OCR中断・再開設計

## 目的

読取タブの20 / 50 / 100件読取中にアプリがバックグラウンドへ移行しても、完了済み結果を保持し、残りだけを続きから再開できるようにする。

写真アプリ内の元写真・元動画は削除・変更しない。読取結果、検索インデックス、分類、不要候補、メモ、タグも中断処理では削除しない。

## 状態遷移

バックグラウンド移行時は `.inactive` では止めず、`.background` で次のように保存する。

```text
running
↓
pausing
↓
実行中タスクを止める
↓
processing itemをpendingへ戻す
↓
pausedBackgroundとして保存
```

ユーザーが一時停止した場合は `pausedUser` として保存する。

## 起動時復旧

起動時に古いジョブを読み込んだ時、次のように復旧する。

- `running` / `pausing` / `cancelling` のまま残ったジョブは `pausedBackground` にする
- `processing` itemは `pending` に戻す
- `completedText` / `completedNoText` / `failedPermanent` / `skippedAlreadyOCRed` は保持する
- 完了済みOCR結果は削除しない

## 進捗計算

```text
処理済み = completedText + completedNoText + failedPermanent + skippedAlreadyOCRed
残り = plannedCount - 処理済み
```

`processing` は処理済みに含めない。`failedRetryable` は再開時の再処理候補として扱う。

## 再開

`続きから再開` は `pending` と `failedRetryable` のitemだけを処理する。完了済み、文字なし判定済み、恒久失敗、既読取スキップ済みのitemは再処理しない。

## この処理を終了

`この処理を終了` は未処理分を止める操作であり、完了済みOCR結果は残す。写真本体、元動画、検索インデックス、分類、不要候補、メモ、タグは削除しない。

## DEBUG検証

DEBUGビルド限定でP2検証を用意する。

- 100件ジョブを途中で `pausedBackground` にする
- `pausedBackground` から続き再開し、残りだけ完了する
- `processing` itemを `pending` へ戻す復旧を確認する
- `この処理を終了` で完了済み結果が残ることを確認する

検証証跡は `evidence/batch_ocr_p2_validation/` に保存する。
