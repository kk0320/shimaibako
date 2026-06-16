# テスト画像生成レポート

生成枚数: 100

## グループ別

- classification_samples: 40
- edge_cases: 20
- ocr_samples: 40

## 期待カテゴリ別

- 名刺 (business_card): 13
- 工事黒板 (construction_board): 5
- 書類写真 (document_photo): 13
- 家族写真 (family_photo): 7
- その他 (misc): 5
- 領収書 (receipt): 15
- スクショ (screenshot): 12
- 看板 (signboard): 13
- 旅行写真 (travel_photo): 5
- ホワイトボード (whiteboard): 12

## 方針

- すべてPillowでローカル生成しています。
- 外部画像素材、外部API、有料リソースは使っていません。
- manifest.json / manifest.csv に正解ラベルと期待OCRテキストを保存しています。

