# 画像分類と整理タブ設計

## 目的

しまい箱の画像分類は、写真を削除・移動せずに、アプリ内だけで探しやすい整理状態を作るための機能とする。

OCRは文字検索を強くする補助機能として扱い、画像分類では写真の内容や形式から「整理に役立つ候補」を作る。写真アプリ内の元写真・元動画、アルバム、iCloud写真の原本は変更しない。

## タブ構成

最終UIは次の5タブにする。

```text
写真 / 整理 / 検索 / 読取 / 設定
```

「画像認識」というタブ名は使わず、ユーザー目的が分かる「整理」を使う。整理タブの画面タイトルは次の表記にする。

```text
画像認識で自動整理
```

## 各タブの役割

### 写真

写真を見る・手動整理する場所。

置くもの:

- 写真一覧
- 表示状態フィルター
- カテゴリ表示
- 手動分類
- 不要候補
- 非表示
- 詳細画面

置かないもの:

- 重い画像認識バッチ
- OCR実行
- OCR進捗
- 検索インデックス再構築

### 整理

画像認識による自動整理を進める場所。

置くもの:

- 自動フォルダ
- 分類済み、未分類、要確認
- 画像分類バッチ
- 手動修正
- OCR候補作成
- 分類精度確認

### 検索

探すための場所。

置くもの:

- キーワード検索
- OCR文字検索
- 自動フォルダ検索
- カテゴリ検索
- メモ、タグ、日付検索

### 読取

OCRを実行・再開する場所。

置くもの:

- 20 / 50 / 100 / 500 / 2,000件OCR
- 続きから再開
- 自動で次の2,000件へ進む
- 分類結果からOCR候補を選ぶ
- 失敗分再試行

### 設定

管理・復旧・安全説明の場所。

置くもの:

- 分類データ再構築
- 読取結果削除
- 検索データ修復
- ジョブ状態整理
- Debug項目
- プライバシーと安全説明

## 分類方式

「人物 / 食べ物 / 風景 / 書類 / スクショ / その他」のような排他的な6分類にはしない。内部は複数タグ方式にする。

同じ写真が複数の自動フォルダに入ってよい。

例:

```text
人物あり
食べ物
風景・屋外
建物
工事現場
看板
書類
スクショ
```

写真一覧用には代表カテゴリを1つ持ってよい。ただし、内部の検索・整理では複数タグを維持する。

## 初期自動フォルダ

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

建物と工事現場は分ける。

- 建物: 完成建物、外観、内観、ビル、住宅
- 工事現場: 足場、施工中、仮設、重機、現場全景

## P0.9後の初期公開範囲

P0.9の合成fixtureは、Engine Goの判断材料として使う。本番UIへ出す分類範囲は、合成fixtureや一般公開画像だけでは決めない。

P0.10の失敗分析では、K Phoneで `contractPass 56/56`、`ocrPriorityPass 41/50` だった。一方で、レシート、名刺、書類、看板、白板、図面の `categorySignalPass` は十分ではない。したがって、分類エンジンの処理経路と読取候補の方向性はGo寄りだが、カテゴリ自動フォルダはまだNo-Goとする。

一般UIで初期公開してよい候補:

```text
スクショ
読取候補
要確認
```

条件付き候補:

```text
書類かもしれない写真
```

DEBUGまたは社内テストに留める候補:

```text
建物候補
工事現場候補
看板候補
白板候補
図面候補
車両・重機候補
資材・設備候補
名刺候補
レシート候補
食べ物候補
風景候補
```

建物は重要カテゴリとしてtaxonomyには残す。ただし、許可済みの現場写真や自分で撮影した写真で十分に検証できるまでは、一般向け自動フォルダとして断定表示しない。

まだ一般UIに出さない自動フォルダ:

```text
レシート自動フォルダ
名刺自動フォルダ
書類自動フォルダ
看板自動フォルダ
白板自動フォルダ
建物自動フォルダ
工事現場自動フォルダ
図面自動フォルダ
車両・重機自動フォルダ
資材・設備自動フォルダ
```

P0.10では、K Phoneを正規評価環境、Simulatorをsmoke確認環境として扱う。Simulatorの `espressoContextError` は環境制約として棚卸しし、K Phoneでも同じ失敗が出るかを確認する。

File-based fixture benchmarkは `fixtures/vision_benchmark/` の開発用画像を使う。fixture画像は製品Bundleに含めず、本番分類DB、写真タブカテゴリ、読取タブOCR候補へ反映しない。

## OCR候補連携

画像分類結果からOCR優先度を出す。

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

建物だけではOCR候補にしない。建物に文字がありそう、工事現場に看板っぽい要素がある、などの複合条件で候補に入れる。

内部的には `ocrPriorityScore` を持たせる。

## データモデル案

本実装では、OCRとは別の分類データとして `PhotoClassification` を検討する。

```text
assetIdentifier
analysisState
schemaVersion
classifierVersion
visionRevision
sourceRevision

autoPrimaryCategory
manualCategory
resolvedCategory

formatTags
contentTags

screenshotScore
documentScore
personScore
foodScore
landscapeScore
buildingScore
constructionSiteScore
signScore
whiteboardScore
businessCardScore
receiptScore

ocrPriorityScore

confidenceBand
scoreMargin

isScreenshot
containsPerson
faceCount

signalFlags
topLabelsData
ocrSignalFlags

createdAt
updatedAt
manualUpdatedAt
```

手動分類は必ず自動分類と分けて保存する。

```text
resolvedCategory = manualCategory ?? autoPrimaryCategory
```

画像分類を再実行しても、`manualCategory` を上書きしない。

## ClassificationJob

OCRの `BatchOCRJob` とは別に `ClassificationJob` を作る。状態や保存先を混ぜない。

ClassificationJob state:

```text
preparing
running
pausedUser
pausedBackground
pausedThermal
completed
failed
```

ClassificationItem state:

```text
pending
processing
classified
ambiguous
failed
skippedManual
```

実行件数:

```text
100件
500件
2,000件
```

OCRと画像分類は同時に重く走らせない。将来的に `DeviceAnalysisCoordinator` のような排他制御を検討する。

## 整理タブ案

```text
整理

自動整理状況
分類済み 8,420 / 28,105件

自動フォルダ

形式
[スクショ] [書類] [図面] [名刺]
[レシート] [看板] [白板]

内容
[建物] [工事現場] [人物]
[車両・重機] [資材・設備] [風景]

要確認
分類が曖昧な写真 184件

分類を進める
[100件] [500件] [2,000件]

読取候補
文字がありそうな未読取写真 1,248件
[読取タブで確認]
```

高信頼度は自動フォルダへ入れる。中信頼度は要確認へ入れる。低信頼度は未分類へ残す。

## 読取タブ連携案

整理タブの分類結果から読取候補を作る。

```text
読取候補

名刺 42件
レシート 118件
書類 326件
図面 89件
看板・掲示 236件
白板・黒板 57件
スクショ 1,120件

[選択した自動フォルダから最大500件を読み取る]
```

ランダムな2,000件ではなく、文字検索に役立つ写真から優先的に読取できるようにする。

## 保存するデータ

保存してよいもの:

- 軽量な分類結果
- 代表カテゴリ
- 複数タグ
- スコア
- 信頼度帯
- 状態
- OCR優先度
- Visionのラベル名とスコアの要約

## 保存しないデータ

保存しないもの:

- 写真本体
- サムネイル本体
- 顔画像
- 顔テンプレート
- 人物識別情報
- 大量特徴ベクトル
- 写真アプリ側のアルバム変更情報

## 安全条件

- 元写真・元動画は削除・変更しない
- PhotoKit書き込み/削除APIは使わない
- 外部APIを使わない
- 画像を外部送信しない
- 有料APIを使わない
- 顔画像を保存しない
- 顔テンプレートを保存しない
- 人物識別をしない
- 画像本体を保存しない
- 大量特徴ベクトルを保存しない
- 手動分類を自動分類で上書きしない

## ブランチ方針

画像分類は `feature/persistent-batch-ocr` へ混ぜない。

評価用spike:

```text
spike/vision-classification-benchmark
```

本実装:

```text
feature/local-image-classification
```

spikeで分類精度・速度・発熱・誤分類を確認してから、本実装ブランチへ進む。

## P0ベンチ境界

`spike/vision-classification-benchmark` では、Vision標準機能の信号確認だけを行う。

実装するもの:

- DEBUG限定のVision分類ベンチ
- 20件 / 100件の小規模解析
- `VNClassifyImageRequest` のラベル棚卸し
- 顔検出、人物矩形検出、書類セグメント検出の件数記録
- ハッシュ化したasset identifierと軽量な解析結果のevidence保存

実装しないもの:

- 整理タブの本実装
- 5タブ化の本実装
- ClassificationJobの本格実装
- 2,000件分類ジョブ
- 画像分類結果の写真タブ反映
- OCR候補への自動投入
- 外部Core MLモデルの同梱

P0ベンチ結果は、本番DBの分類結果として保存しない。OCR結果、BatchOCRJob、検索インデックス、手動分類、不要候補、メモ、タグには影響させない。

K Phoneの直近100件ベンチでは、Vision解析自体は失敗0で実行できた。一方で `documentScore` は過検出気味だったため、次フェーズではカテゴリ別サンプルで精度としきい値を見直す。

## P0.5結果と設計判断

P0.5では、`documentScore` を分解し、スクショと書類を分離した。

```text
hasDocumentSegmentation
documentLabelScore
documentVisualScore
documentScore
ocrPriorityScore
```

K Phoneでは、`VNDetectDocumentSegmentationRequest` が直近20件、直近100件、スクショ20件、スクショ以外20件のすべてで全件反応した。したがって `hasDocumentSegmentation` は「書類らしさ」の決定打ではなく、補助信号に留める。

スクショはPhotoKitの `photoScreenshot` を優先し、`documentScore` を抑制する。スクショは書類ではないが、文字検索の価値が高いため `ocrPriorityScore` は高くする。

P0.5のK Phone結果:

```text
直近20件: finalDocumentCandidate 1 / ocrPriorityCandidate 15
直近100件: finalDocumentCandidate 1 / ocrPriorityCandidate 87
スクショ20件: finalDocumentCandidate 0 / ocrPriorityCandidate 20
スクショ以外20件: finalDocumentCandidate 1 / ocrPriorityCandidate 0
```

この結果から、整理タブ本実装へ進む前に次を行う。

- スクショ、書類、領収書、看板、白板、建物、工事現場の固定サンプルを用意する。
- `VisionClassificationTaxonomy.swift` のラベルセットを、supportedIdentifiersで実在確認できたものだけに寄せる。
- `documentSegmentation` は過検出信号として扱い、ラベル、視覚ルール、OCR結果候補と組み合わせる。
- スクショは「記録・メモ」用途として独立させ、書類候補とは別集計にする。
- OCR候補作成には `ocrPriorityScore` を使い、画像分類カテゴリとは混ぜない。

P0.5でも、画像本体、サムネイル本体、顔画像、顔テンプレート、人物識別情報、大量特徴ベクトルは保存しない。本番分類DB、写真タブ、読取タブ、BatchOCRJob、検索インデックスには反映しない。

## 初期taxonomyメモ

Vision標準ラベルで確認できた初期候補:

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

直接確認できなかった、または別信号で扱うべきもの:

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

人物や顔はラベルではなくVisionの矩形検出を使う。名刺は `business_card` がないため、P0.5では `credit_card` を弱い仮信号として扱うが、本番ではOCRテキストや手動レビューとの併用が必要。

## P0.6結果からの設計更新

P0.6では `fullProbe` と `gatedProbe` を比較した。K Phoneの直近100件では、`fullProbe` が平均55.1ms/件、`gatedProbe` が平均7.8ms/件だった。直近100件中87件がスクショだったため、スクショ高速パスの効果が大きい。

採用候補:

- スクショはPhotoKitメタデータで判定する。
- スクショには原則として画像分類、顔検出、人物検出、書類セグメント検出をかけない。
- スクショは書類候補ではなくOCR優先候補として扱う。
- 書類候補は `documentLabelScore` と `documentVisualScore` を優先する。
- `documentSegmentation` は過検出するため、final判定の主信号にしない。

P0.6でまだ弱いもの:

- 建物
- 工事現場
- 看板
- 白板
- 図面
- 名刺

これらは今回のK Phoneサンプルに十分な実例がなかった。Vision標準だけで本実装へ進むには、手動正解ラベル付きの固定サンプルでprecision / recallを確認する必要がある。

## 本実装へ進む条件

最初の本実装では、次の信号だけを採用候補にする。

- スクショ判定
- OCR優先判定
- レシート/書類の弱い候補
- 顔/人物の「含む可能性」カウント

次はまだ候補扱いに留める。

- 建物
- 工事現場
- 看板
- 白板
- 図面
- 名刺

外部Core MLモデルはまだ導入しない。Core MLを検討する場合は、モデルサイズ、ライセンス、端末負荷、オフライン動作、削除可能なキャッシュ設計を別途確認する。

P0.6でも、画像本体、サムネイル本体、顔画像、顔テンプレート、大量特徴ベクトルは保存しない。分類結果は本番DB、写真タブ、読取タブ、BatchOCRJobには反映しない。

## P0.8 手動評価ワークフロー

P0.8では、本実装の設計を増やすのではなく、DEBUG限定で手動正解ラベルを付けやすくする。整理タブ、5タブ化、ClassificationJob、読取タブ連携には進まない。

目的:

- 20〜100件のレビュー対象キューを作る。
- スクショ、スクショ以外、OCR優先、建物、工事現場、看板、白板、書類の候補を優先的に確認する。
- ラベル済み件数、評価対象件数、タグ別件数をSettingsのDEBUGカードで確認する。
- ラベル済みデータからprecision / recallを再計算する。
- `p08_*` evidenceを出力し、画像を含まない形で判断材料を残す。

レビュー対象キュー:

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

正解ラベルは複数選択できる。`判定不能` は評価対象から除外する。判定不能を選んだ場合は単独ラベルとして扱い、通常ラベルを選ぶ場合は判定不能を外す。

評価再実行:

- `ラベル済みデータで評価` で、最新ベンチ結果と保存済み正解ラベルを照合する。
- 出力指標は `support`、`TP`、`FP`、`FN`、`precision`、`recall`。
- `support` はそのタグが正解として付いた件数である。
- ラベル件数が0件の場合は「正解ラベルがないため評価できません」と表示し、precision / recallを判断材料にしない。

P0.8の安全境界:

- サムネイルはレビュー画面表示だけに使い、保存しない。
- evidenceには画像本体、サムネイル本体、顔画像、顔テンプレートを含めない。
- asset identifierはハッシュ化した値だけを出す。
- 本番分類DB、写真タブカテゴリ、読取タブ、BatchOCRJob、検索インデックスには反映しない。

整理タブ本実装へ進む基準:

- 最低20〜50件の手動ラベルがある。
- スクショ/OCR必要が高precisionである。
- 書類/看板/建物/工事現場の誤検出傾向を説明できる。
- 弱いカテゴリは候補表示に留め、断定しないUI方針が決まっている。
- 手動分類を自動分類より優先する保存設計を維持できる。
