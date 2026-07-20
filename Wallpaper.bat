@echo off
REM GUI launcher - ASCII only on purpose (cmd.exe renders text by codepage).
REM -STA is required: WinForms and OpenFileDialog need a single-threaded apartment.
REM -WindowStyle Hidden keeps the console from flashing behind the window.

where pwsh >nul 2>&1
if errorlevel 1 (
    chcp 65001 >nul
    echo.
    echo PowerShell 7 ^(pwsh^) not found on PATH.
    echo Install it first:  winget install Microsoft.PowerShell
    echo.
    pause
    exit /b 1
)

start "" pwsh -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Wallpaper-GUI.ps1"
