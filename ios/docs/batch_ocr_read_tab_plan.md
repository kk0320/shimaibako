# 読取タブとBatch OCR計画

## 方針

`feature/persistent-full-ocr` で検証したライブラリ全体OCRは、リリース前機能として採用しない。実機では発熱、処理時間、状態管理、UI復旧が重くなりすぎたためである。

今後は `main` から作成した `feature/persistent-batch-ocr` で、最大2,000件までの「まとめてOCR」を段階的に実装する。写真本体、元動画、写真アプリ側のアルバム、iCloud写真の原本は削除・変更しない。OCR結果、検索インデックス、分類、不要候補、メモ、タグはしまい箱内のアプリデータとして扱う。

## 残す土台

- SQLite写真インデックス
- PhotoGridへ全件配列を渡さないページング構造
- 28,000件規模での写真一覧高速化
- 元写真・元動画を削除・変更しない安全方針
- OCR結果、検索インデックス、分類、不要候補、メモ、タグをアプリ内データとして扱う方針

## 持ち込まないもの

- ライブラリ全体を対象にしたOCR
- 高精度で全ライブラリを処理するOCR
- 全体OCR専用の管理画面
- 全体OCR専用heartbeat
- 全体OCRの自動復旧
- 0/0 completed job 対策の複雑な状態管理
- ダミー全体OCRの通常UI
- 写真タブに重いOCR進捗を表示する仕組み
- 写真タブ全体を disabled / hitTesting false にする仕組み
- 全ライブラリ対象の自動OCRジョブ作成

## タブ構成

ユーザー表示では `OCR` ではなく `読取` を使う。内部コードや型名は既存資産との互換のため `OCR` のままでよい。

```text
写真
検索
読取
設定
```

### 写真タブ

写真タブは「見る・分類する」に限定する。

置くもの:

- 写真一覧
- カテゴリ/表示状態フィルター
- 不要候補
- 非表示
- 整理済み
- 写真詳細

置かないもの:

- OCR実行ボタン
- OCR進捗カード
- OCR結果削除
- 全体OCR表示
- 大きな検索インデックス作成カード

必要な場合だけ、小さく次の案内を表示する。

```text
文字検索用の読取は「読取」タブで実行できます
```

### 検索タブ

検索タブは「探す」に限定する。

置くもの:

- キーワード検索
- OCR文字検索
- カテゴリ検索
- 検索結果

OCR未処理が多い場合は、小さく次の案内を出す。

```text
未読取の写真があります。
文字検索の精度を上げるには、読取タブで文字を読み取ってください。
```

### 読取タブ

OCR操作は読取タブへ集約する。

画面タイトル:

```text
文字を読み取る
```

説明文:

```text
写真内の文字を端末内で読み取り、あとから検索できるようにします。
元写真・元動画は変更されません。
```

表示するもの:

- 読取済み件数
- 未読取件数
- 文字あり件数
- 文字なし件数
- 失敗件数
- 検索データ状態
- 20 / 50 / 100 / 500 / 2,000件の選択
- まとめて文字を読み取る
- 中断中ジョブの再開
- 失敗分の再試行

件数の位置づけ:

```text
20件
50件
100件
500件
2,000件（長時間）
```

推奨表示:

```text
おすすめ: 100件
多め: 500件
長時間: 2,000件
```

### 設定タブ

設定タブは管理・復旧・安全説明に限定する。

置くもの:

- OCR結果削除
- 検索インデックス修復
- ジョブ状態整理
- Debug項目
- プライバシー説明
- 元写真・元動画を変更しない説明

危険操作に見えるものは読取タブに置かない。

## BatchOCRJob

20 / 50 / 100 / 500 / 2,000件は同じ `BatchOCRJob` で動かし、件数上限だけを変える。

### Job

```text
id
state
requestedLimit
plannedCount
processedCount
completedTextCount
completedNoTextCount
failedCount
createdAt
startedAt
updatedAt
pausedReason
filterSnapshot
recognitionProfileVersion
```

### Item

```text
jobID
assetIdentifier
ordinal
state
attemptCount
sourceRevision
lastErrorCode
updatedAt
```

### Job state

```text
preparing
running
pausing
pausedBackground
pausedUser
cancelling
completed
failed
```

### Item state

```text
pending
processing
completedText
completedNoText
failedRetryable
failedPermanent
skippedAlreadyOCRed
```

## 重要ルール

- 対象は開始時に `asset localIdentifier` で固定保存する
- 2,000件を超えて自動継続しない
- 対象0件ならジョブを作らない
- 0/0 completed job は作らない、表示しない
- `processing` のままアプリ終了したitemは起動時に `pending` へ戻す
- 完了済みitemは再処理しない
- 文字なしitemも再処理しない
- `failedRetryable` と `failedPermanent` を分ける
- `failedPermanent` は完了を妨げない
- OCR結果保存はupsertにして二重保存を避ける
- OCR結果、SearchDocument、PhotoRecordを壊さない

## 完了の定義

次の終端状態になったitem数が `plannedCount` に達したら完了とする。

- `completedText`
- `completedNoText`
- `failedPermanent`
- `skippedAlreadyOCRed`

表示上の計算は分ける。

```text
targetCount = plannedCount
processedCount = 終端状態に達した数
withTextCount = completedText
noTextCount = completedNoText
failedCount = failedPermanent + failedRetryableのうち最終扱い
```

「処理済み」「成功」「文字あり」を混ぜない。

## バックグラウンド移行

初回リリースではバックグラウンドでOCRを続けることを目指さない。

```text
バックグラウンドへ移行
↓
安全に一時停止
↓
状態を保存
↓
復帰後にユーザーが再開
```

バックグラウンド移行時:

```text
running
↓
pausing
↓
現在の画像要求/Vision要求を止める
↓
processing中のItemをpendingへ戻す
↓
pausedBackgroundとして保存
```

復帰後の表示:

```text
文字読取は一時停止中です
84 / 500件完了
残り416件
[続きから再開]
[この処理を終了]
```

「この処理を終了」は未処理分を破棄するだけである。完了済みOCR結果は残す。

## 起動時処理

起動時にやること:

- ローカルDBを開く
- 保存済み写真一覧をすぐ表示する
- 写真権限を確認する
- `pausedBackground` のOCRジョブを復元する
- PhotoKit差分状態を確認する
- 差分だけを小さく反映する
- 変更された写真だけ検索データ更新する

起動時にやらないこと:

- 全写真再取得
- 全検索インデックス再構築
- カテゴリ全件再集計
- 旧JSON移行の再実行
- OCRの自動再開
- ライブラリ全体OCR系ジョブ復旧

## PhotoKit差分同期

写真同期はライブラリ全体の大きさではなく変更量に比例させる。

状態を分ける。

```text
LibrarySyncState
SearchIndexState
BatchOCRState
```

方針:

- アプリ実行中はPhotoKit change observerで差分取得する
- 起動時は可能なら前回同期情報で差分確認する
- 差分が小さい場合のみDBを増分更新する
- tokenが使えない、権限変更などで信頼できない場合でも即全件再構築しない
- 全件再構築は設定の「データ管理」からユーザー操作で実行する

写真タブのpull-to-refreshは削除する。右上更新ボタンがある場合、通常タップでは未反映のPhotoKit差分確認だけ行う。

全件再構築は設定内の深い場所へ移す。

```text
設定
  データ管理
    写真情報を再構築
```

確認ダイアログ必須。

## 検索インデックス

可能ならSQLite FTS5を検討する。

- OCR結果保存時にSearchDocument/FTSを増分更新する
- 起動時に全件インデックス準備ジョブを走らせない
- OCR、メモ、タグ、分類が変わった写真だけ検索データ更新する
- indexVersionが変わっても小分け更新する
- 古い検索データは更新完了まで利用可能にする

検索インデックス状態は写真タブに大きく出さない。必要なら読取タブか設定に小さく表示する。

## 実装順序

### P0: 土台確認

- `main` から `feature/persistent-batch-ocr` を作成する
- `feature/persistent-full-ocr` はmergeしない
- SQLite/PhotoGrid高速化がmainにあるか確認する
- 全体OCR実験コードがmainにないか確認する
- safety check
- xcodebuild build

### P1: 軽量な写真差分同期

- 起動時の重い再読み込みを止める
- pull-to-refresh削除
- PhotoKit差分同期
- 全件再構築を設定へ移動
- LibrarySyncState / SearchIndexState / BatchOCRState を分離

### P2: 読取タブの器

- `写真 / 検索 / 読取 / 設定`
- 可能なら標準 `TabView` を優先
- 写真タブからOCR操作を外す
- 読取タブにOCR状態/開始/再開UIを集約

### P3: BatchOCRJob最小実装

- 20 / 50 / 100件から開始
- 同じBatchOCRJobで動かす
- 対象固定
- `pausedBackground`
- 復帰後に続きから再開
- 強制終了後の復旧
- `completedText` / `completedNoText` / failed系の終端管理

### P4: 500 / 2,000件対応

- 500件
- 2,000件
- 自動継続なし
- 2,000件は長時間扱い
- 実機で中断/再開確認

### P5: 検索FTS/増分検索

- OCR結果保存時に検索データ増分更新
- 重い検索インデックス準備ジョブをなくす/縮小
- 検索タブでOCR結果検索確認

### P6: 実機ハードニング

- K Phoneで500件
- K Phoneで2,000件
- バックグラウンド
- 強制終了
- 再起動
- 失敗再試行
- 発熱
- メモリ
- 写真タブ操作性
