@echo off
REM Launcher - ASCII only on purpose (cmd.exe renders text by codepage).
REM Runs PowerShell 7 (pwsh). The .ps1 is saved as UTF-8 WITH BOM, so it still
REM parses correctly on the off chance it gets run under Windows PowerShell 5.1.
chcp 65001 >nul

where pwsh >nul 2>&1
if errorlevel 1 (
    echo.
    echo PowerShell 7 ^(pwsh^) not found on PATH.
    echo Install it first:  winget install Microsoft.PowerShell
    echo.
    pause
    exit /b 1
)

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-Wallpaper.ps1" %*
echo.
pause
