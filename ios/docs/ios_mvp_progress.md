# iOS MVP進捗

## 概要

しまい箱のiOS版MVPとして、SwiftUIの基本画面、PhotoKitによる写真ライブラリ読み取り、検索/フィルタ、端末内OCR、OCR結果の端末内保存、一括OCRの中断対応、大規模写真ライブラリ向けの読み込みモード、安全確認、検索インデックス保存を実装した。

現時点の方針は完全ローカル処理。写真は外部送信せず、削除・移動・編集・共有は行わない。

## 実装済み

- SwiftUIアプリの基本構成
- 日本語UI
- AppIcon設定
- 写真アクセス前の説明画面
- PhotoKit権限状態の扱い
  - 未確認
  - 許可
  - 限定アクセス
  - 拒否
  - 制限
- 許可または限定アクセス時の直近写真読み取り
- 読み込みモード
  - 軽量: 100件
  - 標準: 500件
  - 多め: 2,000件
  - 大量: 10,000件
  - フル: 全件
- 読み込みモードの永続化
- 大量/フルモード開始前の安全確認画面
- 端末状態チェック
  - バッテリー残量
  - 低電力モード
  - 発熱状態
  - 保存容量
- サムネイルの画面表示時取得
- 大量モード時のメタデータ中心読み込み
- サムネイルグリッド表示
- 写真詳細画面
- 日付順表示
- 検索欄
- 仮想フォルダによるカテゴリフィルタ
  - すべて
  - スクショ
  - 領収書候補
  - 書類写真候補
  - 名刺候補
  - 看板候補
  - ホワイトボード候補
  - 工事写真候補
  - 旅行写真候補
  - 動画
  - その他
- OCR前の軽量分類
- OCR後のテキストを使った再分類
- カテゴリ別件数表示
- 設定/ヘルプ画面
- Vision frameworkによる端末内OCR
- 詳細画面から1枚だけOCRを実行する導線
- OCR済み写真の再OCR導線
- 表示中、スクショのみ、書類写真候補のみ、未OCRのみを最大20件までまとめてOCRする導線
- まとめてOCR開始前の安全確認画面
- OCR状態表示
  - 未処理
  - 処理中
  - OCR済み
  - 読み取り失敗
- OCR結果のJSON保存
- OCR結果を含む検索
- OCR結果、分類結果、検索用メタデータを統合する検索インデックス
- `PhotoIndexStoring` protocolによる保存層の抽象化
- `JSONPhotoIndexStore` による `photo_index.json` version 2保存
- 既存 `ocr_results.json` との互換読み込み
- 設定画面でのインデックス件数、分類済み件数、OCR件数表示
- 検索インデックス再構築ボタン
- 30,000件相当のダミー検索インデックス性能確認スクリプト
- 設定画面での写真アクセス状態、読み込み上限、OCR件数、安全方針の表示
- 限定アクセス時の写真選択変更導線
- まとめてOCR中のキャンセル
- OCR対象画像の長辺1800px目安への縮小
- SettingsViewでのOCR言語、精度、一括OCR上限、キャッシュ説明の表示
- iCloud写真取得モード
  - オフライン優先
  - iCloud取得を許可
- iCloud取得時の通信量注意表示
- 実機向けビルド、インストール、起動確認

## 主なファイル

- `ios/ShimaiBako/Info.plist`
- `ios/ShimaiBako/ShimaiBako/ShimaiBakoApp.swift`
- `ios/ShimaiBako/ShimaiBako/ContentView.swift`
- `ios/ShimaiBako/ShimaiBako/Models/PhotoAsset.swift`
- `ios/ShimaiBako/ShimaiBako/Models/AppSettings.swift`
- `ios/ShimaiBako/ShimaiBako/Models/DeviceSafety.swift`
- `ios/ShimaiBako/ShimaiBako/Models/PhotoCategory.swift`
- `ios/ShimaiBako/ShimaiBako/Models/OCRConfiguration.swift`
- `ios/ShimaiBako/ShimaiBako/Models/OCRResult.swift`
- `ios/ShimaiBako/ShimaiBako/Services/PhotoLibraryService.swift`
- `ios/ShimaiBako/ShimaiBako/Services/PhotoIndexService.swift`
- `ios/ShimaiBako/ShimaiBako/Services/PhotoIndexStore.swift`
- `ios/ShimaiBako/ShimaiBako/Services/OCRService.swift`
- `ios/ShimaiBako/ShimaiBako/Services/OCRResultStore.swift`
- `ios/ShimaiBako/ShimaiBako/Views/HomeView.swift`
- `ios/ShimaiBako/ShimaiBako/Views/PermissionView.swift`
- `ios/ShimaiBako/ShimaiBako/Views/PhotoGridView.swift`
- `ios/ShimaiBako/ShimaiBako/Views/PhotoDetailView.swift`
- `ios/ShimaiBako/ShimaiBako/Views/SettingsView.swift`
- `ios/ShimaiBako/ShimaiBako/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `ios/scripts/index_store_performance_check.swift`
- `ios/docs/index_store_design.md`
- `ios/docs/large_library_performance_notes.md`

## ビルド方法

```sh
cd ~/Desktop/all_dev/shimaibako
xcodebuild build \
  -project ios/ShimaiBako/ShimaiBako.xcodeproj \
  -scheme ShimaiBako \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/shimaibako-final-validate
```

## Simulator確認

確認環境:

- Xcode 26.2
- Swift 6.2.3
- iPhone 17 Pro Simulator
- iOS 26.3 runtime

確認結果:

- アプリ起動: PASS
- 権限前の説明画面表示: PASS
- `NSPhotoLibraryUsageDescription` 設定: PASS
- AppIcon設定: PASS
- `xcodebuild build`: PASS
- warning/errorなし: PASS
- 写真権限拒否時の表示: PASS
- 写真グリッド表示: PASS
- 詳細画面表示: PASS
- Vision OCR処理: PASS
- OCR結果のJSON保存: PASS
- 検索インデックスJSON保存: PASS
- アプリ再起動後のOCR結果読み込み: PASS
- OCR結果検索: PASS
- カテゴリ別件数表示: PASS
- 30,000件相当ダミーインデックス検索: PASS
- まとめてOCR: PASS
- まとめてOCRキャンセル: PASS
- まとめてOCR前の安全確認表示: PASS
- 大量/フルモードの安全確認表示: PASS
- 読み込みモードUI表示: PASS
- iCloud取得モードUI表示: PASS
- カテゴリチップ表示: PASS
- 設定画面の安全方針表示順維持: PASS
- 実機向けビルド: PASS
- 実機インストール: PASS
- 実機起動: PASS

補足:

- Simulatorの写真権限自動付与では、iOS 26.3 runtimeで追加アクセス確認が残る場合があった。
- そのため、検証用SimulatorではTCCの写真アクセス状態を確認しながら検証した。
- 通常のアプリ操作では、アプリ内の説明画面からシステムの写真アクセス許可へ進む。
- 限定アクセスはコード上で扱っているが、今回の自動確認では実機操作に近い限定選択までは未確認。
- 限定アクセスの選択変更は `PHPhotoLibrary.shared().presentLimitedLibraryPicker` で標準画面へ誘導する。

## PhotoKit権限

設定済みキー:

- `NSPhotoLibraryUsageDescription`
- `PHPhotoLibraryPreventAutomaticLimitedAccessAlert`

権限ごとの挙動:

- 未確認: 説明画面と許可ボタンを表示
- 許可: 設定した読み込みモードの範囲で写真を読み取り専用表示
- 限定アクセス: 許可された範囲だけを表示し、設定画面で写真の選択変更導線を表示
- 拒否: 設定画面への導線を表示
- 制限: 端末や管理設定による制限として説明を表示

## OCR状況

- `VNRecognizeTextRequest` を利用
- 認識言語は日本語と英語
- 詳細画面の「この写真をOCR」ボタンで1枚だけ処理
- OCR済みまたは失敗した写真は詳細画面で状態、処理日時、結果を表示
- 写真グリッドではOCR状態バッジを表示
- 写真一覧/検索画面では、対象を選んで未処理写真を最大20件まで順番にOCR可能
- まとめてOCR中はキャンセル可能。完了済み結果は保存し、未処理分は未処理のまま残す
- 端末温度や保存容量に問題がある場合、まとめてOCRを開始しない、または中断する
- Vision OCRに渡す画像は長辺1800px目安に縮小する
- OCR結果は `Application Support/ShimaiBako/ocr_results.json` に保存
- 検索インデックスは `Application Support/ShimaiBako/photo_index.json` に保存
- 検索は撮影日、種別、サイズ、スクリーンショット判定、仮想フォルダ名、OCRテキストを対象にする
- OCRテキストを使って仮想フォルダ分類を再判定する
- 外部OCR APIは未使用

ローカルのテスト画像では次の文字列を認識できた。

```text
しまい箱OCR テスト
写真は外部送しません
読み取り専用で扱います
端末内で検索します
```

## 未実装

- ユーザータグ
- お気に入り管理
- ファイル名や追加メタデータの安定取得
- 実機画面での限定アクセス選択確認
- 実機写真での1枚OCR確認
- 実機写真でのまとめてOCR確認
- 実機での再起動後OCR結果復元確認
- バックグラウンド移行中のOCR中断確認
- 3万枚規模の実機ライブラリでの負荷検証
- SQLiteまたはSwiftDataへの検索インデックス移行
- SQLite FTSによるOCRテキスト検索
- 読み込み範囲のページング
- OCR結果キャッシュ削除UI
- UIテストターゲット
