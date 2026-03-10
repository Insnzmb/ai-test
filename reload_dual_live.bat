@echo off
setlocal
set "ROOT=%~dp0"

call "%ROOT%reload_host_live.bat"
set "HOST_RC=%errorlevel%"
call "%ROOT%reload_silver_live.bat"
set "SILVER_RC=%errorlevel%"

if not "%HOST_RC%"=="0" exit /b %HOST_RC%
exit /b %SILVER_RC%

