# 外部画像OCR・分類評価レポート

## 対象

- データセット: `data/external_test_assets`
- manifest件数: 100
- DB登録件数: 100
- サムネイルあり: 100

## ライセンス管理

- `manifest.json` と `manifest.csv` に出典URL、出典サイト、ライセンス名、作者/クレジット、同梱可否を保存しています。
- NC/ND付きライセンスは、利用条件が複雑になりやすいため `allowed_for_demo_bundle=false` にしています。

## 出典別

- Openverse / flickr: 96
- Openverse / nasa: 2
- Openverse / rawpixel: 1
- Openverse / thingiverse: 1

## ライセンス別

- CC BY 2.0: 43
- CC BY-NC 2.0: 8
- CC BY-NC-ND 2.0: 8
- CC BY-NC-SA 2.0: 25
- CC BY-ND 2.0: 2
- CC BY-SA 2.0: 11
- CC0 1.0: 2
- Public Domain Mark: 1

## デモ同梱可否

- false: 43
- true: 57

## OCR結果

- OCR済み: 100/100
- OCRエラー: 0
- OCRテキストあり: 86/100
- `expected_keywords` は検索/分類用の期待語です。外部写真の可視文字を人手で転記したOCR正解ではありません。
- 期待キーワードがOCRテキストに入った画像: 0/100
- OCRキーワード一致数: 0/293

## 分類結果

- 分類一致: 100/100

### 期待カテゴリ

- document_photo: 17
- receipt: 8
- signboard: 20
- travel_photo: 48
- whiteboard: 7

### 推定カテゴリ

- document_photo: 17
- receipt: 8
- signboard: 20
- travel_photo: 48
- whiteboard: 7

## 重複候補

- 外部画像データセット内の重複ハッシュグループ: 0

## OCR成功例

- EXT-090 ext-090_documents_Le_Canard_encha_n_t_1915.jpg: chars=1901 keywords=0 category=document_photo
- EXT-089 ext-089_documents_Mobilmachung._Affiche._Karslruhe_K_niglisch_Pressisches.jpg: chars=1868 keywords=0 category=document_photo
- EXT-049 ext-049_signboard_Merry_Christmas_1.jpg: chars=1092 keywords=0 category=signboard
- EXT-064 ext-064_signboard_Police_Warning.jpg: chars=971 keywords=0 category=signboard
- EXT-087 ext-087_documents_Ordinance_relating_to_regulation_and_collection_of_licenses_1872_laarc-1.jpg: chars=936 keywords=0 category=document_photo
- EXT-085 ext-085_documents_Ordinance_relating_to_regulation_and_collection_of_licenses_1872_laarc-1.jpg: chars=765 keywords=0 category=document_photo
- EXT-078 ext-078_desk_My_desk_office.jpg: chars=583 keywords=0 category=document_photo
- EXT-100 ext-100_documents_Revisionary_Survey_for_the_determination_of_the_Light_Houses_and_Defensi.jpg: chars=473 keywords=0 category=document_photo

## OCR弱い/失敗例

- EXT-019 ext-019_landscape_Columbia_River_Gorge_view_from_near_Hood_River.jpg: status=done chars=0 keywords=0 category=travel_photo
- EXT-067 ext-067_signboard_DSC_0329ax.jpg: status=done chars=0 keywords=0 category=signboard
- EXT-069 ext-069_whiteboard_My_office.jpg: status=done chars=0 keywords=0 category=whiteboard
- EXT-076 ext-076_desk_Always_Writing.jpg: status=done chars=0 keywords=0 category=document_photo
- EXT-077 ext-077_desk_When_Math_Goes_Horribly_Wrong.jpg: status=done chars=0 keywords=0 category=document_photo
- EXT-083 ext-083_desk_Collaboration.jpg: status=done chars=0 keywords=0 category=document_photo
- EXT-093 ext-093_labels_CCCP2.jpg: status=done chars=0 keywords=0 category=receipt
- EXT-072 ext-072_whiteboard_Photo_Series_Life_at_the_Office_Aimless_Magnets_-_nothing_to_hold.jpg: status=done chars=1 keywords=0 category=whiteboard
- EXT-016 ext-016_landscape_Waterton_National_Park_2009.jpg: status=done chars=2 keywords=0 category=travel_photo
- EXT-066 ext-066_signboard_Waterloo_Underground_Station_-_sign.jpg: status=done chars=2 keywords=0 category=signboard
- EXT-025 ext-025_buildings_office_building.jpg: status=done chars=6 keywords=0 category=travel_photo
- EXT-074 ext-074_whiteboard_Empty_office_meeting_room.jpg: status=done chars=8 keywords=0 category=whiteboard

## 分類不一致例

- なし

## 注意

- 画像は外部送信せず、ローカルスキャンとローカルOCRだけで評価しています。
- Openverseはライセンス情報を持つ検索APIですが、最終的な利用可否は出典URLとライセンス条件を確認してください。
- 人物や個人情報を示す語は除外していますが、完全な内容保証ではありません。デモ同梱前に代表画像を目視確認してください。

