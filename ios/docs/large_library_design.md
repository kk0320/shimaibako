# 大規模写真ライブラリ設計

## 目的

約3万枚の写真ライブラリでも、初回表示や検索UIが固まらないようにする。しまい箱は写真本体を移動・削除・変更せず、まずPhotoKitのメタデータと参照だけを扱う。

## 読み込みモード

設定画面から次のモードを選択できる。選択値は `UserDefaults` に保存する。

| モード | 上限 | 用途 |
| --- | ---: | --- |
| 軽量 | 100件 | 初回確認、権限確認、実機テスト |
| 標準 | 500件 | 日常利用の初期値 |
| 多め | 2,000件 | 少し広く探す |
| 大量 | 10,000件 | 端末状態を見ながら使う |
| フル | 全件 | 慎重運用。安全確認後だけ使う |

大量/フルを選ぶ前には安全確認画面を表示する。

- バッテリー残量が50%以上、または充電中に使用する
- 発熱、保存容量、メモリ使用量に注意する
- iCloud写真取得を許可している場合は通信量に注意する
- 最初は軽量/標準モードで試す

## 読み込み方針

- PhotoKitの `PHAsset` を撮影日降順で取得する
- 画像本体は一覧読み込み時には取得しない
- サムネイルはグリッド表示時に必要になったセルだけ取得する
- OCR用の高解像度画像は、1枚OCRまたはまとめてOCRの対象になった時だけ取得する
- 500件単位で `Task.yield()` し、UI更新の余地を作る
- 大量モードではファイル名取得を省略し、PhotoKitメタデータ中心で扱う

## 検索インデックス

`PhotoIndexStore` は `Application Support/ShimaiBako/photo_index.json` に検索インデックスを保存する。保存は `PhotoIndexStoring` protocol 越しに扱い、現在は `JSONPhotoIndexStore` を使う。

主キー:

- `localIdentifier`

保存対象:

- `localIdentifier`
- `creationDate`
- `mediaType`
- `mediaSubtypes`
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
- `categoryUpdatedAt`
- `lastSeenAt`
- `hasOCRText`

写真本体やサムネイル本体は保存しない。保存するのは検索と表示に必要なメタデータ、OCRテキスト、分類結果のみ。

現段階ではJSON保存を維持する。3万件規模では全件の頻繁な読み書きが重くなるため、次段階では同じ `PhotoIndexStoring` 境界を保ったままSQLiteまたはSwiftDataへ移行する。

## 検索と分類

検索は読み込み済み範囲を対象にし、OCRテキストとカテゴリ情報は `PhotoIndexService` 経由で参照する。全件検索を行うには、まず読み込みモードで対象範囲を広げる。

分類はしまい箱内の仮想フォルダであり、写真アプリ側にアルバムやフォルダは作らない。

## 3万件相当の性能確認

`ios/scripts/index_store_performance_check.swift` で30,000件のダミー検索インデックスを生成し、JSON読み書きとLIKE相当検索を確認した。

開発環境での結果:

- JSON読み込みとデコード: 約0.5秒
- OCRテキスト検索: 約0.25秒
- カテゴリ集計: 約0.03秒

詳細は `ios/docs/large_library_performance_notes.md` に記録する。この結果から、MVP互換としてJSONは維持できるが、実機でOCR済み件数が増えた段階ではSQLite/FTS移行を優先する。

## 大量ライブラリで避けること

- 初回起動で3万枚すべてのサムネイルを生成しない
- 初回起動で全件OCRしない
- 写真本体をアプリ側へ複製しない
- 写真アプリ側へアルバムを作らない
- バックグラウンド移行後も長時間処理を続けない

## 今後の拡張

- 差分インデックス更新
- 読み込み範囲のページング
- SQLiteまたはSwiftDataへの移行
- SQLite FTSによるOCRテキスト検索
- カテゴリ推定の精度改善
