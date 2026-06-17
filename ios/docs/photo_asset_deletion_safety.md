# 写真本体削除に関する安全設計

## 結論

しまい箱は、iPhoneの写真アプリ内にある元写真・元動画を削除しない設計にする。写真・動画本体の削除、移動、リネーム、上書き、写真アプリ側のアルバム作成は行わない。

## 使用しないAPI

次のようなPhotosライブラリ変更APIは使用しない。

- `PHPhotoLibrary.shared().performChanges`
- `PHAssetChangeRequest.deleteAssets`
- `PHAssetCollectionChangeRequest` を使った削除
- `PHAssetCreationRequest`
- `UIImageWriteToSavedPhotosAlbum`

写真アクセスは、PhotoKitの読み取り、サムネイル取得、表示用画像取得、限定アクセス選択画面の表示に限定する。PHAssetは読み取り専用の参照IDとして扱う。

## 削除対象にしてよいもの

削除またはリセットしてよいものは、しまい箱のApplication Support内にあるアプリ内データに限定する。

- 分類傾向学習データ
- 精度向上モードの処理履歴
- 将来の画像特徴量データ枠
- 明示操作されたOCR結果キャッシュ
- 検索インデックス内のOCR欄や仮想分類欄

これらは検索や候補分類のための補助データであり、写真アプリ内の元写真・元動画ではない。

## 削除対象にしないもの

- 元写真・元動画
- 写真アプリ内のアセット
- iCloud写真
- 写真アプリ側のアルバムやフォルダ
- 手動分類結果
- 精度向上データ削除時のOCR結果

OCR結果キャッシュ削除は、ユーザーが明示したOCR結果削除操作に限定する。精度向上データ削除ではOCR結果を削除しない。

## 精度向上データ削除

精度向上データ削除で行うこと:

- 分類傾向学習データを空にする
- 将来の画像特徴量データ枠を削除する
- 精度向上モードの処理履歴を消す

精度向上データ削除で行わないこと:

- 元写真・元動画の削除
- OCR結果の削除
- 手動分類の削除
- 写真アプリ内アセットの変更

実装では、ファイル削除対象を `LocalDataDeletionTarget` に限定する。現在の削除対象は `future_image_feature_cache.json` のみで、PhotosライブラリのパスやPhotoKitアセットを受け取る口を持たない。

削除直前に、対象ファイルが `Application Support/ShimaiBako` 直下にあることを確認する。対象外のパスになった場合は削除を中止するため、写真アプリ内の元写真・元動画、PhotoKitアセット、OCR結果、手動分類結果を誤ってファイル削除対象にできない。

## アプリ削除時

しまい箱アプリをiPhoneから削除しても、写真アプリ本体の元写真・元動画は削除されない。アプリ削除で失われる可能性があるのは、しまい箱アプリ内の設定、履歴、キャッシュ、OCR結果、分類結果、学習補助データなどのローカルデータである。

分類/OCR/履歴を残したい場合は、アプリ削除前にエクスポート/バックアップが必要になる。詳細は `ios/docs/app_uninstall_data_policy.md` に記録する。

## 手動分類保護

精度向上モードでは、手動分類済み写真を自動再判定で上書きしない。対象に含まれた場合はスキップし、手動分類保護件数として記録する。

## 確認方法

次の検索でPhotosライブラリ変更APIがないことを確認する。

```sh
rg -n "performChanges|PHAssetChangeRequest|PHAssetCollectionChangeRequest|deleteAssets|PHAssetCreationRequest|UIImageWriteToSavedPhotosAlbum" ios/ShimaiBako ios/scripts ios/docs README.md
```

次のスクリプトで、精度向上モードの削除対象と安全条件を確認する。

```sh
swift ios/scripts/accuracy_improvement_safety_check.swift
```
