param(
    [switch]$NoZip
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$ReleaseRoot = Join-Path $Root "release_candidate"
$PackageRoot = Join-Path $ReleaseRoot "shimaibako_demo"
$ZipPath = Join-Path $ReleaseRoot "shimaibako-demo-local.zip"

$resolvedRoot = (Resolve-Path $Root).Path
if (Test-Path $PackageRoot) {
    $resolvedPackage = (Resolve-Path $PackageRoot).Path
    if (-not $resolvedPackage.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Package root is outside the project: $PackageRoot"
    }
    Remove-Item -LiteralPath $PackageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force $PackageRoot | Out-Null

function Copy-FilteredDirectory {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @()
    )
    New-Item -ItemType Directory -Force $Destination | Out-Null
    $args = @($Source, $Destination, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    if ($ExcludeDirs.Count -gt 0) {
        $args += "/XD"
        $args += $ExcludeDirs
    }
    if ($ExcludeFiles.Count -gt 0) {
        $args += "/XF"
        $args += $ExcludeFiles
    }
    & robocopy @args | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed for $Source"
    }
}

Copy-FilteredDirectory "backend" (Join-Path $PackageRoot "backend") @("__pycache__") @("*.pyc", "*.pyo")
Copy-FilteredDirectory "frontend" (Join-Path $PackageRoot "frontend") @("node_modules", "dist") @()
Copy-FilteredDirectory "docs" (Join-Path $PackageRoot "docs") @() @()

New-Item -ItemType Directory -Force (Join-Path $PackageRoot "data") | Out-Null
Copy-FilteredDirectory "data\samples" (Join-Path $PackageRoot "data\samples") @() @()
Copy-FilteredDirectory "data\test_assets" (Join-Path $PackageRoot "data\test_assets") @() @()
if (Test-Path "data\tessdata") {
    Copy-FilteredDirectory "data\tessdata" (Join-Path $PackageRoot "data\tessdata") @() @()
}
New-Item -ItemType Directory -Force (Join-Path $PackageRoot "data\real_test_photos") | Out-Null
Copy-Item -LiteralPath "data\real_test_photos\README.txt" -Destination (Join-Path $PackageRoot "data\real_test_photos\README.txt") -Force
Copy-Item -LiteralPath "data\README.txt" -Destination (Join-Path $PackageRoot "data\README.txt") -Force

$rootFiles = @(
    "README.md",
    "Setup-DriveResearch.ps1",
    "Start-DriveResearch.ps1",
    "Start-ShimaiBako.cmd",
    "Start-ShimaiBako-LAN.cmd",
    "Check-ShimaiBakoRelease.ps1"
)
foreach ($file in $rootFiles) {
    Copy-Item -LiteralPath $file -Destination (Join-Path $PackageRoot $file) -Force
}

$contents = @'
# しまい箱 デモ配布メモ

## 同梱するもの

- アプリ本体: `backend/`, `frontend/`
- セットアップ/起動ファイル
- docs
- 自作生成サンプル: `data/samples`, `data/test_assets`
- OCR言語データ: `data/tessdata` が存在する場合のみ

## 同梱しないもの

- 実写真
- `data/external_test_assets`
- `data/app.db` とDB WAL/SHM
- `data/thumbnails`
- `data/backups`
- `logs`
- `.venv`
- `frontend/node_modules`
- `frontend/dist`

## 確認

展開先のルートでは次を実行してください。

```powershell
.\Check-ShimaiBakoRelease.ps1
```
'@
$contents | Set-Content -LiteralPath (Join-Path $PackageRoot "PACKAGE_CONTENTS.md") -Encoding UTF8

if (-not $NoZip) {
    if (Test-Path $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath $ZipPath -Force
    Write-Host "Created: $ZipPath" -ForegroundColor Green
}

Write-Host "Prepared: $PackageRoot" -ForegroundColor Green
