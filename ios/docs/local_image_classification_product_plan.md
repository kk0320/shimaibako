# ローカル画像分類 P1 実装方針

## P0.10の結論

画像分類spikeは P0.10 で一旦終了し、製品実装へ進む。

- Engine Go: yes
- Workflow Go: スクショ / 読取候補のみ yes
- Category Go: no
- Product Go: no

P1では、分類エンジンを製品内で実行する段階には進めない。まず整理タブと分類データ保存の土台を入れる。

## P1の範囲

- 5タブ構成: 写真 / 整理 / 検索 / 読取 / 設定
- 整理タブの最小骨格
- 分類データモデル
- 分類ストアの土台
- 手動分類優先ルール
- 保存してよいデータと保存しないデータの明確化

整理タブを開いても、画像認識、全件処理、バックグラウンド分類は開始しない。

## 一般UIで出す分類

初期版で通常表示してよい分類は次の範囲に限定する。

- スクショ
- 読取候補
- 要確認
- 未整理

スクショは PhotoKit のメタデータを優先する。読取候補と要確認は、今後の分類ジョブや読取タブ連携のための受け皿として扱う。

## まだ通常表示しない分類

次の分類は内部taxonomyや将来候補として残してよいが、十分な検証が終わるまで通常UIの自動フォルダとして断定表示しない。

- レシート候補
- 名刺候補
- 書類候補
- 看板候補
- 白板候補
- 建物候補
- 工事現場候補
- 図面候補
- 車両・重機候補
- 資材・設備候補
- 食べ物候補
- 風景候補

## 分類データモデル

`PhotoClassification` は写真の識別子を主キーにする。

- `assetIdentifier`
- `schemaVersion`
- `classifierVersion`
- `analysisState`
- `autoPrimaryCategory`
- `manualCategory`
- `resolvedCategory`
- `formatTags`
- `contentTags`
- `screenshotScore`
- `documentScore`
- `personScore`
- `ocrPriorityScore`
- `buildingScore`
- `constructionSiteScore`
- `signScore`
- `whiteboardScore`
- `drawingScore`
- `receiptScore`
- `businessCardScore`
- `confidenceBand`
- `scoreMargin`
- `isScreenshot`
- `containsPerson`
- `faceCount`
- `createdAt`
- `updatedAt`
- `manualUpdatedAt`

P1では未使用のスコア項目があってもよい。将来SQLiteやSwiftDataへ移行しやすいよう、分類レコードとして分離しておく。

## 手動分類優先

自動分類と手動分類は分けて保存する。

```text
resolvedCategory = manualCategory ?? autoPrimaryCategory
```

将来の再分類や分類ジョブを追加しても、`manualCategory` は上書きしない。手動分類がある写真では、表示上の分類も手動分類を優先する。

## 保存するデータ

しまい箱内に保存してよいものは、分類や検索のための軽量データに限定する。

- 分類カテゴリ
- タグ
- スコア
- 状態
- 更新日時
- バージョン
- 写真の識別子

## 保存しないデータ

P1では次のデータを保存しない。

- 元写真
- 元動画
- サムネイル本体
- 顔画像
- 顔テンプレート
- 人物識別データ
- 大量特徴ベクトル
- 外部送信用データ

## 安全方針

- 元写真・元動画は削除・変更しない
- 写真アプリ側にアルバムやフォルダを作らない
- PhotoKit の書き込み/削除APIは使わない
- 外部APIは使わない
- 写真本体を外部送信しない
- 有料APIやクラウドDBは使わない

## P1でまだ実装しないもの

- Vision分類の本番実行
- ClassificationJob
- 100/500/2,000件の分類バッチ
- 整理タブからの自動分類開始
- 読取タブへの読取候補本連携
- 建物や工事現場などの自動フォルダ公開
- Core ML外部モデル
- ネット画像fixture

## 既存機能への影響方針

- 写真タブは写真を見る場所として維持する
- 検索タブの既存検索は変更しない
- 読取タブのBatchOCRには接続しない
- 設定タブには分類データの保存内容だけを表示する
- 整理タブを開いても重い処理を開始しない

## P2の目的

P2では、画像認識を使わず、すでに安全に扱える軽量メタデータだけで整理タブの件数を実データ化する。

- スクショ
- 読取候補
- 要確認
- 未整理
- 分類済み
- 全体件数

整理タブを開いただけでは処理を開始しない。ユーザーが「軽量整理を更新」を押した時だけ、読み込み済み範囲のメタデータ整理を行う。

## メタデータのみで整理する理由

3万枚規模でも安全に段階導入するため、P2では画像本体、サムネイル、Vision解析、顔検出、特徴ベクトルを使わない。PhotoKitのメタデータと既存インデックスの読取状態だけを使う。

この方針により、写真タブ、検索タブ、読取タブの既存処理を重くしない。

## P2の分類ルール

### スクショ

PhotoKitの `isScreenshot` 相当のメタデータを使う。

```text
isScreenshot == true
→ formatTags に screenshot
→ autoPrimaryCategory = screenshot
→ screenshotScore = 1.0
→ documentScore = 0.0
→ ocrPriorityScore = 0.85
```

スクショは「書類」とは扱わず、読取優先の候補として扱う。手動分類がある場合は手動分類を優先する。

### 読取候補

初期条件は次のとおり。

```text
スクショ かつ 既存インデックス上で読取未処理
```

P2では、書類っぽさ、看板っぽさ、名刺っぽさなどは画像解析で判定しない。読取候補は `contentTags` に `readCandidate` を保存して表現する。

### 要確認

P2では無理に作らない。分類状態の競合や破損など、明確な理由がある場合だけ使う。通常は0件でよい。

### 未整理

次のいずれかを未整理として扱う。

- `PhotoClassification` が存在しない
- `analysisState` が未解析
- `resolvedCategory` がない

軽量整理更新後も、スクショでも手動分類でもない写真は未整理のまま残る。

## P2で保存するデータ

- 写真の識別子
- 分類状態
- 自動分類カテゴリ
- 手動分類カテゴリ
- 解決済み分類カテゴリ
- フォーマットタグ
- 内容タグ
- スクショスコア
- 書類スコア
- 読取優先スコア
- スクショ判定
- 更新日時
- classifierVersion
- schemaVersion

## P2で保存しないデータ

- 画像本体
- 動画本体
- サムネイル本体
- 顔画像
- 顔テンプレート
- 人物識別データ
- 特徴ベクトル
- 外部送信用データ

## P2でまだ行わないこと

- Vision分類の本番実行
- 画像ファイル解析
- サムネイル解析
- 顔検出
- 人物検出
- 書類検出
- 建物/工事現場/看板の自動分類
- ClassificationJob
- 100/500/2,000件の分類バッチ
- 読取タブへの読取候補本連携

## 手動分類優先の継続

P2の軽量整理を再実行しても、`manualCategory` は上書きしない。

```text
resolvedCategory = manualCategory ?? autoPrimaryCategory
```

手動分類済みの写真は、軽量整理更新後も手動分類を表示上の分類として維持する。

## P2.6 DEBUG軽量整理検証

P2.6では、実機画面を自動タップできない環境でも、整理タブの「軽量整理を更新」ボタン相当の経路を確認できるようにする。DEBUGビルド限定で次の起動引数を使う。

```text
-ShimaiBakoRunMetadataOnlyOrganizationValidation
```

この起動引数では、整理タブのボタンと同じ `PhotoClassificationService.updateMetadataOnly` 経路を呼び出す。ボタン専用とは別の検証ロジックを作らず、読み込み済み写真と既存PhotoIndexメタデータだけで件数更新できることを確認する。

検証結果はアプリ内の次のJSONに保存する。

```text
Application Support/ShimaiBako/debug_metadata_organization_validation.json
```

既存検証データなどの影響で上記ディレクトリに書き込めない場合は、同じApplication Support内の次の場所へフォールバックする。

```text
Application Support/ShimaiBakoData/debug_metadata_organization_validation.json
```

それでも実機環境でApplication Supportへの書き込みが拒否される場合は、アプリ内DocumentsまたはCachesの `ShimaiBakoData` 配下へ退避する。いずれもアプリ内データであり、写真本体やサムネイル本体は保存しない。

JSONには次を記録する。

- 全体件数
- 分類済み件数
- スクショ件数
- 読取候補件数
- 要確認件数
- 未整理件数
- 更新した分類件数
- 手動分類保護件数
- 手動分類優先セルフテスト結果
- Vision、画像本体、サムネイル本体、PhotoKit書き込みAPIを使っていないこと

必要に応じて、整理タブを開く起動引数と組み合わせる。

```text
-ShimaiBakoOpenOrganizationTab
-ShimaiBakoRunMetadataOnlyOrganizationValidation
```

### P2.6で使わないもの

- Vision分類の本番処理
- 画像本体取得
- サムネイル本体取得
- 顔画像、顔テンプレート、特徴ベクトル
- ClassificationJob
- 読取タブ本連携
- PhotoKit書き込み/削除API

### main merge前の合格条件

- DEBUG起動引数で軽量整理検証が完了する
- `totalAssets > 0` の実機環境で検証JSONがPASSになる
- `manualCategory` が自動分類で上書きされない
- 整理タブsummaryが保存済み分類データから読める
- 写真タブ、検索タブ、読取タブ、設定タブが起動できる
- BatchOCR、検索、写真タブの性能に影響しない
- 元写真・元動画を削除・変更しない

## P2.7 整理summary件数の整合性

P2.6の実機検証で `totalAssets: 100` になった理由は、DEBUG検証が整理タブのボタンと同じく、現在読み込み済みの `photoLibrary.assets` を対象にしているためである。軽量モードでは読み込み済み範囲が直近100件なので、これは検証上限/読み込み済み範囲であり、写真ライブラリ全体件数ではない。

通常UIでは、次の件数を分けて表示する。

- 写真ライブラリ全体件数: PhotoIndex/SQLiteまたはPhotoKitが把握している全体件数
- 軽量整理済み件数: `PhotoClassificationStore` に保存済みの分類データ件数
- 今回更新した件数: 直近の `updateMetadataOnly` で処理した件数
- 未整理件数: 分類済み件数を除いた未確認分を含む推定件数

軽量整理更新はP2時点では全件処理ではない。画像本体、サムネイル本体、Visionを使わず、読み込み済み範囲のPhotoKitメタデータと既存PhotoIndexメタデータだけを整理する。UIには「現在読み込み済みの範囲」または「直近100件を軽量整理しました」のように表示し、2.8万枚規模の全体件数と混同しないようにする。

DEBUG検証JSONには、100件が検証上限かどうかを判断できるように次の項目を含める。

- `libraryTotalAssets`
- `validationLimit`
- `processedAssets`
- `classificationStoreTotal`
- `summaryTotalAssets`
- `summaryClassifiedCount`

main merge前の確認では、`libraryTotalAssets` が実ライブラリ全体、`processedAssets` が今回処理した範囲であることを確認する。

## P3 整理タブの仮想フォルダ化

P3では、整理タブのsummaryを実際に開ける「しまい箱内だけの仮想フォルダ」にする。仮想フォルダはアプリ内の分類データとPhotoIndexメタデータで表示を切り替えるだけで、写真アプリ側の元写真・元動画を移動・変更しない。

### P3で表示する仮想フォルダ

通常UIで公開するフォルダは、P2までに安全性を確認した次の4つに限定する。

- スクショ
- 読取候補
- 要確認
- 未整理

各フォルダは整理タブの「自動フォルダ」カードから開ける。一覧は既存のPhotoKit参照とサムネイル取得経路を使い、表示中の写真だけを必要に応じて取得する。

### 取得条件

- スクショ: `formatTags` に `screenshot` がある、または `resolvedCategory == screenshot`、またはスクショメタデータがある
- 読取候補: `contentTags` に `readCandidate` がある、または `resolvedCategory == readCandidate`
- 要確認: `analysisState == needsReview`、または `resolvedCategory == needsReview`
- 未整理: 分類レコードがない、`resolvedCategory == nil`、`resolvedCategory == unorganized`、または `analysisState == notAnalyzed`

未整理は2.8万枚規模になる可能性があるため、PhotoIndexの識別子を小分けに読み、最初は100件だけ表示する。ユーザーが「さらに表示」を押した場合だけ、次の候補を追加する。

### P3で表示しないカテゴリ

次のカテゴリは内部taxonomyまたは将来候補として残すが、P3の通常UIには出さない。

- 建物
- 工事現場
- 看板
- 白板
- 図面
- 名刺
- レシート
- 車両・重機
- 資材・設備
- 食べ物
- 風景

これらはVision分類や実機評価が十分に終わってから、別フェーズでUI公開を検討する。

### P3で行わないこと

- Vision分類の本番処理
- ClassificationJobの追加
- 読取候補から読取タブへの本連携
- 500件/2,000件OCRへの候補リスト引き渡し
- 画像本体、サムネイル本体、顔画像、顔テンプレート、特徴ベクトルの保存
- PhotoKit書き込み/削除APIの追加

読取候補フォルダはP3では開けるだけに留め、読取タブとの連携はP4以降で扱う。

### DEBUG起動引数

仮想フォルダの起動確認用に、DEBUGビルド限定で次の起動引数を使える。

```text
-ShimaiBakoOpenOrganizationScreenshotsFolder
-ShimaiBakoOpenOrganizationReadCandidatesFolder
-ShimaiBakoOpenOrganizationUnorganizedFolder
```

これらは整理タブを選択し、対象フォルダ画面を直接開くための検証導線である。Release相当の通常UIには影響しない。
