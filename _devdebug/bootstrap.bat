@echo off
setlocal EnableExtensions
set "DEVDEBUG_DIR=%~dp0"
for %%I in ("%DEVDEBUG_DIR%..") do set "PROJECT_ROOT=%%~fI"
set "CALLER=%~f1"
if not exist "%DEVDEBUG_DIR%logs" md "%DEVDEBUG_DIR%logs" >nul 2>&1
if not exist "%DEVDEBUG_DIR%logs\sessions" md "%DEVDEBUG_DIR%logs\sessions" >nul 2>&1
if not exist "%DEVDEBUG_DIR%state" md "%DEVDEBUG_DIR%state" >nul 2>&1
if not exist "%DEVDEBUG_DIR%settings.env" (
  >"%DEVDEBUG_DIR%settings.env" echo @echo off
  >>"%DEVDEBUG_DIR%settings.env" echo set "AUTO_OPEN_DEBUG=1"
  >>"%DEVDEBUG_DIR%settings.env" echo set "AUTO_OPEN_DEV=1"
  >>"%DEVDEBUG_DIR%settings.env" echo set "DEBUG_REFRESH_SECONDS=2"
  >>"%DEVDEBUG_DIR%settings.env" echo set "DEV_REFRESH_SECONDS=5"
  >>"%DEVDEBUG_DIR%settings.env" echo set "MAX_TAIL_LINES=120"
)
call "%DEVDEBUG_DIR%settings.env"
for /f %%T in ('powershell -NoProfile -Command "(Get-Date).ToString('yyyyMMdd_HHmmss_fff')"') do set "RUNSTAMP=%%T"
set "SAFE_NAME=%~n1"
set "SAFE_NAME=%SAFE_NAME: =_%"
set "LOGFILE=%DEVDEBUG_DIR%logs\sessions\%RUNSTAMP%_%SAFE_NAME%.log"
>"%DEVDEBUG_DIR%state\current_script.txt" echo %CALLER%
>"%DEVDEBUG_DIR%state\current_log.txt" echo %LOGFILE%
>>"%DEVDEBUG_DIR%logs\all_output.log" echo [%DATE% %TIME%] BOOTSTRAP %CALLER%
if "%AUTO_OPEN_DEBUG%"=="1" (
  tasklist /v | findstr /i /c:"Project Debug Screen" >nul 2>&1
  if errorlevel 1 start "Project Debug Screen" powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DEVDEBUG_DIR%debug_screen.ps1" -Root "%PROJECT_ROOT%"
)
if "%AUTO_OPEN_DEV%"=="1" (
  tasklist /v | findstr /i /c:"Project Dev Screen" >nul 2>&1
  if errorlevel 1 start "Project Dev Screen" powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DEVDEBUG_DIR%dev_screen.ps1" -Root "%PROJECT_ROOT%"
)
endlocal & set "DEBUG_SESSION_LOG=%LOGFILE%" & set "PROJECT_ROOT=%PROJECT_ROOT%" & exit /b 0
