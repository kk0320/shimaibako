# 端末内データベース設計

## 採用方式

今回の性能改善ではSQLiteを採用する。Core Dataはモデル移行や永続コンテナ設定が増えるため、既存の `PhotoIndexStoring` protocol へ安全に差し込めるSQLiteを優先した。SQLiteはiOS標準の `SQLite3` を使い、外部ライブラリは追加しない。

保存先:

```text
Application Support/ShimaiBako/photo_index.sqlite
```

旧JSON:

```text
Application Support/ShimaiBako/photo_index.json
```

旧JSONは主DBではなく、初回移行元、互換バックアップ、障害解析用に残す。

## テーブル

### photo_records

一覧、分類、集計、表示状態に必要な軽量カラムを持つ。

- `asset_identifier`
- `record_json`
- `creation_date`
- `media_type`
- `media_subtype`
- `pixel_width`
- `pixel_height`
- `display_state`
- `category`
- `screenshot_category`
- `manual_category`
- `has_ocr`
- `ocr_status`
- `classification_status`
- `analysis_version`
- `memo`
- `updated_at`
- `last_seen_at`
- `normalized_search_text`
- `is_screenshot`

`record_json` は既存 `PhotoIndexRecord` 互換のために残す。検索と集計はできるだけ個別カラムを見る。

### search_documents

検索用の正規化済みテキストを、一覧用の集計カラムと分けて持つ。

- `asset_identifier`
- `normalized_text`
- `index_version`
- `source_revision`
- `indexed_at`

旧JSON移行や既存SQLiteの初回起動時に、500件単位でバックフィルする。進捗は `IndexProgressStore` にだけ流し、写真グリッド全体の再描画にはつなげない。

### photo_texts

OCR本文を一覧用レコードから分離する。

- `asset_identifier`
- `ocr_text`
- `normalized_search_text`

一覧を開くだけでOCR全文を大量に読む設計へ戻さないための分離である。

### photo_tags

タグ検索用。

- `asset_identifier`
- `tag`
- `normalized_tag`

### processing_jobs / processing_job_items

OCRや将来の分類ジョブを永続化するための枠。今回の初期実装ではテーブルを用意し、既存のまとめてOCR UIは20/50/100件の小分け実行を維持する。

## インデックス

- `asset_identifier`
- `creation_date`
- `display_state`
- `category`
- `screenshot_category`
- `is_screenshot`
- `has_ocr`
- `ocr_status`
- `classification_status`
- `search_documents.normalized_text`
- `search_documents.source_revision`
- `photo_tags.normalized_tag`

検索語が増え、LIKE検索で足りなくなった段階でFTSを検討する。

## 移行

SQLite側の `photo_records` が空の場合のみ、旧 `photo_index.json` を読み込む。移行は500件ずつ行う。失敗しても旧JSONは残す。写真本体、元動画、写真アプリ側のアルバムは触らない。

移行中は `PhotoIndexService` が進捗通知を受け取り、写真画面と設定画面に「旧インデックスをSQLiteへ移行中」と件数を表示する。移行進捗の表示はUI用の状態だけであり、旧JSONを削除しない。

既存SQLiteに `search_documents` または `is_screenshot` が無い場合は、旧JSONではなくSQLite内の `record_json` から500件単位でバックフィルする。これにより、通常動作用DBとして旧JSONを使い続けない。

## 書き込み安全性

- `upsert` はトランザクション内で実行する
- `saveAll` は削除と再登録を同一トランザクションにする
- OCR本文とタグは別テーブルへ同期する
- 検索文書は `upsertRecord` と同じトランザクションで同期する
- 失敗時はロールバックする

## 集計

件数チップや設定画面の概要は、可能な限りSQLite側の集計結果を `PhotoIndexService` のキャッシュへ反映して表示する。

- 表示状態別件数: `displayStateCounts()`
- カテゴリ別件数: `categoryCounts(displayState:)`
- スクショ細分類件数: `screenshotSubcategoryCounts(displayState:)`

これにより、スクロール、サムネイル更新、タブ移動のたびに28,000件規模の配列へ `.filter { }.count` をかけ直す経路を避ける。集計中は `FilterCountsSnapshot` を準備中として扱い、UIは `0` ではなく `--` を表示する。

カテゴリの「すべて」は、表示状態スコープを反映した件数として扱う。これにより、通常表示があるのにカテゴリ側の「すべて」が0に見える状態を避ける。

## ページング

写真一覧と検索結果は `PhotoIndexPageRequest` でSQLiteからIDページを取得する。

- 1ページの初期上限は200件
- 「さらに表示」で200件ずつ増やす
- 検索語、表示状態、カテゴリ、スクショ細分類をDB条件に入れる
- 検索語は `search_documents.normalized_text` をLIKE検索する
- 結果は `creation_date DESC` を基本順序にする
- View側は世代番号を見て古い検索結果の反映を捨てる

この段階では、返ってきたIDを表示用 `PhotoAsset` に戻すために、読み込み済みアセット辞書を参照する。写真本体やサムネイル本体はDBに保存しない。

## 削除しないもの

- 写真アプリ内の元写真
- 写真アプリ内の元動画
- PHAssetそのもの
- 写真アプリ側アルバム
- iCloud写真の原本

SQLiteはしまい箱内の検索インデックスだけを保存する。
