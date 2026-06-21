# Batch OCR中断・再開設計

## 目的

読取タブの20 / 50 / 100 / 500 / 2,000件読取中にアプリがバックグラウンドへ移行しても、完了済み結果を保持し、残りだけを続きから再開できるようにする。

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

## 端末状態からの自動再開

ユーザー操作ではなく端末状態で止まった場合は、条件が回復した時に自動再開を試みる。

自動再開する可能性がある理由:

- バッテリー50%未満
- 低電力モード
- 端末温度
- 空き容量不足
- アプリが前面でない
- 端末状態による一時停止

自動再開しない理由:

- ユーザー操作で一時停止した
- ユーザー操作で処理を終了した
- 恒久失敗
- キャンセル中

自動再開条件:

- 自動継続ON
- アプリがforeground / active
- 低電力モードOFF
- バッテリー50%以上
- thermal state が `nominal` または `fair`
- 空き容量2GB以上を推奨
- 実行中の別Jobがない
- `pending` / `failedRetryable` item、または次の2,000件候補がある

thermal `fair` では低速再開できる。`serious` / `critical` では待機する。

読取タブには「端末の状態を見て一時停止しています」「条件が整うと自動で続きから再開します」を表示する。手動の `続きから再開` は残すが、条件が悪い時は開始せず理由を表示する。

## この処理を終了

`この処理を終了` は未処理分を止める操作であり、完了済みOCR結果は残す。写真本体、元動画、検索インデックス、分類、不要候補、メモ、タグは削除しない。

## DEBUG検証

DEBUGビルド限定でP2検証を用意する。

- 100件ジョブを途中で `pausedBackground` にする
- `pausedBackground` から続き再開し、残りだけ完了する
- `processing` itemを `pending` へ戻す復旧を確認する
- `この処理を終了` で完了済み結果が残ることを確認する

検証証跡は `evidence/batch_ocr_p2_validation/` に保存する。

P3では同じ仕組みで、500件と2,000件の完了、500件と2,000件の中断・再開を検証する。証跡は `evidence/batch_ocr_p3_validation/` に保存する。

## 2,000件自動継続の再開

`自動で次の2,000件へ進む` がONの場合でも、バックグラウンドや端末状態の悪化では無理に続けない。

再開順序:

1. 未完了の `BatchOCRJob` がある場合は、そのJobの `pending` / `failedRetryable` だけを再開する
2. 未完了Jobがなく、2,000件完了後の自動継続待ちなら、次の2,000件Jobを新しく作る
3. 未読取候補が0件なら `completedNoMoreTargets` として表示し、0件Jobは作らない

自動継続中も1つのJobは最大2,000件までに固定する。2,000件を超える巨大Jobは作らない。

端末状態:

- thermal `fair`: 停止せず低速運転する
- thermal `serious`: 現在の1件を保存後に `pausedDeviceCondition` として一時停止する
- thermal `critical`: 安全停止し、続きから再開できる状態にする
- 低電力モードON: 自動継続を開始しない
- 空き容量2GB未満: 自動継続を開始しない
- background: 自動継続を開始しない

## 読取状態再確認

読取結果キャッシュを削除しなくても500件/2,000件読取を開始できるように、設定画面に「読取状態を再確認」を用意する。

この操作で行うこと:

- SearchDocumentだけがある写真を読取済み扱いしないよう、対象抽出状態を再確認する
- OCR本文や文字なし判定を保持する
- 検索インデックスを削除しない
- 手動分類、不要候補、メモ、タグを保持する
- 古い空のcompleted状態やstaleなprocessing状態だけを未読取扱いに戻す
- 無効な0件ジョブや旧全数OCR由来の状態を通常UIから外す

この操作で行わないこと:

- 写真アプリ内の元写真・元動画を削除/変更しない
- OCR本文を削除しない
- 文字なし判定を削除しない
- 検索インデックスを全削除しない
- 手動分類や表示状態を削除しない
