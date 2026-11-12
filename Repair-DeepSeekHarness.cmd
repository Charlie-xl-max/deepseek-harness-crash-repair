@echo off
setlocal
chcp 65001 >nul
set "REPAIR_SCRIPT=%~dp0Repair-DeepSeekHarness.ps1"

where pwsh.exe >nul 2>nul
if not errorlevel 1 (
    pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPAIR_SCRIPT%" %*
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPAIR_SCRIPT%" %*
)

set "REPAIR_CODE=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %REPAIR_CODE%
