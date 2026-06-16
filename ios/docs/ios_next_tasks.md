# iOS次タスク

## 優先度高

1. 実機または手動Simulator操作で写真権限フローを確認する
2. 限定アクセスで選択写真だけが表示されることを確認する
3. OCR結果を写真IDごとに永続化する
4. OCR結果を検索対象に含める
5. 写真詳細画面のメタデータ表示を増やす

## 優先度中

1. UIテストターゲットを追加する
2. 写真グリッドの空状態と読み込み状態を追加検証する
3. スクリーンショット判定の精度を上げる
4. 動画サムネイル表示と種別バッジを追加確認する
5. SettingsViewに安全方針とバージョン情報を整理する

## 優先度低

1. 写真枚数が多い場合のページングまたは段階読み込みを設計する
2. OCR処理のキャンセルを追加する
3. OCR対象の画像サイズ調整を行う
4. 端末内インデックス作成の設計を始める
5. 追加ファイル種別への拡張方針を決める

## 検証コマンド

```sh
cd ~/Desktop/all_dev/shimaibako
xcodebuild build \
  -project ios/ShimaiBako/ShimaiBako.xcodeproj \
  -scheme ShimaiBako \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/shimaibako-final-derived
```

## 注意点

- 写真は外部送信しない
- 写真の削除、移動、リネーム、上書き機能は作らない
- 外部APIモードは次段階以降に回す
- App Store提出、証明書、課金関連はこの段階では扱わない
- テスト用の起動引数はDebugビルドのみで使う
