# 全数OCRジョブDB移行

## 目的

既存インストール環境でも、全数OCR用の `ocr_jobs.sqlite` に必要なテーブルとindexを安全に用意する。`no such table: ocr_jobs` で全数OCRを開始できない状態を防ぐ。

## 対象

準備対象は全数OCRジョブ用DBのみである。

- `ocr_jobs`
- `ocr_job_items`
- `ocr_results`
- OCRジョブ用index

写真インデックス、OCR結果、手動分類、不要候補、非表示、整理済み、メモ、タグ、精度向上履歴は削除しない。写真アプリ側の元写真・元動画も削除・変更しない。

## 準備タイミング

`OCRJobStore.prepareDatabaseIfNeeded()` を次のタイミングで呼ぶ。

- アプリ起動時の未完了OCRジョブ復元前
- 全数OCR確認画面の表示時
- 全数OCR開始直前
- active job確認前

処理は冪等で、複数回呼んでも既存データを消さない。

## 移行内容

- `CREATE TABLE IF NOT EXISTS` で `ocr_jobs`、`ocr_job_items`、`ocr_results` を作成する
- 既存テーブルに不足列がある場合は `ALTER TABLE ... ADD COLUMN` で補う
- `CREATE INDEX IF NOT EXISTS` で必要なindexを作成する
- 準備後に `ocr_jobs` と `ocr_job_items` の存在を検証する

DB全体削除、写真インデックス削除、OCR結果削除、手動分類削除は行わない。

## UI表示

全数OCR確認画面では、DB準備状態を表示する。

- 準備中: `OCRジョブDBを準備しています…`
- 準備完了: 開始可能
- 失敗: エラー詳細と `再試行`

準備中または失敗中は、全数OCR開始ボタンを無効にする。

## DEBUG確認

DEBUG表示では以下を見る。

- `jobDB`
- `ocr_jobs`
- `ocr_job_items`
- `lastDBError`
- `lastMigrationAt`
- `activeJob`

`jobDB: ready` かつ `activeJob: none` は正常で、未完了ジョブがない状態である。`jobDB: missingTable` や `repairFailed` の場合は、DB準備が失敗しているため、active jobなしとは区別する。

## 実機確認

1. 既存アプリへ上書きインストールする
2. スマート全数OCR確認画面を開く
3. `OCRジョブDBを準備しています…` の後に準備済み表示になることを確認する
4. DEBUG表示で `jobDB: ready`、`ocr_jobs: yes`、`ocr_job_items: yes` を確認する
5. スマート全数OCRを開始し、`OCRJob(state=preparing)` と進捗カードが表示されることを確認する

どの手順でも、元写真・元動画は削除・変更しない。
