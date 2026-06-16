# しまい箱 デモZIP方針

## 標準方針

先輩に見せる標準デモZIPには、自作生成の `data/test_assets` 100枚を同梱します。外部画像データセット `data/external_test_assets` は検証用として扱い、標準デモZIPには同梱しません。

## 同梱するもの

- `backend/`
- `frontend/`
- `docs/`
- `README.md`
- `Setup-DriveResearch.ps1`
- `Start-DriveResearch.ps1`
- `Start-ShimaiBako.cmd`
- `Start-ShimaiBako-LAN.cmd`
- `Check-ShimaiBakoRelease.ps1`
- `data/samples/`
- `data/test_assets/`
- `data/tessdata/` が存在する場合
- `data/real_test_photos/README.txt`

## 同梱しないもの

- 実写真
- `data/external_test_assets/`
- `data/app.db`
- `data/app.db-wal`
- `data/app.db-shm`
- `data/thumbnails/`
- `data/backups/`
- `logs/`
- `.venv/`
- `frontend/node_modules/`
- `frontend/dist/`
- 個人パス情報を含む可能性があるログやDB

## ZIP作成

開発フォルダでは次を実行します。

```powershell
.\Build-ShimaiBakoDemoPackage.ps1
```

出力先:

- `release_candidate/shimaibako_demo/`
- `release_candidate/shimaibako-demo-local.zip`

## 配布前チェック

開発フォルダでは次を実行します。

```powershell
.\Check-ShimaiBakoRelease.ps1 -PackagePath release_candidate\shimaibako_demo
```

ZIPを別フォルダへ展開した後は、展開先のルートで次を実行します。

```powershell
.\Check-ShimaiBakoRelease.ps1
```

確認内容:

- 実写真が混ざっていない
- 外部検証画像が混ざっていない
- ログ、DB、バックアップ、サムネイルキャッシュが混ざっていない
- `data/real_test_photos` はREADMEのみ
- 禁止表現がない
- APIキーやトークンらしき文字列がない
- 8000 / 5173 / 5174 の起動中リスナーがない

## 外部画像を別途使う場合

標準デモZIPには入れません。別途使う必要がある場合は、`allowed_for_demo_bundle=true` の画像だけを抽出し、attributionファイルを作成します。

```powershell
.\.venv\Scripts\python.exe .\backend\scripts\export_allowed_external_assets.py --force
```

出力先:

- `release_candidate/external_allowed_assets/`

出力後も、出典URLとライセンス条件を確認してください。
