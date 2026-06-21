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
