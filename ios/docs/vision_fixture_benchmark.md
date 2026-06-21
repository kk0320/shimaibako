# Vision Fixture Benchmark

## 目的

P0.9では、PhotoKitの実写真だけでなく、開発用の画像ファイルfixtureを使ってVision分類経路を検証する。

目的は本番精度を断言することではない。確認するのは次の範囲に限定する。

- File URL入力でVision probeが動くこと
- score計算とsemantic assertionが動くこと
- OCR優先度が期待方向に反応すること
- metadataAwareのスクショ高速パスが退行しないこと
- taxonomyやscore調整時にJSON/CSV/Markdown evidenceを残せること

## 評価レイヤー

| Layer | 用途 | Product Go判断 |
| --- | --- | --- |
| Contract fixtures | ローカル合成画像。処理経路、score合成、回帰テスト用 | しない |
| Characterization fixtures | ライセンス確認済み実写真。Vision傾向、誤分類、閾値仮調整用 | しない |
| In-domain holdout | 自分で撮影した写真、許可済み現場写真。本番精度判断用 | ここだけで判断 |

合成画像や一般公開画像だけで、建物、工事現場、重機、資材、看板などのProduct Go判断はしない。

## 入力抽象化

P0.9では `ClassificationSample` を共通入力にする。

```text
ClassificationSample
  id
  imageSource
  metadata
  expected
  provenance

ClassificationImageSource
  photoAsset(localIdentifier)
  fileURL(URL)
```

既存PHAssetベンチとFile-basedベンチは、Vision requestとscore合成を共有する。File fixture専用に分類ロジックを二重実装しない。

## 合成fixture

保存先:

```text
fixtures/vision_benchmark/synthetic/
fixtures/vision_benchmark/manifests/
```

生成スクリプト:

```text
ios/scripts/generate_vision_fixtures.swift
```

カテゴリ:

- receipt
- businessCard
- document
- drawing
- sign
- whiteboard
- chatScreenshot
- appScreenshot
- buildingLike
- constructionLike

各fixtureは架空の店名、会社名、UI、文字だけを使う。実在の氏名、会社名、電話番号、住所、ブランドロゴ、QRコード、LINEなどの実在UIは使わない。

## スクショ2モード

スクショfixtureは2系統で評価する。

```text
metadataAware:
  metadata.isScreenshot = true
  gatedProbe相当
  PhotoKit高速パスの回帰検出

imageOnly:
  metadata.isScreenshot = null
  fullProbe相当
  画像だけでスクショらしさが出るかの観察
```

この2つは混ぜて評価しない。metadataAwareが通っても、imageOnlyの本番精度が高いとは判断しない。

## Semantic Assertion

完全一致snapshotは使わない。

避けるもの:

```text
topLabel == receipt
confidence == 0.821354
```

使うもの:

```text
requiredTags contains ocrNeeded
forbiddenTags excludes screenshot
ocrPriorityScore >= 0.2
screenshotScore > documentScore
documentScore > foodScore
```

Vision revisionやOSで数値が変わるため、assertionは意味的・方向性の確認に留める。

## 出力

アプリ内DEBUG runnerは、app sandbox内へ次を出力する。基本は `Application Support/ShimaiBako/vision_classification_benchmark/` を使う。`devicectl` でfixtureを投入した実機では親ディレクトリが書き込み不可になる場合があるため、その場合は `Caches/ShimaiBako/vision_classification_benchmark/` へフォールバックする。

```text
p09_fixture_results_*.json
p09_fixture_results_*.csv
p09_fixture_summary_*.md
p09_fixture_assertions_*.md
```

証跡として必要な場合は、これらを次へコピーする。

```text
evidence/vision_classification_benchmark/
```

出力には次を含める。

- fixtureId
- fixtureSHA256
- expectedTags
- actualTopLabels
- actualScores
- predictedTags
- ocrPriorityScore
- assertionResults
- processingTimeMs
- deviceModel
- osVersion
- appBuild
- visionRevision
- supportedIdentifiersHash
- taxonomyVersion
- scoringVersion
- probeVersion
- runAt

## 外部画像fixture

P0.9ではネット画像を自動収集しない。将来導入する場合も、検索結果や一般Webページから直接保存しない。

初期許可:

- 自作画像
- CC0
- Public Domain
- CC BY 4.0

除外:

- CC BY-NC
- CC BY-ND
- CC BY-SA
- 独自不明ライセンス
- 識別可能な人物
- 個人情報
- 車両ナンバー
- 社員証
- QRコード
- 機密図面
- 商標やロゴを主対象にした画像

`fixtures/vision_benchmark/manifests/external_sources_template.csv` に将来の `sources.csv` ひな形を置く。`approved=false` の画像は正式benchmarkに含めない。

## Release混入防止

fixture画像は開発用であり、Release targetやCopy Bundle Resourcesに含めない。

チェック:

```text
swift ios/scripts/check_vision_fixture_release_mix.swift
```

必要に応じて `.app` を指定する。

```text
swift ios/scripts/check_vision_fixture_release_mix.swift --app-path path/to/ShimaiBako.app
```

このチェックは、Xcode projectや.app内に `fixtures/vision_benchmark`、`p09_synthetic_manifest.json`、主要fixture名が混入していればFAILにする。

## 安全方針

- 元写真・元動画は削除・変更しない。
- PhotoKit書き込み/削除APIは使わない。
- 外部APIや画像外部送信は使わない。
- 本番データとして画像本体を保存しない。
- サムネイル本体を保存しない。
- 顔画像や顔テンプレートを保存しない。
- 人物識別は行わない。
- BatchOCRや読取タブへ自動連携しない。
