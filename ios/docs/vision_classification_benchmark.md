# Vision分類評価計画

## 目的

画像分類を本実装する前に、端末内のVision標準機能でどこまで整理に使えるかを評価する。

このspikeでは、ユーザー向け機能を作り込まない。分類精度、速度、メモリ、発熱、誤分類の傾向を確認し、保存してよい軽量データの範囲を決める。

## 評価対象

確認する信号:

- PhotoKitのスクショメタデータ
- 顔検出
- 人物検出
- 汎用画像分類
- 書類っぽさ
- 建物に使えそうな信号
- 工事現場に使えそうな信号
- 看板・掲示に使えそうな信号
- 1件あたり処理時間
- メモリ使用傾向
- 発熱傾向
- 誤分類

人物識別は行わない。顔画像や顔テンプレートは保存しない。

## 評価セット

少数サンプルで始める。目安はカテゴリごとに100〜150枚。

```text
スクショ 100〜150枚
書類 100〜150枚
人物あり 100〜150枚
食べ物 100〜150枚
風景/屋外 100〜150枚
建物/工事現場 100〜150枚
看板/掲示 100〜150枚
その他 100〜150枚
```

同じ写真に複数タグを付けられる前提で評価する。

## 評価カテゴリ

### 形式・種類

```text
通常写真
スクショ
書類
図面
名刺
レシート・領収書
看板・掲示
白板・黒板
```

### 内容

```text
建物
工事現場
人物
車両・重機
資材・設備
食べ物
風景
```

建物と工事現場は別評価にする。

- 建物: 完成建物、外観、内観、ビル、住宅
- 工事現場: 足場、施工中、仮設、重機、現場全景

## 評価手順

1. 対象写真を少数サンプルとして固定する。
2. PhotoKitメタデータでスクショ判定を確認する。
3. Visionの顔検出・人物検出を確認する。
4. Visionの汎用画像分類ラベルを取得する。
5. 書類、看板、白板、図面に使えそうな信号を確認する。
6. 1件あたりの処理時間を記録する。
7. バッチ100件、500件、2,000件の負荷見積もりを作る。
8. 誤分類表を作る。
9. OCR候補への優先度付けに使えるか評価する。

## 記録する指標

```text
assetIdentifier
expectedTags
predictedFormatTags
predictedContentTags
topLabels
faceCount
containsPerson
documentScore
buildingScore
constructionSiteScore
signScore
whiteboardScore
receiptScore
ocrPriorityScore
processingTimeMs
memoryNote
thermalNote
manualReview
falsePositiveTags
falseNegativeTags
notes
```

`assetIdentifier` はアプリ内評価用の参照キーとして使う。写真本体は保存しない。

## OCR候補評価

OCR最優先:

```text
名刺
レシート・領収書
書類
看板・掲示
白板・黒板
スクショ
```

OCR優先:

```text
図面
工事看板
安全標識
資料写真
```

条件付き:

```text
建物
工事現場
人物
車両・重機
```

建物だけではOCR候補にしない。文字がありそう、看板っぽい、資料写真っぽいなど、別信号と組み合わせて `ocrPriorityScore` を上げる。

## 合格基準

spikeでは、次の判断材料を得られればよい。

- スクショ判定が安定している
- 人物あり判定が整理に使える
- 書類・看板・白板の候補抽出に使える信号がある
- 建物と工事現場を完全には分けられなくても、要確認へ回す判断材料がある
- 100件単位の処理が実用的な速度で動く
- 500件、2,000件を実行する場合の一時停止条件が見える
- OCR候補作成に使える優先度スコアを設計できる

## 誤分類表

最低限、次の形式で記録する。

```text
期待タグ
推定タグ
誤分類タイプ
原因メモ
OCR候補への影響
手動修正が必要か
```

誤分類タイプ:

```text
見逃し
過検出
建物/工事現場の混同
書類/スクショの混同
看板/書類の混同
人物検出の誤判定
```

## 保存するデータ

保存してよいもの:

- 軽量な分類結果
- タグ
- スコア
- 状態
- 処理時間
- Visionラベルの要約
- OCR優先度

## 保存しないデータ

保存しないもの:

- 写真本体
- サムネイル本体
- 顔画像
- 顔テンプレート
- 人物識別情報
- 大量特徴ベクトル
- 外部送信用データ

## 実装しないこと

spikeでは次を実装しない。

- ユーザー向けの本番分類タブ
- 大量ライブラリ全体の自動分類
- 写真アプリ側アルバム作成
- 写真本体の削除、移動、変更
- 外部API連携
- 画像の外部送信
- 顔識別

## P0.9 File-based Fixture Benchmark

P0.9では、PHAssetだけでなく開発用の画像ファイルfixtureを入力できるようにする。目的は本番精度の断言ではなく、Vision request、score計算、semantic assertion、evidence出力の退行検出である。

評価データは3層に分ける。

```text
Layer 1: Contract fixtures
  ローカル合成画像。
  処理経路、OCR優先度、score合成、回帰テスト用。

Layer 2: Characterization fixtures
  ライセンス確認済み実写真。
  Visionの傾向、誤分類、閾値仮調整用。

Layer 3: In-domain holdout
  自分で撮影した写真、許可済み現場写真。
  本番精度、リリース可否判断用。
```

合成画像や一般公開画像だけで、建物、工事現場、車両・重機、資材・設備などのProduct Go判断はしない。

追加した構成:

```text
ClassificationSample
ClassificationImageSource.photoAsset / fileURL
ClassificationMetadata
VisionFixtureBenchmarkRunner
ios/scripts/generate_vision_fixtures.swift
ios/scripts/check_vision_fixture_release_mix.swift
fixtures/vision_benchmark/
```

P0.9の合成fixtureカテゴリ:

```text
receipt
businessCard
document
drawing
sign
whiteboard
chatScreenshot
appScreenshot
buildingLike
constructionLike
```

スクショfixtureは `metadataAware` と `imageOnly` を分けて評価する。`metadataAware` はPhotoKit高速パス相当、`imageOnly` は画像だけの観察であり、同じ判断には使わない。

出力:

```text
evidence/vision_classification_benchmark/p09_fixture_results_*.json
evidence/vision_classification_benchmark/p09_fixture_results_*.csv
evidence/vision_classification_benchmark/p09_fixture_summary_*.md
evidence/vision_classification_benchmark/p09_fixture_assertions_*.md
```

fixture画像はRelease target、Copy Bundle Resources、Archive後の `.app` に含めない。`swift ios/scripts/check_vision_fixture_release_mix.swift` で混入を検出する。

DEBUG runnerの出力先は通常 `Application Support/ShimaiBako/vision_classification_benchmark/`。実機へ `devicectl` でfixtureを配置した場合に親ディレクトリが書き込み不可になることがあるため、その場合は `Caches/ShimaiBako/vision_classification_benchmark/` へフォールバックする。
- 特徴ベクトルの大量保存

## 安全確認

各段階で次を確認する。

```text
swift ios/scripts/photo_library_safety_check.swift
swift ios/scripts/accuracy_improvement_safety_check.swift
xcodebuild build
git diff --check
```

加えて、warning/error抽出、禁止表現チェック、`xcuserdata` / `UserInterfaceState` 混入チェック、Simulator install / launch、K Phone build / install / launchを行う。

## P0ベンチ実装

`spike/vision-classification-benchmark` では、Settings内にDEBUG限定の「Vision分類ベンチ」カードを追加した。Release相当の通常UIには表示しない。

実行できる内容:

```text
20件で実行
100件で実行
ラベル棚卸しを保存
```

起動引数でもDEBUGビルド限定で実行できる。

```text
-ShimaiBakoOpenSettingsTab
-ShimaiBakoRunVisionClassificationBenchmark20
-ShimaiBakoRunVisionClassificationBenchmark100
```

このベンチは本番分類結果を保存しない。写真タブ、整理タブ、OCRジョブ、検索インデックスには反映しない。

## 使用したVision request

P0では次を1枚ずつ実行する。

```text
VNClassifyImageRequest
VNDetectFaceRectanglesRequest
VNDetectHumanRectanglesRequest
VNDetectDocumentSegmentationRequest
VNClassifyImageRequest.supportedIdentifiers()
```

画像取得はPhotoKitから最大640px程度の解析用画像を1枚ずつ取得する。`PHImageRequestOptions.isNetworkAccessAllowed` は `false` とし、iCloud上にしかない画像を無理に取得しない。

## 取得した信号

保存する軽量情報:

- ハッシュ化したasset identifier
- pixelWidth / pixelHeight
- mediaType / mediaSubtypes
- isScreenshot
- creationDate有無
- Vision分類ラベル上位5件
- 顔数、人物矩形数、書類セグメント数
- Vision requestごとの処理時間
- 仮スコア
  - screenshotScore
  - documentScore
  - personScore
  - foodScore
  - landscapeScore
  - buildingScore
  - constructionSiteScore
  - signScore
  - whiteboardScore
  - businessCardScore
  - receiptScore
  - ocrPriorityScore

保存しない情報:

- 写真本体
- サムネイル本体
- 顔画像
- 顔テンプレート
- 人物識別情報
- 画像特徴ベクトル
- 生のasset identifierを含むevidence

## evidence出力

出力先:

```text
evidence/vision_classification_benchmark/
```

アプリ実行時はApplication Support内へ保存し、実機検証では `devicectl` でrepo側のevidenceへコピーした。

出力形式:

```text
JSON
Markdown
CSV
supported_identifiers_summary.md
```

## supportedIdentifiers棚卸し結果

K Phone / Debug実行時点では、`VNClassifyImageRequest.supportedIdentifiers()` は `1303` 件を返した。

確認キーワードの例:

```text
billboards
building
crane_construction
document
food
receipt
sign
street_sign
truck
vehicle
whiteboard
```

一方で、`person`、`face`、`architecture`、`landscape` はキーワード一致が0件だった。人物や顔は `VNDetectFaceRectanglesRequest` / `VNDetectHumanRectanglesRequest` の検出結果で扱う。

## K Phoneベンチ結果

検証端末:

```text
K Phone
photoAuthorizationStatus: authorized
totalAvailableImageCount: 26992
```

20件:

```text
actualCount: 20
averageMsPerAsset: 349.6
maxMsPerAsset: 1473.7
failedCount: 0
screenshotCandidateCount: 15
faceDetectedCount: 1
humanDetectedCount: 2
likelyDocumentCount: 20
likelyBuildingCount: 5
likelySignCount: 0
likelyFoodCount: 0
likelyConstructionSiteCount: 0
```

100件:

```text
actualCount: 100
averageMsPerAsset: 265.0
maxMsPerAsset: 1424.4
failedCount: 0
screenshotCandidateCount: 87
faceDetectedCount: 1
humanDetectedCount: 2
likelyDocumentCount: 100
likelyBuildingCount: 15
likelySignCount: 0
likelyFoodCount: 0
likelyConstructionSiteCount: 0
```

所感:

- 100件規模ではVision標準機能の逐次解析は実行可能だった。
- 直近100件にスクリーンショットが多く、`screenshotScore` はPhotoKitメタデータで安定して取れた。
- `likelyDocumentCount` は100件中100件となり、P0の仮 `documentScore` は過検出気味である。`VNDetectDocumentSegmentationRequest` とラベルキーワードをそのまま強く使うだけでは、書類候補としては緩すぎる可能性がある。
- 食べ物、看板、工事現場は今回の直近100件では十分なサンプルが取れていない。次フェーズではサンプルセットをカテゴリ別に固定して再評価する。

## Simulator確認メモ

Simulatorでは、CLIから写真権限付与とサンプル画像投入を試したが、アプリ内の `photoAuthorizationStatus` が `notDetermined` のままで、PhotoKitから取得できた画像数は0件だった。

このため、Simulatorではアプリの起動とファイル出力経路、および `supportedIdentifiers()` の棚卸しを確認し、実画像20件/100件のベンチ結果はK Phone実機結果を採用した。

## 次フェーズへの判断

次に進む場合の優先事項:

- カテゴリ別の固定サンプルセットを用意する。
- `documentScore` の過検出を下げるため、ラベル、縦横比、明るさ、OCR候補情報を組み合わせる。
- 建物 / 工事現場 / 看板 / 食べ物は、十分なサンプルを分けて評価する。
- 本番保存はまだ行わず、手動分類を上書きしない設計を維持する。
- 500件以上の分類ジョブは、発熱・バッテリー・中断復旧の設計が固まってから扱う。

## P0.5スコア調整

`documentScore` の過検出を抑えるため、書類系の信号を分解した。

```text
hasDocumentSegmentation
documentLabelScore
documentVisualScore
documentScore
ocrPriorityScore
```

`hasDocumentSegmentation` は `VNDetectDocumentSegmentationRequest` が反応したかだけを示す。K PhoneのP0.5でも全バケットで全件検出されており、これ単体では書類判定に使わない。

スクショはPhotoKitの `photoScreenshot` を優先し、次のように扱う。

```text
スクショ = OCR優先
スクショ != 書類
```

`isScreenshot == true` の場合は `screenshotScore` と `ocrPriorityScore` を高くし、`documentScore` は抑制する。これにより、スクショ20件では `documentSegmentationDetected: 20`、`documentLabelCandidate: 20` のままだが、`finalDocumentCandidate: 0` になった。

CSVにはP0.5確認用として次を出力する。

```text
assetHash
bucketName
isScreenshot
pixelWidth
pixelHeight
topLabel1
topLabel1Confidence
topLabel2
topLabel2Confidence
topLabel3
topLabel3Confidence
hasFace
hasHuman
hasDocumentSegmentation
documentLabelScore
documentVisualScore
documentScore
screenshotScore
buildingScore
constructionSiteScore
signScore
whiteboardScore
receiptScore
businessCardScore
ocrPriorityScore
elapsedMs
expectedFormatTags
expectedContentTags
reviewNote
```

`expectedFormatTags`、`expectedContentTags`、`reviewNote` は人間が後で手動レビューするための空欄として残す。

## P0.5バケット

DEBUG限定のSettingsカードと起動引数で、次のバケットを実行できる。

```text
直近20件
直近100件
スクショ20件
スクショ以外20件
```

起動引数:

```text
-ShimaiBakoOpenSettingsTab
-ShimaiBakoRunVisionClassificationBenchmark20
-ShimaiBakoRunVisionClassificationBenchmark100
-ShimaiBakoRunVisionClassificationBenchmarkScreenshot20
-ShimaiBakoRunVisionClassificationBenchmarkNonScreenshot20
```

実装上は `VisionClassificationBenchmarkBucket` として、縦長、横長、読取済み、読取なしも定義している。ただしP0.5の実機evidenceは最低限の4バケットに限定した。

## P0.5 taxonomy

`VisionClassificationTaxonomy.swift` に、`VNClassifyImageRequest.supportedIdentifiers()` で確認できたラベルを中心に初期taxonomyを置いた。

有望な対応ラベル:

```text
building
house_single
lighthouse
skyscraper
crane_construction
billboards
sign
street_sign
whiteboard
document
newspaper
receipt
credit_card
food
seafood
blue_sky
mountain
night_sky
sky
```

未対応または今回の標準ラベルでは直接見つからなかったもの:

```text
architecture
blackboard
business_card
excavator
face
heavy_equipment
landscape
person
poster
site
```

人物・顔は分類ラベルではなく `VNDetectFaceRectanglesRequest` と `VNDetectHumanRectanglesRequest` で扱う。

## P0.5 K Phone結果

| Bucket | Count | Avg ms | Failed | Screenshots | Non-screenshots | Segmentation | Label doc | Final doc | OCR priority | Receipt |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 直近20 | 20 | 449.4 | 0 | 15 | 5 | 20 | 16 | 1 | 15 | 0 |
| 直近100 | 100 | 67.5 | 0 | 87 | 13 | 100 | 87 | 1 | 87 | 1 |
| スクショ20 | 20 | 533.3 | 0 | 20 | 0 | 20 | 20 | 0 | 20 | 0 |
| スクショ以外20 | 20 | 40.2 | 0 | 0 | 20 | 20 | 4 | 1 | 0 | 1 |

所感:

- document segmentationは全件反応し続けているため、書類候補の主判定にはしない。
- スクショ抑制により、スクショはOCR候補として残しつつ、書類候補から外せた。
- 直近サンプルでは建物、工事現場、看板、白板の実例が足りないため、P1前にカテゴリ別サンプルを用意する。
- 本番DB保存、整理タブ本実装、OCRジョブ連携はまだ行わない。

## P0.6実装

P0.6では、速度と精度評価のために次を追加した。

- `fullProbe` / `gatedProbe` の2モード
- Vision処理の時間内訳
- スクショ高速パス
- documentSegmentationの弱寄与化と、無効時スコア `documentScoreWithoutSegmentation`
- DEBUG限定の手動正解ラベルUI
- 正解ラベル付きprecision / recall評価の出力
- 建物、工事現場、看板、白板、図面、名刺、レシート、OCR必要判定の評価列

`fullProbe` は画像取得、画像分類、顔検出、人物矩形検出、書類セグメント検出、視覚特徴、スコアリングを実行する。

`gatedProbe` はスクショの場合に画像取得と重いVision requestを省略し、PhotoKitの `photoScreenshot` だけで次のように扱う。

```text
screenshotScore = 1.0
documentScore = 0.0
ocrPriorityScore = 0.85
```

スクショ以外では、P0.6時点の `gatedProbe` は `fullProbe` と同じ解析経路を使う。つまりP0.6の高速化対象はスクショである。

## P0.6時間内訳

K Phoneで実行した結果:

| bucket | mode | count | avg ms | image | classify | face | human | doc seg | visual | scoring |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| スクショ | fullProbe | 20 | 527.8 | 241.5 | 30.2 | 9.0 | 3.6 | 3.7 | 0.2 | 0.0 |
| スクショ | gatedProbe | 20 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| 直近 | fullProbe | 100 | 55.1 | 12.3 | 26.7 | 4.6 | 3.8 | 3.0 | 0.2 | 0.0 |
| 直近 | gatedProbe | 100 | 7.8 | 2.2 | 2.0 | 1.0 | 0.5 | 0.6 | 0.0 | 0.0 |
| スクショ以外 | fullProbe | 20 | 52.8 | 18.6 | 11.9 | 6.1 | 4.0 | 4.0 | 0.2 | 0.0 |
| スクショ以外 | gatedProbe | 20 | 49.3 | 16.0 | 11.3 | 6.0 | 4.0 | 3.9 | 0.2 | 0.0 |

直近100件ではスクショが多かったため、gatedProbeで平均55.1msから7.8msへ短縮できた。スクショ20件では画像取得とVision requestを省略できるため、ほぼ0msになった。

## P0.6信号評価

| bucket | mode | screenshots | finalDocument | ocrPriority | building | sign | whiteboard | receipt | businessCard | construction |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| スクショ | fullProbe | 20 | 0 | 20 | 0 | 0 | 0 | 0 | 0 | 0 |
| スクショ | gatedProbe | 20 | 0 | 20 | 0 | 0 | 0 | 0 | 0 | 0 |
| 直近 | fullProbe | 87 | 1 | 87 | 0 | 0 | 0 | 1 | 0 | 0 |
| 直近 | gatedProbe | 87 | 1 | 87 | 0 | 0 | 0 | 1 | 0 | 0 |
| スクショ以外 | fullProbe | 0 | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |
| スクショ以外 | gatedProbe | 0 | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |

P0.6でもdocumentSegmentationは過検出傾向が残るため、final document判定の主信号にはしない。P0.6では寄与を0.08まで下げ、`documentScoreWithoutSegmentation` を併記した。

## 手動正解ラベル

DEBUG限定のSettingsカードに、最新ベンチ結果の先頭20件へ正解ラベルを付けるUIを追加した。表示するのはサムネイル、top labels、主要score、スクショ/OCR優先/書類などの信号である。

保存先:

```text
Application Support/ShimaiBako/vision_benchmark_ground_truth.json
```

保存するもの:

- ハッシュ化asset identifier
- 正解ラベル
- 任意メモ
- 作成/更新日時

保存しないもの:

- 画像本体
- サムネイル本体
- 顔画像
- 顔テンプレート
- 人物識別情報

CLIからK Phone画面を手動操作できないため、今回のK Phone evidenceでは手動ラベル件数は0件である。UIから20件以上の手動ラベルを付けると、次回ベンチ出力にprecision / recallが含まれる。

## P0.8 手動ラベル付け支援

P0.8では、整理タブ本実装へ進まず、DEBUG限定の手動レビュー作業をしやすくする。目的は、Vision推定が本当に整理に使えるかを人間の正解ラベルで確認し、precision / recallを再計算できる状態にすることである。

手動ラベルが必要な理由:

- P0.6/P0.7のK Phone結果では、スクショ高速パスの速度は有望だった。
- ただし、正解ラベルが0件のため、スクショ/OCR必要/書類/看板/建物などのprecision / recallはまだ評価できない。
- documentSegmentationのように全件反応しやすい信号があるため、人間の正解なしに本番カテゴリへ入れると誤検出を増やす可能性がある。
- 建物、工事現場、看板、白板、図面、名刺はサンプル不足で、候補表示以上に進む根拠が足りない。

DEBUG限定Settingsカードでは、次のレビュー対象キューを作れる。

```text
直近20件
直近50件
直近100件
スクショ候補20件
スクショ以外20件
OCR優先候補20件
建物候補20件
工事現場候補20件
看板候補20件
白板候補20件
書類候補20件
```

候補別キューは、先に直近100件などのベンチを実行した後、その結果から抽出する。候補が少ない場合は、DEBUG UIに別キューを試す案内を出す。

K Phoneでのレビュー手順:

1. Debugビルドで設定タブを開く。
2. `Vision分類ベンチ` の `直近100 gated` などを実行する。
3. `レビュー対象キュー` から `直近20`、`OCR優先20`、`建物20` などを選ぶ。
4. サムネイル表示、top labels、推定タグ、scoreを見て正解ラベルを複数選択する。
5. `保存して次へ`、`スキップ`、`前へ`、`判定不能`、`ラベルをクリア` を使って20〜100件をレビューする。
6. `ラベル済みデータで評価` を押してprecision / recallを再計算する。
7. `評価をexport` で `p08_*` ファイルをApplication Supportへ出力し、必要に応じてrepoの `evidence/vision_classification_benchmark/` へコピーする。

レビューUIに表示する情報:

- 現在のレビュー件数
- ラベル済み件数
- 未ラベル件数
- 現在の写真番号
- 自動推定タグ
- top labels上位5件
- isScreenshot
- ocrPriorityScore
- documentScore
- buildingScore

P0.8のexport:

```text
p08_ground_truth_summary_*.md
p08_ground_truth_export_*.json
p08_evaluation_*.md
p08_evaluation_*.csv
p08_review_queue_summary_*.md
```

出力するasset identifierはハッシュ化済みである。画像本体、サムネイル本体、顔画像、顔テンプレートは出力しない。サムネイルはレビュー画面で表示するだけで保存しない。

ラベル件数が0件の場合は、評価ボタンとexportは動作するが、UIとMarkdownに「正解ラベルがないため評価できません」と表示する。0件の状態ではprecision / recallを判断材料にしない。

P0.8でも次は行わない。

- 整理タブ本実装
- 5タブ化
- ClassificationJob本実装
- 本番分類DBへの保存
- 写真タブカテゴリへの反映
- 読取タブ/BatchOCRへの連携
- 全数OCRの復活

## P0.6判断

- スクショはPhotoKitメタデータで高速判定し、重いVision分類を原則かけない。
- スクショは書類ではなくOCR優先として扱う。
- documentSegmentationはfinal document判定には使わない、または0.0〜0.1の弱い補助に留める。
- 建物、工事現場、看板、白板、図面は今回サンプル不足のため、Vision標準だけで十分とはまだ判断しない。
- 本実装に進む前に、人間が手動ラベルを付けた固定サンプルでprecision / recallを再評価する。

## 整理タブ本実装へ進む基準

P0.8後も、次を満たすまでは整理タブ本実装へ進まない。

- 少なくとも20〜50件の手動正解ラベルがある。
- スクショ/OCR必要のprecisionが高く、誤検出した場合の影響が小さいことを確認できている。
- 書類、看板、建物、工事現場の誤検出傾向を把握できている。
- documentSegmentationを単独の主判定にしない方針が維持されている。
- 建物/工事現場など弱いカテゴリを初期UIで過信しない表示方針が明確である。
- 画像本体、サムネイル本体、顔画像、顔テンプレートを保存しない設計を維持できる。
