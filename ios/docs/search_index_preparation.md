# 検索インデックス準備状態

## 背景

大規模ライブラリでは、旧JSON移行や検索ドキュメント補完が途中で止まると、次回起動時に `検索インデックスを準備しています` が繰り返し表示され、写真タブが重く見えることがある。

## 永続状態

SQLiteに `search_index_preparation_state` を保存する。

- libraryRevision
- totalCount
- completedCount
- state
- startedAt
- updatedAt
- completedAt
- lastProcessedAssetIdentifier
- lastOperation
- lastError
- schemaVersion
- indexVersion

`completedAt` があり、`completedCount >= totalCount` で、schemaVersion / indexVersion が現在値と合う場合は完了扱いにし、起動ごとに再実行しない。

## stale判定

`preparing` または `running` のまま `updatedAt` が一定時間以上古い場合は `paused` に戻す。

この処理では写真本体、OCR結果、手動分類、不要候補、メモ、タグを削除しない。検索ドキュメント不足があっても、古い処理を毎回重く再実行しない。

## 再開

検索インデックスを再確認する場合は `prepareSearchIndexIfNeeded()` を使う。SQLite内の不足検索ドキュメントだけを補完し、旧JSONを通常DBとして使い続けない。

## UI方針

起動時に実作業がない場合は、`検索インデックスを準備しています` を表示しない。移行や補完が実際に走っている時だけ進捗カードを表示する。

元写真・元動画は削除・変更しない。
