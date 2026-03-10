@echo off
setlocal
set "ROOT=%~dp0"
set "MODEL=%~1"
set "NAME_SLOT=%~2"
set "KB_TARGET=%~3"

if "%MODEL%"=="" set "MODEL=llama3.2"
if "%NAME_SLOT%"=="" set "NAME_SLOT=0"
if "%KB_TARGET%"=="" set "KB_TARGET=none"

call "%ROOT%refresh_ai_background.bat" "%MODEL%" "%NAME_SLOT%" "%KB_TARGET%"
if errorlevel 1 (
	echo Hot update failed. Existing mGBA windows were left untouched.
	exit /b 1
)

if /I "%GS_SILVER_WINDOW%"=="bg" (
	call "%ROOT%repark_silver_background.bat" >nul 2>nul
)

echo Hot update complete. Gold/Silver mGBA windows stayed open.
