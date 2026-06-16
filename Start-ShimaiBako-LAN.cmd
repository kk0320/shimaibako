@echo off
setlocal
cd /d "%~dp0"

echo Starting ShimaiBako in LAN access mode.
echo.
echo WARNING:
echo - Devices on the same Wi-Fi/LAN may be able to reach this app.
echo - Use only on a trusted home Wi-Fi network.
echo - Do not use public Wi-Fi, company Wi-Fi, hotels, cafes, or shared offices.
echo - Do not open router ports or publish this app through external tunnels.
echo - A session PIN will be shown after startup and is required on the phone.
echo.
pause

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DriveResearch.ps1" -LanAccess

echo.
echo ShimaiBako has stopped.
pause
