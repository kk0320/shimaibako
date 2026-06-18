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

`record_json` は既存 `PhotoIndexRecord` 互換のために残す。検索と集計はできるだけ個別カラムを見る。

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
- `has_ocr`
- `ocr_status`
- `classification_status`
- `photo_tags.normalized_tag`

検索語が増え、LIKE検索で足りなくなった段階でFTSを検討する。

## 移行

SQLite側の `photo_records` が空の場合のみ、旧 `photo_index.json` を読み込む。移行は500件ずつ行う。失敗しても旧JSONは残す。写真本体、元動画、写真アプリ側のアルバムは触らない。

## 書き込み安全性

- `upsert` はトランザクション内で実行する
- `saveAll` は削除と再登録を同一トランザクションにする
- OCR本文とタグは別テーブルへ同期する
- 失敗時はロールバックする

## 削除しないもの

- 写真アプリ内の元写真
- 写真アプリ内の元動画
- PHAssetそのもの
- 写真アプリ側アルバム
- iCloud写真の原本

SQLiteはしまい箱内の検索インデックスだけを保存する。
