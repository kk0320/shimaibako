param(
    [string]$PackagePath = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $defaultCandidate = Join-Path $Root "release_candidate\shimaibako_demo"
    if (Test-Path $defaultCandidate) {
        $PackagePath = "release_candidate\shimaibako_demo"
    } else {
        $PackagePath = "."
    }
}
$Target = Join-Path $Root $PackagePath
$Failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $Failures.Add($Message) | Out-Null
}

function Test-PathInsideRoot {
    param([string]$Path)
    $resolvedRoot = (Resolve-Path $Root).Path
    $resolvedPath = (Resolve-Path $Path).Path
    return $resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

if (-not (Test-Path $Target)) {
    Add-Failure "Package path was not found: $Target"
} elseif (-not (Test-PathInsideRoot $Target)) {
    Add-Failure "Package path is outside the project: $Target"
}

if (Test-Path $Target) {
    $forbiddenDirs = @(
        "data\external_test_assets",
        "data\thumbnails",
        "data\backups",
        "logs",
        "frontend\node_modules",
        "frontend\dist",
        ".venv"
    )
    foreach ($dir in $forbiddenDirs) {
        if (Test-Path (Join-Path $Target $dir)) {
            Add-Failure "Forbidden directory is included: $dir"
        }
    }

    $forbiddenFiles = Get-ChildItem $Target -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^app\.db($|-shm|-wal)$' -or
            $_.Extension -in @(".db", ".sqlite", ".sqlite3", ".log")
        }
    foreach ($file in $forbiddenFiles) {
        Add-Failure "Forbidden file is included: $($file.FullName.Substring($Target.Length + 1))"
    }

    $realTest = Join-Path $Target "data\real_test_photos"
    if (Test-Path $realTest) {
        $media = Get-ChildItem $realTest -Recurse -File |
            Where-Object { $_.Name -notmatch '^README(\.txt|\.md)?$' }
        foreach ($file in $media) {
            Add-Failure "real_test_photos contains a non-README file: $($file.Name)"
        }
    }

    $forbiddenTerms = @(
        "Chat" + "G" + "PT",
        "Co" + "dex",
        "Open" + "AI",
        "G" + "PT",
        "Clau" + "de",
        "Gem" + "ini",
        "AI" + "作成",
        "プロ" + "ンプト"
    )
    $textExtensions = @(".md", ".txt", ".ps1", ".cmd", ".py", ".js", ".jsx", ".css", ".html", ".json", ".csv")
    $textFiles = Get-ChildItem $Target -Recurse -File |
        Where-Object { $textExtensions -contains $_.Extension.ToLowerInvariant() }
    foreach ($file in $textFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($term in $forbiddenTerms) {
            if ($content -like "*$term*") {
                Add-Failure "Forbidden term found in package: $($file.FullName.Substring($Target.Length + 1))"
                break
            }
        }
    }

    $secretPatterns = @(
        'sk-[A-Za-z0-9_-]{20,}',
        'ghp_[A-Za-z0-9_]{20,}',
        'xox[baprs]-[A-Za-z0-9-]{20,}',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        '(?i)(api[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*["''][^"'']{12,}["'']'
    )
    foreach ($file in $textFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($pattern in $secretPatterns) {
            if ($content -match $pattern) {
                Add-Failure "Potential secret found in package: $($file.FullName.Substring($Target.Length + 1))"
                break
            }
        }
    }

    $windowsUsersPrefix = [regex]::Escape("C:" + "\Users\")
    $posixUsersPrefix = [regex]::Escape("C:" + "/Users/")
    $personalPathPatterns = @(
        $windowsUsersPrefix + '[^\\\r\n`"'' ]+',
        $posixUsersPrefix + '[^/\r\n`"'' ]+'
    )
    foreach ($file in $textFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($pattern in $personalPathPatterns) {
            if ($content -match $pattern) {
                Add-Failure "Personal user path found in package: $($file.FullName.Substring($Target.Length + 1))"
                break
            }
        }
    }
}

$listeners = Get-NetTCPConnection -LocalPort 8000,5173,5174 -ErrorAction SilentlyContinue |
    Where-Object { $_.State -eq "Listen" }
foreach ($listener in $listeners) {
    Add-Failure "Listener is still running on port $($listener.LocalPort), pid $($listener.OwningProcess)"
}

if ($Failures.Count -gt 0) {
    Write-Host "Release precheck: FAIL" -ForegroundColor Red
    foreach ($failure in $Failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host "Release precheck: PASS" -ForegroundColor Green
