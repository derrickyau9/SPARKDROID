@echo off
setlocal
cd /d "%~dp0"
if not exist "tools\powershell\pwsh.exe" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\Setup-Tools.ps1"
  if errorlevel 1 exit /b 1
)
if not exist "state\seed.iso" (
  "tools\powershell\pwsh.exe" -NoProfile -File "scripts\Prepare-Guest.ps1"
  if errorlevel 1 exit /b 1
)
start "" "artifacts\launcher\win-arm64\SparkDroid.exe" --project "%~dp0."
