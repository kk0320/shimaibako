# 写真ライブラリ全体安全方針

## 結論

しまい箱は、iPhoneの写真アプリ本体にある元写真・元動画を削除、移動、リネーム、編集、上書きしない。PHAssetは読み取り専用の参照として扱い、写真アプリ側のアルバムやフォルダも作成しない。

アプリ内で削除またはリセットできるのは、しまい箱のローカルデータだけである。OCR結果、手動分類、学習補助データ、検索インデックスは写真本体ではないが、ユーザーの作業結果として扱い、対象を明示した操作だけで変更する。

## PhotoKit利用

| 項目 | 状況 | 安全判定 |
| --- | --- | --- |
| `PHPhotoLibrary.shared().performChanges` | 使用なし | PASS |
| `PHAssetChangeRequest.deleteAssets` | 使用なし | PASS |
| `PHAssetChangeRequest` | 使用なし | PASS |
| `PHAssetCollectionChangeRequest` | 使用なし | PASS |
| `PHAssetCreationRequest` | 使用なし | PASS |
| `UIImageWriteToSavedPhotosAlbum` | 使用なし | PASS |
| `UISaveVideoAtPathToSavedPhotosAlbum` | 使用なし | PASS |
| `PHPhotoLibrary.authorizationStatus` | 読み取り権限状態の確認のみ | PASS |
| `PHPhotoLibrary.requestAuthorization` | 写真読み取り許可の要求のみ | PASS |
| `presentLimitedLibraryPicker` | limited access の選択変更画面表示のみ | PASS |
| `PHAsset.fetchAssets` | アセット参照とメタデータ取得のみ | PASS |
| `PHCachingImageManager.requestImage` | サムネイル/表示/OCR用の読み取りのみ | PASS |

## 権限と設定

`Info.plist` は `NSPhotoLibraryUsageDescription` のみを持つ。`NSPhotoLibraryAddUsageDescription` は持たない。写真追加、写真編集、iCloud entitlement、App Groups、File Provider、Document Browser関連の権限は使わない。

写真権限文言は、端末内で検索・表示するための利用であり、元写真・元動画を削除・変更せず外部送信しないことを明記する。

## データ区分

| 区分 | 保存/参照内容 | 削除可否 | 方針 |
| --- | --- | --- | --- |
| 写真アプリ本体の元写真・元動画 | PHAssetの実体 | 削除不可 | しまい箱は削除・変更機能を持たない |
| PHAsset参照 | `localIdentifier`、日時、種別、サイズなど | アプリ内インデックスからは再構築可 | PhotoKit側のアセットは変更しない |
| しまい箱内の表示状態 | `active`、`unwanted`、`hidden`、`archived` | 明示操作時のみ変更可 | 不要候補や非表示はアプリ内の分類であり、写真アプリ側は変更しない |
| OCR結果 | `ocr_results.json` と `photo_index.json` のOCR欄 | 明示操作時のみ削除可 | 精度向上データ削除では削除しない |
| 手動分類 | `manualCategory`、`manualScreenshotSubcategory` | 明示的に自動判定へ戻す場合のみ解除可 | 自動分類より優先する |
| 検索インデックス | メタデータ、OCRテキスト参照、分類候補、メモ、タグ | 再構築可 | 元写真・OCR原文・手動分類を巻き込まない |
| 読み込みジョブ状態 | 進捗、件数、最終更新時刻、停止状態 | リセット可 | 元写真、OCR結果、手動分類、不要候補状態は残す |
| 学習補助データ | 手動分類傾向の軽量データ | 削除可 | 元写真・OCR結果・手動分類は残す |
| 精度向上履歴 | 実行日時、件数、中断理由 | 削除可 | 写真アプリ側には影響しない |
| 将来特徴量キャッシュ枠 | 端末内の再生成可能キャッシュ | 削除可 | 写真本体やサムネイル本体は保存しない |

## 削除/初期化/リセット処理の棚卸し

| ファイル | 関数/操作 | 行番号目安 | 操作内容 | 対象 | 元写真・元動画 | OCR結果 | 手動分類 | 判定 | 必要な修正 |
| --- | --- | ---: | --- | --- | --- | --- | --- | --- | --- |
| `PhotoLibraryService.swift` | `loadRecentAssets` | 130 | 写真参照を読み込み直す | メモリ上の一覧/サムネイル辞書 | 影響なし | 影響なし | 影響なし | PASS | なし |
| `PhotoLibraryService.swift` | `cancelLoading` | - | 読み込みジョブを中止 | 読み込み進捗状態 | 影響なし | 影響なし | 影響なし | PASS | 写真本体には触れない |
| `PhotoLibraryService.swift` | `resetLoadingState` | - | 読み込み状態をリセット | UserDefaults上の進捗状態 | 影響なし | 影響なし | 影響なし | PASS | インデックスやOCRは消さない |
| `PhotoLibraryService.swift` | `reloadLightMode` | - | 軽量モードで再読み込み | 読み込みモードと写真参照 | 影響なし | 影響なし | 影響なし | PASS | 復旧用 |
| `PhotoLibraryService.swift` | `updateReadMode` | 99 | 読み込み件数設定を変更 | UserDefaultsと読み込み一覧 | 影響なし | 影響なし | 影響なし | PASS | なし |
| `PhotoLibraryService.swift` | `updateICloudMode` | 105 | iCloud取得設定を変更 | UserDefaults | 影響なし | 影響なし | 影響なし | PASS | なし |
| `OCRService.swift` | `clearResult` | 139 | 1件のOCR結果を削除 | `ocr_results.json` | 影響なし | 影響あり、明示操作 | 影響なし | PASS | なし |
| `OCRService.swift` | `clearResults` | 149 | 複数OCR結果を削除 | `ocr_results.json` | 影響なし | 影響あり、明示操作 | 影響なし | PASS | なし |
| `OCRService.swift` | `clearAllResults` | 164 | OCR結果キャッシュを一括削除 | `ocr_results.json` | 影響なし | 影響あり、確認ダイアログあり | 影響なし | PASS | なし |
| `PhotoIndexStore.swift` | `clearOCRResult(s)` | 73 | インデックス内OCR欄を未処理へ戻す | `photo_index.json` | 影響なし | 影響あり、明示操作 | 影響なし | PASS | なし |
| `PhotoIndexStore.swift` | `clearAllOCRResults` | 91 | 全インデックスのOCR欄を未処理へ戻す | `photo_index.json` | 影響なし | 影響あり、確認ダイアログあり | 影響なし | PASS | なし |
| `PhotoIndexStore.swift` | `resetCategory(s)` | 97 | 仮想分類を未分類へ戻す | `photo_index.json` | 影響なし | 影響なし | 影響あり、分類リセット操作 | PASS | なし |
| `PhotoIndexStore.swift` | `resetAllCategories` | 115 | 全仮想分類を未分類へ戻す | `photo_index.json` | 影響なし | 影響なし | 影響あり、今後UI化時は確認必須 | WARNING | UI化時は強い確認を追加 |
| `PhotoIndexStore.swift` | 壊れたJSON退避 | - | 読み込み不能な `photo_index.json` を別名へ移動 | アプリ内インデックスファイル | 影響なし | 元ファイル内には残る | 元ファイル内には残る | PASS | 削除せず退避 |
| `PhotoIndexService.swift` | `rebuildSearchIndex` | 275 | 検索インデックス再構築 | `photo_index.json` | 影響なし | OCR結果を保持 | 手動分類を保持 | PASS | なし |
| `PhotoIndexService.swift` | `setDisplayState` | - | しまい箱内の表示状態を変更 | `photo_index.json` の表示状態欄 | 影響なし | 影響なし | 影響なし | PASS | 元写真・元動画には触れない |
| `PhotoIndexService.swift` | `setMemoAndTags` | - | 検索用メモ・タグを保存 | `photo_index.json` のメモ/タグ欄 | 影響なし | 影響なし | 影響なし | PASS | 写真アプリ側のメタデータではない |
| `PhotoIndexService.swift` | `rebuildAllCategories` | 416 | 仮想分類再構築 | `photo_index.json` | 影響なし | 影響なし | 手動分類を優先 | PASS | なし |
| `PhotoIndexService.swift` | `restoreAutomaticCategory` | 266 | 手動分類を解除して自動判定へ戻す | `photo_index.json`/学習例 | 影響なし | 影響なし | 影響あり、明示操作 | PASS | なし |
| `ManualCategoryLearningService.swift` | `removeExample` | 88 | 1件の学習例を削除 | `manual_category_learning.json` | 影響なし | 影響なし | 手動分類自体は残る | PASS | なし |
| `ManualCategoryLearningService.swift` | `clearAll` | 96 | 学習補助データを削除 | `manual_category_learning.json` | 影響なし | 影響なし | 手動分類自体は残る | PASS | なし |
| `ManualCategoryLearningService.swift` | `trimIfNeeded` | 205 | 上限超過時に古い学習例を整理 | `manual_category_learning.json` | 影響なし | 影響なし | 手動分類自体は残る | PASS | なし |
| `AccuracyImprovementService.swift` | `clearImprovementData` | 193 | 精度向上履歴と将来特徴量枠を削除 | UserDefaults/許可済みローカルファイル | 影響なし | 影響なし | 影響なし | PASS | なし |
| `AccuracyImprovementService.swift` | `removeLocalDataFile` | 408 | 許可済みローカルファイル削除 | `future_image_feature_cache.json` | 影響なし | 影響なし | 影響なし | WARNING | 許可済みパスガード済み |
| `PhotoDetailView.swift` | `clearOCRResult` | 146 | 詳細画面から1件OCR結果削除 | OCR結果/インデックスOCR欄 | 影響なし | 影響あり、確認あり | 影響なし | PASS | なし |
| `PhotoGridView.swift` | `clearVisibleOCRResults` | 695 | 表示中OCR結果削除 | OCR結果/インデックスOCR欄 | 影響なし | 影響あり、確認あり | 影響なし | PASS | なし |
| `SettingsView.swift` | OCR結果キャッシュ削除 | 93 | OCR結果キャッシュを一括削除 | OCR結果/インデックスOCR欄 | 影響なし | 影響あり、確認あり | 影響なし | PASS | 文言を対象限定済み |
| `SettingsView.swift` | 学習データ削除 | 103 | 分類傾向学習データを削除 | 学習補助データ | 影響なし | 影響なし | 手動分類自体は残る | PASS | なし |
| `SettingsView.swift` | 精度向上データ削除 | 113 | 学習補助データ、履歴、将来特徴量枠を削除 | アプリ内補助データ | 影響なし | 影響なし | 影響なし | PASS | なし |

## エクスポート/インポート/バックアップ

現時点で、しまい箱iOS版には分類/OCR/履歴のエクスポート、インポート、バックアップ、復元機能はない。将来追加する場合も、対象はしまい箱内のローカルデータに限定し、写真アプリ本体の元写真・元動画を削除、変更、上書きしない。

## アプリ起動/終了/バックグラウンド

アプリ起動時や設定画面表示時の処理は、権限状態確認、読み込み済み写真参照の更新、検索インデックス再構築、端末安全状態の取得に限定する。終了時やバックグラウンド復帰時に写真アプリ側のデータを削除・変更する処理はない。

## 不要候補/非表示の扱い

不要候補、非表示、整理済みは、しまい箱内の `photo_index.json` に保存する表示状態である。写真アプリ本体の元写真・元動画を削除、移動、編集、上書きする処理ではない。

通常一覧では `active` を中心に表示し、不要候補は専用フィルターで見返せる。検索時は「不要候補も検索に含める」を選んだ場合だけ、不要候補の写真も検索対象に含める。どの場合もPhotoKitの書き込みAPIは使わない。

## 文字検索の扱い

文字検索は端末内の検索インデックスに対して行う。検索対象はOCR結果、写真カテゴリ、スクショ細分類、手動分類、しまい箱内メモ、しまい箱内タグ、日時/種別などのメタデータである。検索語やOCR結果を外部送信しない。

## フル読み込みと復旧

フル/全件読み込みは100件単位で画面へ反映する。進捗状態はUserDefaultsに保存し、アプリ起動時に前回の進行中状態が残っていた場合は復旧可能な停止状態として扱う。

長時間読み込みジョブは `PhotoLibraryService` が保持し、写真タブ、検索タブ、設定タブのViewライフサイクルには直接依存しない。タブ移動やView再描画は元写真・元動画にもアプリ内インデックスにも削除操作を行わず、読み込みを継続する。

読み込み状態リセットが解除するのは、読み込みジョブ状態だけである。元写真・元動画、OCR結果、手動分類、不要候補/非表示/整理済み、メモ、タグ、学習データ、精度向上履歴は削除しない。

`photo_index.json` は一時ファイルに書き込んでから置き換える。読み込み時に壊れたJSONを検出した場合は削除せず、`.corrupt-日時-UUID` の名前で退避してから空インデックスで再構築できるようにする。

## 監査方法

次を実行して、全体安全監査を再確認する。

```sh
swift ios/scripts/photo_library_safety_check.swift
```

このスクリプトは、禁止PhotoKit書き込み/削除API、写真追加権限、entitlement、`removeItem` の境界、OCR/手動分類保護、削除UI文言を確認する。
