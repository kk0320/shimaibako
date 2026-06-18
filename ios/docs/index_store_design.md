# 検索インデックス保存設計

## 目的

約3万枚規模の写真ライブラリで、OCR結果、分類結果、検索用メタデータを同じ `localIdentifier` で参照できるようにする。写真本体やサムネイル本体は保存しない。

## 採用方式

現段階では `PhotoIndexStoring` protocol の実装として `SQLitePhotoIndexStore` を主に使う。旧 `JSONPhotoIndexStore` は移行元、互換バックアップ、障害解析用として残す。

- 主保存先: `Application Support/ShimaiBako/photo_index.sqlite`
- 旧JSON: `Application Support/ShimaiBako/photo_index.json`
- 主キー: `localIdentifier`
- 呼び出し元: `PhotoIndexService`
- 写真本体: 保存しない
- サムネイル本体: 保存しない

SQLiteはiOS標準の `SQLite3` を使う。外部ライブラリは追加しない。Core Dataはモデル移行の設計余地があるため、今回は既存protocolへ差し込みやすいSQLiteを選んだ。

## 保存項目

`PhotoIndexRecord` は次を保存する。

- `localIdentifier`
- `creationDate`
- `mediaTypeRawValue`
- `mediaSubtypesRawValue`
- `pixelWidth`
- `pixelHeight`
- `isScreenshot`
- `ocrStatus`
- `ocrText`
- `ocrLanguage`
- `ocrProcessedAt`
- `ocrErrorMessage`
- `inferredCategory`
- `categoryConfidence`
- `categoryReason`
- `categoryUpdatedAt`
- `screenshotSubcategory`
- `screenshotSubcategoryConfidence`
- `screenshotSubcategoryReason`
- `screenshotSubcategoryUpdatedAt`
- `manualCategory`
- `manualScreenshotSubcategory`
- `manualCategoryUpdatedAt`
- `lastSeenAt`
- `updatedAt`

`hasOCRText` は保存互換のためJSONに出すが、アプリ内では `ocrStatus` と `ocrText` から計算する。

## JSON互換

既存の `ocr_results.json` は `OCRResultStore` が引き続き読み込む。写真を読み込んだ時、`PhotoIndexService` がOCR結果とPhotoKitメタデータを合わせて `photo_index.json` に反映する。

既存の古い `photo_index.json` に新しい項目がない場合は、次の既定値で読み込む。

- OCRテキスト: 空文字
- OCR状態: 未処理
- 推定カテゴリ: 未分類
- 分類理由: なし
- スクショ細分類: なし
- カテゴリ更新日時: 既存の更新日時
- 最終確認日時: 既存の更新日時

移行処理は写真本体を触らない。

## 検索と集計

検索用テキストは `PhotoIndexRecord.searchableIndexText` で作る。検索対象は次の情報を含む。

- `localIdentifier`
- 撮影日
- メディア種別
- 画像サイズ
- スクリーンショット判定
- 仮想フォルダ名
- 分類理由
- スクショ細分類名
- スクショ細分類理由
- OCRテキスト

SettingsViewのOCR件数、分類済み件数、カテゴリ別件数は `PhotoIndexService` 経由で表示する。SQLite実装では表示状態別件数、カテゴリ別件数、スクショ細分類件数をSQLで集計し、`PhotoIndexService` のキャッシュへ反映する。

検索用に `searchLocalIdentifiers(matching:)` を用意している。現段階の画面表示は読み込み済み `PhotoAsset` 配列との照合が残るため、28,000件規模の実機確認で重い場合は、検索結果のID取得とページングをSQLite側へさらに寄せる。

## リセット操作

`PhotoIndexStoring` はOCR欄と分類欄を分けて更新できるようにする。

OCR欄の操作:

- `clearOCRResult(localIdentifier:)`
- `clearOCRResults(localIdentifiers:)`
- `clearAllOCRResults()`

分類欄の操作:

- `resetCategory(localIdentifier:)`
- `resetCategories(localIdentifiers:)`
- `resetAllCategories()`

`PhotoIndexService` はUIから使うための高レベル操作として、OCR結果削除時に `OCRService` 側の `ocr_results.json` と `PhotoIndexStore` 側の `photo_index.json` を同時に更新する。

リセット操作はすべて検索データのみを対象にする。写真本体、サムネイル本体、写真アプリ側のアルバム、iCloud写真は変更しない。

削除後の状態:

- OCR状態は `unprocessed` に戻る
- OCRテキスト、言語、処理日時、失敗理由は空になる
- OCR文字検索の対象から外れる
- 再OCRすると新しい結果を保存できる

分類の未分類戻しは `inferredCategory` を `uncategorized`、`categoryConfidence` を0に戻し、スクショ細分類も空にする。分類再構築は読み込み済みの `PhotoAsset` と保存済みOCRテキストから再推定する。

スクショ細分類は通常カテゴリとは別に保存する。スクショではない写真では空のままにし、既存JSONにフィールドがなくても読み込み時に落ちない。

手動分類は自動分類と別フィールドに保存する。手動分類がある場合、表示と検索用カテゴリでは手動分類を最優先する。自動判定に戻す操作では手動分類フィールドを空にし、写真本体を触らずにメタデータと保存済みOCRテキストから分類を再判定する。

## 分類傾向学習データ

分類傾向学習は検索インデックスとは別に、`Application Support/ShimaiBako/manual_category_learning.json` へ保存する。

保存する情報:

- `sourceLocalIdentifier`
- `correctedCategory`
- `correctedScreenshotSubcategory`
- `normalizedKeywords`
- `isScreenshot`
- `mediaTypeRawValue`
- `aspectRatioBucket`
- `originalAutoCategory`
- `createdAt`
- `updatedAt`
- `useCount`

保存しない情報:

- 写真本体
- サムネイル本体
- 画像特徴量ベクトル
- 大量のOCR全文
- 全写真同士の類似度行列

学習データは全体800件、1分類あたり80件を上限にし、キーワードは1例あたり最大20個に制限する。分類時に見る候補も最大60件に絞る。上限を超えた場合は、古く使われていない例から整理する。

分類傾向学習は `PhotoIndexStoring` とは分けている。将来SQLiteへ移行する場合は、検索インデックス本体と同じDBに別テーブルとして移せるが、現段階では既存JSON互換を保つため小さなJSONとして扱う。

## SQLite構成

SQLiteには次のテーブルを作る。

- `photo_records`
- `photo_texts`
- `photo_tags`
- `processing_jobs`
- `processing_job_items`

`photo_records` は一覧や集計に必要な軽量カラムを持つ。OCR本文は `photo_texts` へ分離し、一覧を開くだけで大量のOCR全文を読み込まないようにする。タグは `photo_tags` に分離する。

初回移行時、SQLite側が空なら旧JSONから500件ずつ登録する。旧JSONは削除しない。移行中は進捗通知を出し、写真画面と設定画面で件数を表示する。

OCR検索は初期段階では正規化済みテキストへの `LIKE` で実装する。実機データで不足した場合はFTSへ移行する。

## SwiftData移行方針

SwiftDataは実装量を抑えやすい一方、検索性能、FTS、移行制御、iOS対応バージョンの検討が必要になる。現段階ではSQLite/FTSの方が大規模検索の制御はしやすい。

SwiftDataを採用する場合も、`PhotoIndexStoring` の実装として追加し、既存UIからは直接依存しない。

## 運用方針

- 初回起動で全件OCRしない
- まずPhotoKitメタデータと軽量分類を索引化する
- OCRは表示中、スクショ、書類候補などに絞って段階実行する
- 完了したOCR結果だけを検索対象へ加える
- 手動分類は自動分類と分類傾向学習より優先する
- 分類傾向学習は端末内の軽量データだけを使い、重い画像比較は行わない
- 写真本体は外部送信しない
- 写真本体は変更しない
