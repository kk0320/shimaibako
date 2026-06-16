@echo off
setlocal
cd /d "%~dp0"

echo Starting ShimaiBako in LocalOnly mode.
echo PC-only mode does not show a phone URL.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DriveResearch.ps1" -LocalOnly

echo.
echo ShimaiBako has stopped.
pause
