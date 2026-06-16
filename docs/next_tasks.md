# 次にやること

## ローカルMVP後の改善

- OCR検索
  - `data/real_test_photos` にコピーした実写真で小規模OCRを追加検証する。
  - `data/real_test_photos` にコピーした100〜300件程度の写真で、`eng` / `jpn` / `jpn+eng` の精度差を確認する。
  - 領収書、書類、ホワイトボード、工事看板などの検索精度を実写真で確認する。
  - Tesseract実OCRのテスト画像評価は完了済み。次は実写真でキーワードヒット率を記録する。
  - 外部検証画像100枚ではTesseract `jpn+eng` のOCRエラー0を確認済み。次は可視文字を人手で転記したOCR正解付き外部画像を一部追加する。
  - OCR対象のプレビュー選択を追加する。
  - 必要に応じて `PATH` へ `C:\Program Files\Tesseract-OCR` を追加する手順を起動スクリプトやREADMEに補強する。

- 自動分類
  - 実写真で `receipt`, `business_card`, `whiteboard`, `signboard`, `document_photo`, `screenshot`, `construction_board`, `travel_photo`, `family_photo`, `misc` の分類精度を測る。
  - 誤分類しやすい境界例を `data/test_assets/edge_cases` に追加する。
  - ルールベース分類の重みを検証レポートに基づいて調整する。
  - 外部検証画像ではファイル名/フォルダ名のカテゴリヒントで100/100一致したため、次はヒントの少ない実写真風ファイル名でも評価する。
  - 将来OCR結果が増えた時にカテゴリを一括再推定する管理機能を追加する。

- HEIC強化
  - `pillow-heif` の導入状態を画面に表示する。
  - HEIC / HEIF の失敗理由を分類する。
  - 大量HEICでの速度とメモリ使用量を確認する。

- 動画サムネイル
  - ローカルの ffmpeg がある場合の代表フレーム生成は実装済み。
  - ffmpeg未導入時の案内をUIでもう少し詳しくする。
  - 長尺動画や壊れた動画でのタイムアウト検証を追加する。

- iOSネイティブ版
  - SwiftUI + PhotoKit で写真ライブラリ検索を実装する。
  - 写真アクセス権限、限定アクセス、iCloud同期状態を丁寧に扱う。

- OneDrive Graph対応
  - Microsoftログインを任意設定で追加する。
  - 初期OFF、明示的ON、トークン安全保管を前提にする。

- バックアップ/エクスポート
  - DBのバックアップ作成。
  - 検索結果CSVエクスポート。
  - 設定エクスポート/インポート。

- インストーラー化
  - Windows向けの簡単起動パッケージを作る。
  - ポート競合、ファイアウォール案内、初回セットアップをわかりやすくする。

- LAN公開時の安全強化
  - PIN失敗回数制限と一時ロックを追加する。
  - セッショントークンの有効期限と手動再発行を追加する。
  - 起動中のアクセス元IPを画面に表示する。
  - LocalOnly / LanAccess の現在モードを設定画面にも表示する。
  - 家庭内LAN向けHTTPSまたはローカル証明書の扱いを調査する。
  - 外部公開、ポート開放、トンネル公開を検出または警告する仕組みを検討する。

- 大量写真運用
  - 1万件以上のスキャン時間を測定する。
  - サムネイル生成の並列化を検討する。
  - DB VACUUM / 最適化画面を追加する。
  - バックアップ一覧と復元機能を追加する。

- デモ配布
  - 正式な「しまい箱」アイコン画像が決まったら、`frontend/public/icons/` のデモ用アイコンを差し替える。
  - `release_candidate/shimaibako-demo-local.zip` を配布前に展開し、実写真、外部検証画像、DB、ログが入っていないことを再確認する。
  - 先輩デモでは、標準デモZIPに `data/external_test_assets` を同梱しない。
  - 外部検証画像を別途使う場合は、`allowed_for_demo_bundle=true` の抽出結果とattributionを確認する。

## 追加検証

- `data/external_test_assets` の `allowed_for_demo_bundle=true` 画像を目視確認し、デモ同梱可否を最終判断する。
- 外部検証画像の出典URLとライセンス条件を、配布前に再確認する。
- 実際の iCloud for Windows 同期フォルダでのスキャン。
- 実際の OneDrive 写真フォルダでのスキャン。
- 1万件以上の写真での速度測定。
- スマホ Safari での長時間操作。
- 家庭内LANでの接続手順確認。
- 実機iPhoneで、PIN入力前に検索・詳細・サムネイルが見えないことを確認する。
- 公共Wi-Fiや会社Wi-FiではLanAccessを使わない運用説明をデモ手順に入れる。
- テスト画像100枚を使ったカテゴリフィルタと詳細表示を、実機iPhone Safariでも確認する。

