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
- 低電力モード、発熱、メモリ警告、空き容量不足で一時停止する
- 完了分だけ保存し、未処理分は未処理のまま残す

目的は、検索に効きやすい写真から安全にOCR対象を広げることである。

### 全数高精度OCR

上級者向けモード。入口はメニューに置くが、初期状態ではスマート全数OCRと同じ安全な永続ジョブ経路を通す。高めの画像サイズや再OCRを広く許可する本格的な高精度化は、実機でスマート全数OCRの安定性を確認した後に拡張する。

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

`スマート全件OCR` と `全件高精度OCR` は、強い安全確認ゲートの奥に置く。開始前に長時間実行、発熱、iCloud取得、元写真・元動画を変更しないことを明示する。

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
  - `pending`
  - `running`
  - `paused`
  - `completed`
  - `cancelled`
  - `failed`
- `createdAt`
- `updatedAt`
- `totalCount`
- `completedCount`
- `textFoundCount`
- `noTextCount`
- `skippedCount`
- `cloudPendingCount`
- `failedCount`
- `pausedReason`

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

- 完了件数
- 文字あり件数
- 文字なし件数
- iCloud待ち件数
- 失敗件数
- 一時停止理由
- 最終更新時刻

写真グリッドは、現在表示中セルのOCRバッジだけ必要に応じて更新する。OCR進捗が進むたびに、写真一覧ページ、件数チップ、カテゴリチップを全更新しない。

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
