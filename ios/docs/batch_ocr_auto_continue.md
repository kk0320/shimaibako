# 2,000件読取の自動継続設計

## 目的

2,000件の読取が完了したあと、端末状態が良い場合だけ次の2,000件を続けて読めるようにする。

これは全数読取ではない。28,000件などを1つの巨大ジョブとして作らず、常に最大2,000件の `BatchOCRJob` を1つずつ作る。

## UI

読取タブに `自動で次の2,000件へ進む` を表示する。

- 初期値はOFF
- ONにする時は確認を出す
- 説明では、発熱、低電力、空き容量不足、バックグラウンドでは一時停止することを伝える
- 元写真・元動画は変更されないことを明記する

## 内部状態

単発の `BatchOCRJob` とは別に `BatchOCRSeries` を保存する。

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

`autoContinueEnabled` は設定値を永続保存し、ジョブ状態を読み込む時も最新の設定値を優先する。古いsnapshot内の `BatchOCRSeries.autoContinueEnabled` が残っていても、設定画面のON/OFFとサービス側の判定がずれないようにする。

state:

- `idle`
- `running`
- `waitingForNextBatch`
- `pausedDeviceCondition`
- `pausedUser`
- `completedNoMoreTargets`
- `failed`

## 自動継続条件

次の条件をすべて満たす場合だけ、次の2,000件Jobを作る。

- 自動継続ON
- 現在の2,000件Jobが完了している
- 未読取候補が残っている
- アプリがactive
- 低電力モードOFF
- thermal stateが `nominal` または `fair`
- 空き容量2GB以上を推奨

未読取候補が0件の場合は `completedNoMoreTargets` とし、0件Jobは作らない。

自動継続判定は `BatchOCRJobService` の完了処理内で行う。読取タブの表示、完了カードの表示、ユーザーが画面を開いていることには依存しない。

処理順:

1. 現在のJobを `completed` として保存する
2. `autoContinueEnabled` と `BatchOCRSeries` の状態を確認する
3. 端末状態と未読取候補を確認する
4. 条件OKなら次の2,000件 `BatchOCRJob` を作る
5. 条件NGなら `pausedDeviceCondition` または `completedNoMoreTargets` として保存する

自動継続時の対象抽出は、手動で2,000件読取を開始する時と同じ未読取候補抽出経路を使う。写真タブの表示中配列やViewの状態は使わない。

判断内容はDEBUGログに `AUTO_CONTINUE decision` として残す。ログにはON/OFF、完了Job ID、候補件数、thermal、低電力、空き容量、アプリ状態、既存Job状態、判断結果、理由を含める。

## 端末状態

- `nominal`: 通常
- `fair`: 停止せず低速運転
- `serious`: 現在の1件を保存後に一時停止
- `critical`: 安全停止し、続きから再開できる状態にする

低電力モードON、空き容量不足、バックグラウンド移行時は自動継続を開始しない。

## 再開

`続きから再開` の順序:

1. 未完了の `BatchOCRJob` があれば、それを再開する
2. 未完了Jobがなく、自動継続待ちなら次の2,000件Jobを作る
3. 未読取候補がなければ完了表示にする

完了済みの読取結果、検索データ、分類、不要候補、メモ、タグは削除しない。

## 安全方針

- 元写真・元動画は削除・変更しない
- PhotoKit書き込み/削除APIを使わない
- 外部API、クラウドDB、外部送信、有料サービスを使わない
- 写真タブへ読取操作を戻さない
- 全数読取、スマート全数読取、全数高精度読取は通常UIに戻さない

## DEBUG検証

DEBUGビルド限定で以下を確認する。

- 2,000件完了後に次の2,000件Jobを作る
- 自動継続OFFでは次Jobを作らない
- thermal fairでは停止せず次の2,000件Jobを作る
- 未読取0件で停止する
- thermal seriousで停止する
- 低電力モードで停止する
- 途中Jobがある場合は既存Jobを再開する

証跡保存先:

```text
evidence/batch_ocr_auto_continue_validation/
```
