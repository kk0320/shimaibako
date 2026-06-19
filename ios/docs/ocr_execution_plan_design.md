# OCR実行計画設計

## 目的

OCRの選択UI、確認画面、候補件数、端末状態判定、ジョブ作成を `OCRExecutionPlan` から決定する。複数のBoolや別々の選択値でOCR種別を持たないことで、クイックOCRの確認画面に全数OCRの温度判定が混ざる状態を防ぐ。

## 実行計画

- `quick`: 表示中候補から最大20/50/100件だけOCRする
- `filteredAll`: 現在の検索、表示状態、カテゴリ、スクショ細分類の絞り込み結果を永続ジョブでOCRする
- `smartLibrary`: ライブラリ全体を対象に、スクショや書類を優先する推奨の全数OCR
- `accuracyReview`: スマート全数OCR後に検索精度をさらに上げたい場合の上級者向け処理

`QuickOCRLimit` は20/50/100件のみを持つ。まとめてOCRはこの値だけを使い、全数OCRや高精度OCRを開始しない。

## 温度判定

端末状態判定は `OCRExecutionPlan.workloadClass` から決める。

- quick 20件: small
- quick 50/100件: medium
- filteredAll: large
- smartLibrary: longRunning
- accuracyReview: heavy

thermal fair は開始可能で、実行中は減速する。thermal serious は large/longRunning/heavy の開始を止めるが、small/medium は容量不足など別のブロック条件がなければ開始できる。thermal critical はすべて開始しない。

## 画面分離

まとめてOCRの確認画面は `quick` 専用で、20/50/100件だけを表示する。全数OCRは写真タブの詳細内にある `全数OCRを管理` から専用確認画面へ進む。

全数OCR確認画面では、20/50/100件の選択肢を表示しない。スマート全数OCRではスクショ・書類優先、上級者向け処理では重い処理であることを明記する。

## 開始処理

Viewは `OCRExecutionPlan` を作って開始要求を渡すだけにする。永続ジョブの対象抽出とジョブ作成は `OCRJobRunner` 側で行う。開始ボタン押下後は確認画面を閉じ、準備中状態を表示してUIを返す。

現段階では既存のOCRジョブDBへ対象を作成する。28,000件規模では、今後は対象COUNT、次の小バッチ取得、結果保存、次バッチ取得の流れへさらに分割する。

## Debug用ダミーOCR

Debug buildでは `UserDefaults` の `shimaibako.debugDummyOCR` を true にすると、Vision OCRの代わりに約100ms待って `test` を返す。これは実OCRとUI/DB負荷の切り分け用で、本番UIには表示しない。

## 安全方針

OCRは端末内で実行し、写真アプリ内の元写真・元動画を削除・変更しない。PhotoKit書き込み/削除APIは使わない。
