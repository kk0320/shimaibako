# ローカルMVP検証レポート

最終更新: 2026-06-16

## 実施した検証

| 項目 | 結果 | 内容 |
| --- | --- | --- |
| backend 起動 | PASS | LocalOnly: `127.0.0.1:8000` / LanAccess: `0.0.0.0:8000` |
| frontend build | PASS | `npm.cmd --prefix frontend run build` |
| npm audit | PASS | `npm.cmd --prefix frontend audit --audit-level=low` で 0 vulnerabilities |
| PowerShell構文 | PASS | `Setup-DriveResearch.ps1` / `Start-DriveResearch.ps1` parse OK |
| API health | PASS | `GET /api/health` が最小情報のみ返却 |
| DBマイグレーション | PASS | `ocr_text`, `ocr_status`, `ocr_error`, `ocr_engine`, `ocr_language`, `inferred_category` などを既存DBへ追加 |
| サンプルスキャン | PASS | 17件登録済み、サムネイル17件 |
| サムネイル表示 | PASS | `GET /api/items/{id}/thumbnail` とWeb UIで確認 |
| 検索 | PASS | `q=tokyo` でサンプル検索 |
| OCR開始 | PASS | `POST /api/ocr/start` |
| OCR進捗 | PASS | `GET /api/ocr/status` |
| OCRテキスト検索 | PASS | `q=Recipe` でOCRテキストから `screenshot_recipe_2025.png` を検索 |
| Tesseract導入 | PASS | `winget` で `tesseract-ocr.tesseract` 5.5.0 を導入 |
| Tesseract検出表示 | PASS | `/api/stats` で `tesseract_available: true`, `eng/jpn/osd` を確認 |
| OCR方式表示 | PASS | 統計/詳細/OCR画面で Tesseract 検出状況、実OCR、テスト用フォールバック、OCR言語を表示 |
| OCRエラー継続 | PASS | 初回実OCRで文字コード起因のエラーを確認し、修正後に再処理100件成功 |
| 最大件数制限 | PASS | dry-run 5件、実スキャン3件で停止 |
| データソース別検索 | PASS | `source_id` 指定で検索 |
| カテゴリ別検索 | PASS | `category=receipt` で領収書カテゴリ15件 |
| カテゴリ統計 | PASS | `GET /api/stats` で `by_category` を返却 |
| DBバックアップ | PASS | `data/backups/app-20260616T140046_0900.db` 作成 |
| ログ表示API | PASS | `GET /api/logs` |
| LocalOnly起動 | PASS | frontend/backend が `127.0.0.1` にバインド、スマホURLを案内しない |
| LocalOnly検索 | PASS | `auth_required: false`、認証なしで `q=tokyo` 検索成功 |
| LanAccess起動 | PASS | frontend/backend が `0.0.0.0` にバインド、LAN警告とPIN認証が有効 |
| LanAccess API保護 | PASS | PINなしの `/api/search`, `/api/settings`, `/api/stats`, `/api/items/1/thumbnail` は 401 |
| LanAccess PIN後検索 | PASS | PINログイン後、`q=tokyo` で `travel_tokyo_2024.jpg` を検索 |
| LanAccess再確認 | PASS | 一時PINでPINなし `/api/search` 401、PINなしサムネイル401、PIN後 `q=receipt` 検索200 |
| サムネイル認証 | PASS | PINなしは 401、セッショントークン付きURLは 200 |
| スマホ幅PIN画面 | PASS | 390px幅でPIN入力前は検索UIなし、PIN後に検索結果表示 |
| LAN URL確認 | PASS | LanAccess時のみ `http://192.168.0.53:<frontend port>` を表示する構成 |
| 元ファイル変更なし | PASS | スキャン/OCR/検索/DB操作は読み取り専用。検証用一時フォルダのみ作成後削除 |
| テスト画像生成 | PASS | `data/test_assets` に100枚、manifest JSON/CSV各100件 |
| テスト画像スキャン | PASS | 100件登録、サムネイル100件、エラー0 |
| テスト画像OCR | PASS | Tesseract実OCRで100件成功、エラー0 |
| 分類検証 | PASS | manifest照合で分類一致100/100、OCRキーワードヒット100/100、OCRキーワード一致数413/500 |
| 重複検証 | PASS | 重複期待2/2一致 |
| 外部検証画像生成 | PASS | `data/external_test_assets` に100枚、manifest JSON/CSV各100件 |
| 外部検証画像スキャン | PASS | 100件登録、サムネイル100件、エラー0 |
| 外部検証画像OCR | PASS | Tesseract `jpn+eng` で100件成功、OCRエラー0 |
| 外部検証画像分類 | PASS | manifest照合で分類一致100/100 |
| 外部検証画像検索 | PASS | `source_id=4`, `q=sign`, `category=signboard`, `ocr_status=done` のAPI検索を確認 |
| 外部検証画像重複 | PASS | 外部画像データセット内の重複ハッシュグループ0 |
| アプリ名統一 | PASS | UI、README、docsの表示名を「しまい箱」に統一 |
| アイコン反映 | PASS | favicon、PWA manifest、ヘッダーに `shimaibako-icon` を反映 |
| デモ用cmd起動 | PASS | `Start-ShimaiBako.cmd` はLocalOnly起動、スマホURL非表示を確認 |
| LAN版cmd警告 | PASS | `Start-ShimaiBako-LAN.cmd` は起動前にLAN公開、公共Wi-Fi、会社Wi-Fi、外部トンネル、PINの注意を表示 |
| 配布候補作成 | PASS | `release_candidate/shimaibako_demo` と `release_candidate/shimaibako-demo-local.zip` を作成 |
| 配布対象チェック | PASS | 外部画像、実写真、DB、ログ、サムネイル、node_modules、.venvを除外 |
| 390px初回表示 | PASS | しまい箱の説明、安全チップ、検索欄、条件チップ、下部ナビの大きな見切れなし |
| スマホ幅カテゴリUI | PASS | 390px幅でカテゴリフィルタ、詳細の推定カテゴリ表示を確認 |
| スマホ幅OCR方式UI | PASS | 390px幅で詳細のOCR方式/OCR言語、統計の実OCR/テスト用結果表示を確認 |
| スマホ幅Tesseract UI | PASS | 390px幅で統計のTesseract利用可、jpn/eng利用可、実OCR100件、詳細の実OCR(Tesseract)表示を確認 |
| 禁止表現チェック | PASS | README/docs/frontend/src/logs/data/real_test_photos に禁止表現なし |
| 起動中リスナー停止 | PASS | 検証後に `8000` / `5173` のリスナーなし |
| 起動中リスナー停止再確認 | PASS | 検証後に `8000` / `5173` / `5174` のリスナーなし |
| 実写真コピー確認 | PASS | `data/real_test_photos` はREADMEのみ、実写真メディア0件 |

## 起動確認

- LocalOnly backend: `http://127.0.0.1:8000/api/health`
- LocalOnly frontend: `http://127.0.0.1:5173`
- LocalOnly注記: スマホURLは表示しません。
- LanAccess UI検証: `http://127.0.0.1:5174`
- LanAccessスマホ候補例: `http://192.168.0.53:<frontend port>`
- LanAccess注記: PIN入力前は検索、詳細、サムネイル、データソース、統計、OCR、ログ、設定へアクセスできません。
- 起動スクリプトは `5173` が使用中の場合、別の空きポートを自動選択して表示します。

## LAN公開安全検証

実施内容:

- `GET /api/health`: 200、`access_mode: lan`, `auth_required: true`
- PINなし `GET /api/search?q=tokyo`: 401
- PINなし `GET /api/settings`: 401
- PINなし `GET /api/stats`: 401
- PINなし `GET /api/items/1/thumbnail`: 401
- PINログイン: セッショントークン発行
- トークン付き `GET /api/search?q=tokyo`: 200、1件
- トークン付き `GET /api/items/{id}`: 200
- トークン付きサムネイルURL: 200
- 390px幅UI: PINゲート表示、PIN入力後検索結果表示、コンソールエラーなし

## OCR検証

検証環境では `tesseract-ocr.tesseract` 5.5.0 を `winget` で導入しました。`/api/stats` では `tesseract_available: true`、`jpn_available: true`、`eng_available: true` を確認しました。

確認内容:

- 実行ファイル: `C:\Program Files\Tesseract-OCR\tesseract.exe`
- バージョン: `tesseract v5.5.0.20241111`
- PATH: 現在のPowerShell / User / Machine PATH には未登録
- アプリ検出: 標準インストール先から検出
- 言語データ: `data/tessdata`
- `--list-langs --tessdata-dir data\tessdata`: `eng`, `jpn`, `osd`

実施内容:

- サンプル画像のデモ用ローカルフォールバックで4件OCR済み
- test_assets 100件をTesseract実OCRで再処理
- `shimai` のOCRテキスト検索成功
- 初回実OCRでcp932デコード起因のエラーを確認し、Tesseract出力をUTF-8で読むよう修正
- 修正後、Tesseract実OCR100件成功、エラー0
- OCR画面で `eng` / `jpn` / `jpn+eng` の選択肢を表示
- 詳細画面でOCR方式とOCR言語を表示
- `docs/ocr_evaluation_report.md` を生成

OCR件数:

- OCR済み: 104（サンプル4 + テスト画像100）
- OCR未処理: 13
- OCRエラー: 0
- 実OCR: 100
- テスト用フォールバック: 0
- サンプル用フォールバック: 4

## テストデータセット検証

生成先:

- `data/test_assets/ocr_samples/`
- `data/test_assets/classification_samples/`
- `data/test_assets/edge_cases/`
- `data/test_assets/manifest.json`
- `data/test_assets/manifest.csv`
- `data/test_assets/generation_report.md`

内訳:

- OCR診断用: 40枚
- 自動認識振り分け用: 40枚
- 境界/誤判定確認用: 20枚

検証結果:

- manifest件数: 100
- 実画像数: 100
- DB登録件数: 100
- サムネイルあり: 100
- OCR済み: 100
- 分類一致: 100/100
- OCRキーワードヒット: 100/100
- OCRキーワード一致数: 413/500
- 比較用フォールバックOCRキーワード一致数: 448/500
- 重複期待一致: 2/2
- スクショ期待一致: 12/12

照合レポート:

- `data/test_assets/validation_report.md`
- `data/test_assets/validation_result.json`

## 外部検証画像データセット検証

生成先:

- `data/external_test_assets/images/`
- `data/external_test_assets/manifest.json`
- `data/external_test_assets/manifest.csv`
- `data/external_test_assets/external_dataset_report.md`
- `data/external_test_assets/external_validation_result.json`

内訳:

- 取得画像: 100枚
- manifest件数: 100
- CSV件数: 100
- 出典別: Openverse / flickr 96、Openverse / nasa 2、Openverse / rawpixel 1、Openverse / thingiverse 1
- デモ同梱可: 57
- デモ同梱しない候補: 43

検証結果:

- DB登録件数: 100
- サムネイルあり: 100
- OCR済み: 100
- OCRエラー: 0
- OCRテキストあり: 86/100
- OCR方式: `tesseract`
- OCR言語: `jpn+eng`
- 分類一致: 100/100
- 外部画像データセット内の重複ハッシュグループ: 0
- `q=sign` 検索: 21件
- `category=signboard` 検索: 20件
- `ocr_status=done` 検索: 100件

注意:

- `expected_keywords` は検索/分類用の期待語であり、外部画像内の可視文字を人手で転記したOCR正解ではありません。
- デモ同梱前に `manifest.json` の出典URL、ライセンス、作者/クレジットを再確認してください。
- NC/ND付きライセンスなど利用条件が複雑な画像は `allowed_for_demo_bundle=false` としました。

照合レポート:

- `docs/external_image_evaluation_report.md`
- `data/external_test_assets/external_validation_result.json`

## 大量写真向け検証

- dry-run: 最大5件で見積もり完了
- 実スキャン: 最大3件で停止
- 除外フォルダ指定: `node_modules`, `.venv`, `data/thumbnails`
- ハッシュ軽量モード: API受付確認
- DBバックアップ: 作成確認
- ログ表示: OCRエラー内容を取得確認

## 画面証跡

検証後に更新:

- `logs/desktop_home.png`
- `logs/desktop_ocr_search.png`
- `logs/desktop_detail.png`
- `logs/desktop_ocr.png`
- `logs/desktop_scan.png`
- `logs/mobile_home.png`
- `%TEMP%\drive_research_auth_check\pin_gate_mobile.png`
- `%TEMP%\drive_research_auth_check\search_after_pin_mobile.png`
- `%TEMP%\drive_research_dataset_check\category_filter_mobile_fixed.png`
- `%TEMP%\drive_research_dataset_check\category_filter_desktop.png`
- `logs/mobile_category_filter.png`
- `logs/mobile_detail_ocr_method.png`
- `logs/mobile_stats_ocr_method.png`
- `%TEMP%\drive_research_tesseract_stats_mobile.png`
- `%TEMP%\drive_research_tesseract_detail_mobile.png`

## デモ版整備

追加/更新:

- 表示名を「しまい箱」に統一
- `frontend/public/icons/shimaibako-icon.svg`
- `frontend/public/icons/shimaibako-icon-192.png`
- `frontend/public/icons/shimaibako-icon-512.png`
- `frontend/public/site.webmanifest`
- `Start-ShimaiBako.cmd`
- `Start-ShimaiBako-LAN.cmd`
- `Build-ShimaiBakoDemoPackage.ps1`
- `Check-ShimaiBakoRelease.ps1`
- `docs/demo_readme_for_senior.md`
- `docs/demo_package_contents.md`

配布候補:

- `release_candidate/shimaibako_demo`
- `release_candidate/shimaibako-demo-local.zip`
- SHA256はZIP作成後に `Get-FileHash` で確認します。レポート自身を同梱するため、固定値はここに残しません。

ZIP確認:

- 総エントリ数: 作成後に確認
- `data/test_assets`: 110エントリ
- `data/external_test_assets`: 0
- `data/app.db`: 0
- `logs`: 0
- `frontend/node_modules`: 0

## 既知制限

- test_assetsのTesseract実OCRは検証済みですが、実写真コピーでのOCRは未検証です。
- `data/real_test_photos` はREADMEのみで、実写真コピーはまだ配置されていません。
- Tesseract日本語OCRの実写真精度は追加確認が必要です。
- HEIC/HEIFは `pillow-heif` が有効ですが、実HEICファイルでは未検証です。
- 動画サムネイルは `ffmpeg` がある場合だけ代表フレーム生成を試します。未導入時はプレースホルダーです。
- DBリセット機能は実装済みですが、デモDB保持のため今回の検証では実行していません。
- 数万枚規模の長時間スキャンは未検証です。
- LanAccessのPIN認証はMVP向けのセッション保護です。HTTPS、失敗回数制限、ユーザー別権限は未実装です。
- 自動分類はルールベースです。テスト画像では100/100一致しましたが、実写真では追加検証とルール調整が必要です。
- テスト画像OCRはmanifestフォールバックを使えます。実写真OCR精度の代替ではありません。

## 残タスク

詳細は [next_tasks.md](next_tasks.md) を参照してください。

