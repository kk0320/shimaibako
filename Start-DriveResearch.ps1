param(
    [switch]$LocalOnly,
    [switch]$LanAccess,
    [int]$BackendPort = 8000,
    [int]$FrontendPort = 5173
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Test-PortInUse {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(250, $false)
        if ($connected) {
            $client.EndConnect($iar)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Find-FreePort {
    param([int]$StartPort)
    for ($port = $StartPort; $port -lt ($StartPort + 50); $port++) {
        if (-not (Test-PortInUse $port)) {
            return $port
        }
    }
    throw "No free port found from $StartPort to $($StartPort + 49)."
}

function Get-LanAddresses {
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*" -and
            $_.PrefixOrigin -ne "WellKnown"
        } |
        Select-Object -ExpandProperty IPAddress -Unique
}

if ($LocalOnly -and $LanAccess) {
    throw "Choose only one mode: -LocalOnly or -LanAccess."
}

$Mode = "local"
if ($LanAccess) {
    $Mode = "lan"
}

if (-not (Test-Path ".venv\Scripts\python.exe")) {
    throw "Virtual environment was not found. Run .\Setup-DriveResearch.ps1 first."
}
if (-not (Test-Path "frontend\node_modules")) {
    throw "Frontend dependencies were not found. Run .\Setup-DriveResearch.ps1 first."
}

$SelectedBackendPort = Find-FreePort $BackendPort
$SelectedFrontendPort = Find-FreePort $FrontendPort
$BindHost = if ($Mode -eq "lan") { "0.0.0.0" } else { "127.0.0.1" }
$AccessPin = ""
if ($Mode -eq "lan") {
    $AccessPin = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
}

if ($SelectedBackendPort -ne $BackendPort) {
    Write-Host "Backend port $BackendPort is in use. Using $SelectedBackendPort." -ForegroundColor Yellow
}
if ($SelectedFrontendPort -ne $FrontendPort) {
    Write-Host "Frontend port $FrontendPort is in use. Using $SelectedFrontendPort." -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force "logs" | Out-Null
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$BackendLog = Join-Path $Root "logs\backend_start.log"
$FrontendLog = Join-Path $Root "logs\frontend_start.log"

$BackendJob = Start-Job -Name "ShimaiBakoBackend" -ArgumentList $Root, $Python, $SelectedBackendPort, $BackendLog, $BindHost, $Mode, $AccessPin -ScriptBlock {
    param($Root, $Python, $BackendPort, $BackendLog, $BindHost, $Mode, $AccessPin)
    Set-Location $Root
    $env:DRIVE_RESEARCH_ACCESS_MODE = $Mode
    $env:DRIVE_RESEARCH_ACCESS_PIN = $AccessPin
    & $Python -m uvicorn backend.app.main:app --host $BindHost --port $BackendPort *> $BackendLog
}

$FrontendJob = Start-Job -Name "ShimaiBakoFrontend" -ArgumentList $Root, $SelectedFrontendPort, $FrontendLog, $SelectedBackendPort, $BindHost -ScriptBlock {
    param($Root, $FrontendPort, $FrontendLog, $BackendPort, $BindHost)
    Set-Location $Root
    $env:VITE_API_PORT = "$BackendPort"
    Remove-Item Env:\VITE_API_BASE -ErrorAction SilentlyContinue
    npm.cmd --prefix "frontend" run dev -- --host $BindHost --port $FrontendPort --strictPort *> $FrontendLog
}

Start-Sleep -Seconds 2

Write-Host ""
Write-Host "ShimaiBako started." -ForegroundColor Green
Write-Host "Mode: $Mode"
Write-Host ""
Write-Host "PC URL:"
Write-Host "  http://localhost:$SelectedFrontendPort"

if ($Mode -eq "lan") {
    Write-Host ""
    Write-Host "LAN ACCESS WARNING" -ForegroundColor Yellow
    Write-Host "This server is reachable from devices on the same Wi-Fi/LAN."
    Write-Host "Use only on a trusted home network. Do not use public or company Wi-Fi."
    Write-Host "PIN for this session:"
    Write-Host "  $AccessPin" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Phone URLs for same Wi-Fi:"
    $LanAddresses = @(Get-LanAddresses)
    if ($LanAddresses.Count -eq 0) {
        Write-Host "  No LAN IPv4 address was detected." -ForegroundColor Yellow
    } else {
        foreach ($Address in $LanAddresses) {
            Write-Host "  http://$Address`:$SelectedFrontendPort"
        }
    }
} else {
    Write-Host ""
    Write-Host "LocalOnly mode: frontend and backend are bound to 127.0.0.1."
    Write-Host "Phone URLs are not shown in this mode."
}

Write-Host ""
Write-Host "Backend health:"
Write-Host "  http://localhost:$SelectedBackendPort/api/health"
Write-Host ""
Write-Host "logs:"
Write-Host "  $BackendLog"
Write-Host "  $FrontendLog"
Write-Host ""
Write-Host "Press Enter to stop."
[void][Console]::ReadLine()

Stop-Job $BackendJob, $FrontendJob -ErrorAction SilentlyContinue
Remove-Job $BackendJob, $FrontendJob -Force -ErrorAction SilentlyContinue
Write-Host "Stopped."
