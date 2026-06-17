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

## 軽量インデックスとの関係

OCR結果とは別に、検索と仮想フォルダ用の軽量インデックスを `PhotoIndexStore` が保存する。

- 保存先: `Application Support/ShimaiBako/photo_index.json`
- 主キー: `localIdentifier`
- 保存内容: 撮影日、メディア種別、画像サイズ、スクショ判定、推定カテゴリ、カテゴリ信頼度、OCR状態、OCRテキスト有無

OCRが完了または失敗した写真は、`PhotoIndexService` がカテゴリとOCR状態を再計算して保存する。

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

検索画面では既存の撮影日、種別、サイズ、スクリーンショット判定、仮想フォルダ名に加えて、保存済みのOCRテキストを検索対象に含める。

OCR未処理または失敗した写真は、OCRテキスト検索には含めない。

## OCR画像準備

Vision OCRに渡す前に、画像の長辺が1800pxを超える場合は長辺1800px目安に縮小する。

目的:

- 元画像を過剰に大きいままOCRへ渡さない
- スクリーンショットや書類写真でも読める解像度を維持する
- 端末内処理の時間とメモリ使用量を抑える

画像取得はPhotoKitから読み取り専用で行い、iCloud上にあり端末内で取得できない場合や画像変換に失敗した場合は `failed` として `errorMessage` を保存する。

## まとめてOCRと保存

まとめてOCRは表示中、スクショのみ、書類写真候補のみ、未OCRのみから対象を選び、最大20件まで対象にする。

開始前に安全確認画面を表示し、端末温度や保存容量に問題がある場合は開始を止める。

キャンセル時の扱い:

- すでに完了したOCR結果は保存済みとして残す
- 読み取り失敗した結果は失敗として残す
- まだ開始していない写真は未処理のまま残す
- キャンセル自体を写真の失敗扱いにはしない

バックグラウンド移行、端末温度上昇、保存容量不足で中断した場合も同じ扱いにする。中断理由は画面に表示する。

## 3万件規模での注意

JSON保存は実装が単純で扱いやすい一方、3万件規模で全件を頻繁に読み書きすると負荷が増える。

現段階では次の運用にする。

- 初回から全件OCRしない
- OCRは表示中、スクショ、書類候補などに絞って段階実行する
- OCR結果と軽量インデックスは `localIdentifier` を主キーにする
- 将来のSQLiteまたはSwiftData移行を前提に、保存処理をStore層に閉じ込める

## 今後の移行方針

件数が増えた段階で、`OCRResultStore` の境界を維持したままSwiftDataまたはSQLiteへ移行できる。

移行時に検討する項目:

- OCR結果の差分更新
- 軽量インデックスの差分更新
- 検索インデックス
- 処理履歴
- 画像サイズや認識言語の記録拡張
