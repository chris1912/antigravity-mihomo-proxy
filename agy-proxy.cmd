@echo off
setlocal
set "SCRIPT_PATH=%~dp0run-agy-with-proxy.ps1"
powershell.exe -NoLogo -NoProfile -NonInteractive -File "%SCRIPT_PATH%" %*
set "EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %EXIT_CODE%