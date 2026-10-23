@echo off
setlocal
cd /d "%~dp0"
if not exist "tools\powershell\pwsh.exe" (
  echo Portable PowerShell is missing. Run scripts\Setup-Tools.ps1 first.
  pause
  exit /b 1
)
"tools\powershell\pwsh.exe" -NoProfile -File "scripts\Setup-WSL.ps1" -Action Import
if errorlevel 1 goto failed
"tools\powershell\pwsh.exe" -NoProfile -File "scripts\Setup-WSL.ps1" -Action Probe
if errorlevel 1 goto failed
echo WSL Linux GPU qualification completed. Android graphics still needs separate integration.
pause
exit /b 0
:failed
echo Setup stopped. Read the diagnostic above and artifacts\wsl\setup-last-result.json.
pause
exit /b 1
