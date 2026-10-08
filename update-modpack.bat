@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\update-modpack.ps1"
set "exitCode=%ERRORLEVEL%"

if not "%exitCode%"=="0" (
    echo.
    echo Modpack update failed. See the error above.
    pause
    exit /b %exitCode%
)

start "" explorer.exe "%~dp0download"
exit /b 0
