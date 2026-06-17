# 検索インデックス保存設計

## 目的

約3万枚規模の写真ライブラリで、OCR結果、分類結果、検索用メタデータを同じ `localIdentifier` で参照できるようにする。写真本体やサムネイル本体は保存しない。

## 採用方式

現段階では `PhotoIndexStoring` protocol と `JSONPhotoIndexStore` を採用する。

- 保存先: `Application Support/ShimaiBako/photo_index.json`
- 形式: Codable JSON
- バージョン: 2
- 主キー: `localIdentifier`
- 呼び出し元: `PhotoIndexService`
- 写真本体: 保存しない
- サムネイル本体: 保存しない

SQLiteまたはSwiftDataへ移行する時は、`PhotoIndexStoring` の実装を差し替える。UIやPhotoKit読み込み側は、Store実装の詳細を直接持たない。

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

SettingsViewのOCR件数、分類済み件数、カテゴリ別件数は `PhotoIndexService` 経由で計算する。将来SQLiteへ移行した場合は、同じ集計をSQL側へ寄せられる。

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

## SQLite移行方針

3万件規模で検索語が増え、JSON全体の読み書きが重くなった段階でSQLiteへ移行する。

初期のSQLite構成案:

- テーブル: `photo_index`
- 主キー: `local_identifier`
- インデックス:
  - `creation_date`
  - `media_type`
  - `inferred_category`
  - `ocr_status`
- `last_seen_at`
- `screenshot_subcategory`
- OCR検索:
  - 初期は `LIKE`
  - 件数増加後はFTSへ移行

SQLiteでも写真本体やサムネイル本体は保存しない。

## SwiftData移行方針

SwiftDataは実装量を抑えやすい一方、検索性能、FTS、移行制御、iOS対応バージョンの検討が必要になる。現段階ではSQLite/FTSの方が大規模検索の制御はしやすい。

SwiftDataを採用する場合も、`PhotoIndexStoring` の実装として追加し、既存UIからは直接依存しない。

## 運用方針

- 初回起動で全件OCRしない
- まずPhotoKitメタデータと軽量分類を索引化する
- OCRは表示中、スクショ、書類候補などに絞って段階実行する
- 完了したOCR結果だけを検索対象へ加える
- 写真本体は外部送信しない
- 写真本体は変更しない
