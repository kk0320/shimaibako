# しまい箱 iOS ローカル実機検証RC

## RC対象commit

5b33bf3 Merge metadata organization empty assets hotfix

## RC判定

RC smoke result: PASS

main is releasable for local testing: yes

## 入っているもの

- 写真 / 整理 / 検索 / 読取 / 設定
- 整理タブ
- スクショ / 読取候補 / 要確認 / 未整理
- 仮想フォルダ
- 読取候補handoff
- 候補限定OCR
- 候補OCR後の候補件数減少
- BatchOCR保存先fallback
- 通常BatchOCR

## 入っていないもの

- Vision本番処理
- ClassificationJob
- 建物 / 工事現場 / 看板などの自動分類
- Core ML
- 全数OCR復活
- PhotoKit書き込み/削除API

## 検証結果

- K Phone build/install/launch PASS
- Simulator build/install/launch PASS
- safety checks PASS
- xcodebuild PASS
- metadata-only organization validation PASS
- 候補限定20件OCR PASS
- 通常BatchOCR回帰 PASS
- BatchOCR persistence validation PASS
- 5タブ起動 PASS
- 整理タブ仮想フォルダ起動 PASS
- 読取候補handoff PASS

## 安全条件

- 元写真・元動画を削除/変更しない
- 画像本体・サムネイル・顔画像・顔テンプレートを保存しない
- 外部APIを使わない
- クラウド送信しない
- Vision本番処理を起動しない
- ClassificationJobを追加しない
- 全数OCRを復活させない

## RC固定後の扱い

このRCは、ローカル実機検証用の安定点として固定する。App Store提出やTestFlight配布の判断は別途行う。

次フェーズP6では、Vision本番処理ではなく、整理タブと読取候補OCRの使い勝手改善を優先する。

## P7 ローカル実機検証RC

P6では、読取候補OCRのUX改善として、候補OCR前後summary、候補OCR結果カード、候補件数減少表示、0件候補時の案内を追加した。

P7では、P6を `main` へmergeした後、ローカル実機検証用RCとして次を確認した。

```text
P6 merge commit: ca5a077 Merge read candidate OCR UX polish
RC smoke result: PASS
main is releasable for local testing: yes
```

P7検証では、K Phoneで次の結果を確認した。

```text
metadata-only organization validation: PASS
metadataSource: photoLibraryAssets
libraryTotalAssets: 28060
processedAssets: 100
summaryTotalAssets: 28060
summaryClassifiedCount: 101
screenshotCount: 101
readCandidateCount: 101
usedVision: false
usedImageBody: false
usedThumbnailBody: false
usedPhotoKitWriteAPI: false

read candidate OCR 20 validation: PASS
beforeReadCandidateCount: 30
processedCandidateCount: 20
afterReadCandidateCount: 10
candidateCountDecreased: true
lastCandidateOCRSummarySaved: true
lastCandidateOCRStatus: completed
failedCount: 0
seriesCreated: false
nonCandidateIncluded: false

BatchOCR persistence validation: PASS
BatchOCR P1 regression: 0 / 20 / 50 / 100 PASS
BatchOCR P3 regression: 500 / 2,000 / 中断再開 PASS
```

P7でも引き続き、Vision本番処理、ClassificationJob、建物 / 工事現場 / 看板などの自動分類、Core ML、全数OCR復活には進まない。PhotoKit書き込み/削除APIは追加しない。画像本体、サムネイル本体、顔画像、顔テンプレート、大量特徴ベクトルは保存しない。

P7のRCタグは、P7 docs commit後の `main` HEAD を対象に `shimai-bako-ios-local-rc-p7-20260622` として固定する。既存タグ `shimai-bako-ios-local-rc-20260622` は移動しない。
