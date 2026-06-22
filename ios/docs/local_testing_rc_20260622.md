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
