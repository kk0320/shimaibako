# OCR結果保存設計

## 目的

OCR結果を写真の `localIdentifier` に結びつけて端末内に保存し、アプリ再起動後も検索と詳細表示に利用できるようにする。

## 保存方式

初期実装では外部依存のないCodable JSONを使う。

- 保存先: `Application Support/ShimaiBako/ocr_results.json`
- 管理クラス: `OCRResultStore`
- 呼び出し元: `OCRService`
- ファイル書き込み: atomic write
- 日付形式: ISO 8601

JSONは将来の移行に備えて `version` を持つ。

## 保存項目

- `photoLocalIdentifier`
- `ocrText`
- `ocrStatus`
- `ocrLanguage`
- `processedAt`
- `errorMessage`

## 状態管理

OCR状態は次の4種類。

- `unprocessed`: OCR未実行
- `processing`: 処理中
- `completed`: OCR済み
- `failed`: 読み取り失敗

アプリ起動時に `processing` のまま残っている結果は、前回処理が完了しなかったものとして `failed` に変換する。

## 検索連携

検索画面では既存の撮影日、種別、サイズ、スクリーンショット判定に加えて、保存済みのOCRテキストを検索対象に含める。

OCR未処理または失敗した写真は、OCRテキスト検索には含めない。

## 今後の移行方針

件数が増えた段階で、`OCRResultStore` の境界を維持したままSwiftDataまたはSQLiteへ移行できる。

移行時に検討する項目:

- OCR結果の差分更新
- 検索インデックス
- 処理履歴
- 画像サイズや認識言語の記録拡張
