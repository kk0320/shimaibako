param(
    [switch]$ForceSamples
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

Write-Host "ShimaiBako setup" -ForegroundColor Cyan

New-Item -ItemType Directory -Force `
    "backend", "frontend", "data", "data\thumbnails", "data\samples", "docs", "logs" | Out-Null

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python was not found. Install Python 3.11 or later."
}
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    throw "npm was not found. Install Node.js."
}

if (-not (Test-Path ".venv\Scripts\python.exe")) {
    Write-Host "Creating Python virtual environment..."
    python -m venv ".venv"
}

$Python = Join-Path $Root ".venv\Scripts\python.exe"

Write-Host "Installing backend dependencies..."
& $Python -m pip install --upgrade pip
& $Python -m pip install -r "backend\requirements.txt"

Write-Host "Installing frontend dependencies..."
if (Test-Path "frontend\package-lock.json") {
    npm.cmd --prefix "frontend" ci
} else {
    npm.cmd --prefix "frontend" install
}

Write-Host "Generating sample images..."
if ($ForceSamples) {
    & $Python "backend\scripts\generate_samples.py" --force
} else {
    & $Python "backend\scripts\generate_samples.py"
}

Write-Host "Initializing database..."
& $Python "backend\scripts\init_db.py"

Write-Host ""
Write-Host "Setup completed." -ForegroundColor Green
Write-Host "Start: .\Start-ShimaiBako.cmd"
