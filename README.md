# しまい箱

しまい箱は、Windows 上に同期済みの iCloud 写真、OneDrive 写真、任意フォルダの写真をローカルで横断検索するためのMVPです。外部クラウドAPIへ直接接続せず、指定フォルダを読み取り専用でスキャンし、SQLite に検索インデックスとサムネイルを作成します。

## 目的

先輩のような iPhone / iCloud 写真ユーザーが、PCに同期された写真や動画をスマホブラウザから探しやすくすることを目的にしています。最初のMVPではクラウド上の写真を直接読まず、Windowsに同期済みのローカルフォルダを対象にします。

## ローカルファースト方針

- 写真本体やメタデータを外部送信しません。
- Microsoft Graph、Google API、Apple API、画像認識クラウドAPIには接続しません。
- 元写真、元動画、元ファイルを削除、移動、リネーム、上書きしません。
- スキャンは読み取り専用です。
- 検索インデックス、サムネイル、設定は `data/` 配下に保存します。

## 対応するデータソース

- iCloud for Windows の写真フォルダ候補
  - `%USERPROFILE%\Pictures\iCloud Photos\Photos`
  - `%USERPROFILE%\Pictures\iCloud Photos`
  - `%USERPROFILE%\iCloud Photos`
- OneDrive 同期フォルダ候補
  - `%USERPROFILE%\OneDrive`
  - `%USERPROFILE%\OneDrive\Pictures`
  - `%USERPROFILE%\OneDrive\画像`
  - `%USERPROFILE%\OneDrive\写真`
- 画面から追加する任意フォルダ
- 動作確認用のローカル生成サンプル写真
- OCR診断・分類検証用のローカル生成テスト画像100枚
- ライセンス情報付きの外部検証画像100枚

## セットアップ

PowerShell でこのフォルダを開き、次を実行します。

```powershell
.\Setup-DriveResearch.ps1
```

実行内容:

- Python 仮想環境作成
- backend 依存関係導入
- frontend 依存関係導入
- サンプル画像生成
- 初期DB作成

先輩に見せる時の短い説明は [docs/demo_readme_for_senior.md](docs/demo_readme_for_senior.md) を参照してください。

## 起動

PCだけで使う通常起動:

```cmd
Start-ShimaiBako.cmd
```

PowerShellで直接起動する場合:

```powershell
.\Start-DriveResearch.ps1
```

デフォルトは `LocalOnly` モードです。PC内だけで使う場合はこちらを使ってください。

- backend / frontend は `127.0.0.1` にだけバインドします。
- PC URL だけを表示します。
- スマホ用URLは表示しません。

スマホから使う場合だけ、明示的にLAN公開モードで起動します。

```cmd
Start-ShimaiBako-LAN.cmd
```

PowerShellで直接起動する場合:

```powershell
.\Start-DriveResearch.ps1 -LanAccess
```

`LanAccess` モードでは、同じWi-Fi/LAN内の端末からアクセスできる可能性があります。起動時にセッション用PINがランダム生成され、PowerShell画面にだけ表示されます。スマホで画面を開いたら、そのPINを入力してから使います。

起動モードの違い:

| モード | 使い方 | バインド | スマホURL | PIN |
| --- | --- | --- | --- | --- |
| `LocalOnly` | PCだけで使う通常起動 | `127.0.0.1` | 表示しない | 不要 |
| `LanAccess` | 家庭内Wi-Fiのスマホから使う時だけ | `0.0.0.0` | 表示する | 必須 |

公共Wi-Fi、会社Wi-Fi、ホテル、カフェ、共有オフィスでは `LanAccess` を使わないでください。外部公開、ルーターのポート開放、トンネル公開も推奨しません。

## 使い方

1. `ソース` 画面で iCloud / OneDrive 候補を確認します。
2. 候補が見つかった場合は `登録` を押します。
3. 任意フォルダを使う場合は、フォルダパスを入力して追加します。
4. `スキャン` 画面で `スキャン開始` を押します。
5. `検索` 画面でキーワード、データソース、日付、拡張子、画像/動画、スクショ、重複候補などで絞り込みます。
6. 写真カードを開くと、ファイル名、元パス、撮影日、更新日、サイズ、解像度、拡張子、データソースを確認できます。

## OCR検索

OCRはユーザーが `OCR` 画面で明示的に開始した場合だけ実行します。全写真を勝手にOCRすることはありません。

対応方針:

- `tesseract.exe` がWindows上にある場合は、ローカルTesseract OCRで画像内文字を抽出します。
- 外部OCR API、有料API、クラウドOCRには接続しません。
- `tesseract.exe` が見つからない環境では、実写真OCRはエラーとして記録し、処理全体は止めません。
- サンプル画像は、デモ用のローカルフォールバックでOCR検索を確認できます。
- `data/test_assets` のテスト画像100枚は、manifestの正解OCRテキストを使うデモ用フォールバックで検証できます。

OCR画面で選べる対象:

- 全件
- スクショのみ
- 画像のみ
- 未処理のみ
- エラー再処理
- データソース指定
- 最大件数指定
- OCR言語: `eng` / `jpn` / `jpn+eng`
- OCR済みも再処理する

検索画面のキーワードは、ファイル名、フォルダ名、データソース名、拡張子、OCRテキストに対して効きます。

統計画面とOCR画面には、`tesseract.exe` の検出状況、日本語データ `jpn`、英語データ `eng` の有無、実OCR件数、テスト用フォールバック件数を表示します。詳細画面ではOCR方式とOCR言語を確認できます。

実写真でOCRを使う場合は、Tesseract OCRをWindowsへ導入し、`tesseract.exe` にPATHを通してください。日本語を読む場合は日本語言語データ `jpn` も必要です。`data/test_assets` のmanifestフォールバックはテスト画像専用で、実写真OCR精度の代替ではありません。

現在の検証環境では、`winget` で `tesseract-ocr.tesseract` 5.5.0 を導入し、英語 `eng` と日本語 `jpn` を `data/tessdata/` に配置して確認しています。アプリは標準インストール先 `C:\Program Files\Tesseract-OCR\tesseract.exe` と `data/tessdata/` を検出します。PowerShellの `PATH` には自動登録されていないため、コマンドで直接確認する場合は次のように実行します。

```powershell
& "C:\Program Files\Tesseract-OCR\tesseract.exe" --version
& "C:\Program Files\Tesseract-OCR\tesseract.exe" --list-langs --tessdata-dir .\data\tessdata
```

## 実写真の小規模検証

実写真を試す場合は、元写真フォルダを直接対象にせず、必ずコピーした検証用フォルダを使ってください。

推奨手順:

1. `data/real_test_photos/` に確認したい写真だけをコピーします。
2. `ソース` 画面で `data\real_test_photos` を任意フォルダとして追加します。
3. `スキャン` 画面で最大件数を `100` から `300` 程度にします。
4. スキャン後、`OCR` 画面でも最大件数を `100` から `300` 程度にします。
5. Tesseract導入済みの場合は、OCR言語を `日本語+英語`、`日本語`、`英語` から選んで確認します。

このフォルダ内の画像も外部送信されません。アプリは読み取り専用で扱い、削除・移動・リネーム・上書きはしません。

## 自動分類

スキャン時とOCR完了時に、軽量なルールベース分類で `inferred_category` を保存します。

分類候補:

- 領収書
- 名刺
- ホワイトボード
- 看板
- 書類写真
- スクショ
- 工事黒板
- 旅行写真
- 家族写真
- その他

分類には、ファイル名、フォルダ名、OCRテキスト、画像サイズ、スクショらしさを使います。検索画面では推定カテゴリで絞り込めます。詳細画面と統計画面にも推定カテゴリを表示します。

## テスト画像データセット

OCR診断、自動分類、検索UI確認用に、外部素材を使わずPillowで生成した100枚のテスト画像を `data/test_assets/` に用意できます。

生成:

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\generate_test_dataset.py --force
```

構成:

- `data/test_assets/ocr_samples/`: OCR診断用40枚
- `data/test_assets/classification_samples/`: 分類検証用40枚
- `data/test_assets/edge_cases/`: 境界・誤判定確認用20枚
- `data/test_assets/manifest.json`
- `data/test_assets/manifest.csv`
- `data/test_assets/generation_report.md`
- `data/test_assets/validation_report.md`

詳細は [docs/test_dataset_guide.md](docs/test_dataset_guide.md) を参照してください。

## 外部検証画像データセット

自分のスマホ写真を使わずに、実写真風のスキャン、サムネイル、OCR、分類、検索を確認するため、利用条件が明確な外部画像だけを `data/external_test_assets/` に保存できます。

作成:

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\build_external_dataset.py --target 100 --force --skip-commons
```

構成:

- `data/external_test_assets/images/`
- `data/external_test_assets/manifest.json`
- `data/external_test_assets/manifest.csv`
- `data/external_test_assets/external_dataset_report.md`
- `data/external_test_assets/external_validation_result.json`

manifestには、出典URL、出典サイト、ライセンス名、作者/クレジット、デモ同梱可否を保存します。NC/ND付きなど利用条件が複雑になりやすい画像は `allowed_for_demo_bundle=false` にしています。

今回の検証では100枚を作成し、Tesseract `jpn+eng` でOCR済み100/100、OCRエラー0、分類一致100/100、外部画像データセット内の重複ハッシュグループ0を確認しました。手順は [docs/external_test_dataset_guide.md](docs/external_test_dataset_guide.md)、評価結果は [docs/external_image_evaluation_report.md](docs/external_image_evaluation_report.md) を参照してください。

外部画像はOpenverseでライセンス情報が明確な候補から取得しています。Google画像検索などから無作為に拾った画像は使いません。デモ配布へ同梱する場合は、必ず `manifest.json` の出典URLとライセンス条件を再確認してください。

標準デモZIPには外部検証画像を同梱せず、自作生成の `data/test_assets` を使います。配布候補の同梱/除外方針は [docs/demo_package_contents.md](docs/demo_package_contents.md) を参照してください。

## 大量写真向け安全設定

`スキャン` 画面で次を指定できます。

- スキャン最大件数
- 除外フォルダ
- 除外拡張子
- サムネイル再生成ON/OFF
- ハッシュ計算: SHA-256 / 軽量モード / OFF
- 事前見積もり
- DBバックアップ
- DBリセット
- ログ表示

DBリセットは検索インデックスだけを消します。元写真、元動画、元フォルダは変更しません。リセット前にはDBバックアップを作成します。

## できること

- iCloud写真同期フォルダ候補の検出
- OneDrive写真同期フォルダ候補の検出
- 任意フォルダの登録
- サンプル写真の登録
- 写真/動画ファイルのローカルDB登録
- サムネイル生成
- キーワード検索
- データソース別フィルタ
- 推定カテゴリ別フィルタ
- 日付範囲フィルタ
- 拡張子フィルタ
- スクショらしきファイルの抽出
- 重複候補の表示
- OCR診断・分類検証用テスト画像100枚の生成
- ライセンス情報付き外部検証画像100枚の作成と評価
- スキャン進捗表示
- スマホブラウザ向け表示

## できないこと・制限

- クラウド上だけにある写真を直接検索することはできません。
- iCloud / OneDrive のログイン連携は未実装です。
- 動画サムネイルはプレースホルダー表示です。
- HEIC / HEIF は `pillow-heif` が導入できた環境では読み取りを試みますが、環境により制限があります。
- 実写真OCRにはローカルTesseract OCRの導入が必要です。未導入の場合はエラーとして記録し、処理は継続します。
- 写真の削除、移動、整理操作は実装していません。
- 公開ネットワークや公共Wi-Fiでの利用は想定していません。

## 安全方針

- 登録削除はDB上の登録だけを消します。
- 元フォルダや元ファイルは変更しません。
- サムネイルは `data/thumbnails/` に新規生成されます。
- SQLite DB は `data/app.db` に保存されます。
- 外部クラウドAPIや有料APIは使用しません。
- `LocalOnly` が既定です。LANへ公開する場合だけ `-LanAccess` を指定します。
- `LanAccess` ではPIN入力前に検索、詳細、サムネイル、データソース、統計、OCR、ログへアクセスできません。
- `/api/health` は公開されますが、ファイルパスやスキャン詳細は返しません。

## よくあるトラブル

### スマホから開けない

- `Start-ShimaiBako-LAN.cmd` で起動しているか確認してください。通常起動ではスマホURLを表示しません。
- PCとスマホが同じWi-Fiにいるか確認してください。
- Windows Defender Firewall で `python.exe` または Node.js の通信がブロックされていないか確認してください。
- 起動スクリプトに表示された `http://192.168.x.x:5173` を使ってください。
- `5173` が使用中の場合、起動スクリプトは別の空きポートを表示します。表示された実際のURLを使ってください。
- 公共Wi-Fi、ホテル、カフェ、共有オフィスでは使わないでください。

### PINが分からない

`LanAccess` 起動時のPowerShell画面に、そのセッション用のPINが表示されます。固定PINはREADMEや設定ファイルには保存しません。分からなくなった場合は一度停止し、再起動して新しいPINを確認してください。

### PIN入力前にAPIへアクセスできない

正常な動作です。LAN公開時は、検索、詳細、サムネイル、データソース、統計、OCR、ログなどの主要APIをPIN認証で保護します。

### ポートが使用中と表示される

別の開発サーバーが `8000` または `5173` を使っています。該当プロセスを止めるか、起動スクリプトでポートを変更してください。

```powershell
.\Start-DriveResearch.ps1 -BackendPort 8010 -FrontendPort 5180
```

### HEIC が表示されない

環境により HEIC / HEIF の読み取りに失敗する場合があります。失敗したファイルはエラーとしてDBに残り、検索画面の `エラーあり` で確認できます。

### 動画サムネイルが表示されない

ローカルに `ffmpeg` がある場合だけ動画の代表フレーム生成を試します。`ffmpeg` が無い場合はプレースホルダー表示です。動画処理に失敗してもスキャン全体は止まりません。

## 今後の予定

詳細は [docs/next_tasks.md](docs/next_tasks.md) を参照してください。

