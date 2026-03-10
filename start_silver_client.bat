@echo off
setlocal
set "ROOT=%~dp0"
set "MGBA_DIR="
set "ROM="
set "GS_COOP_HOST=%~1"
set "GS_COOP_PORT=%~2"

if "%GS_COOP_HOST%"=="" set "GS_COOP_HOST=127.0.0.1"
if "%GS_COOP_PORT%"=="" set "GS_COOP_PORT=58777"
if "%GS_BG_INPUT%"=="" set "GS_BG_INPUT=1"
if "%GS_BG_INPUT_PORT%"=="" set "GS_BG_INPUT_PORT=58892"
if "%GS_SILVER_WINDOW%"=="" set "GS_SILVER_WINDOW=fg"
if "%GS_FASTSTART%"=="" set "GS_FASTSTART=0"

for /d %%D in ("%ROOT%..\mGBA-build-*-win32-*") do (
	set "MGBA_DIR=%%~fD"
	goto :mgba_found
)

:mgba_found
if not defined MGBA_DIR (
	echo Could not find mGBA build folder under "%ROOT%.."
	exit /b 1
)

for %%F in ("%ROOT%..\Pokemon - Silver Version*.gbc") do (
	set "ROM=%%~fF"
	goto :rom_found
)

:rom_found
if not defined ROM (
	echo Could not find Silver ROM under "%ROOT%.."
	exit /b 1
)

set "MGBA_EXE=%MGBA_DIR%\mGBA.exe"
set "SCRIPT=%ROOT%scripts\gs_coop_client.lua"
set "WRAPPER=%ROOT%ai\silver_bg_wrapper.py"

if not exist "%MGBA_EXE%" (
	echo Missing "%MGBA_EXE%"
	exit /b 1
)

if /I "%GS_SILVER_WINDOW%"=="bg" (
	set "PYTHON_EXE="
	for /f "delims=" %%P in ('where python 2^>nul') do (
		if not defined PYTHON_EXE set "PYTHON_EXE=%%~fP"
	)
	if defined PYTHON_EXE if exist "%WRAPPER%" (
		start "Silver Background Wrapper" "%PYTHON_EXE%" "%WRAPPER%" --mgba "%MGBA_EXE%" --script "%SCRIPT%" --rom "%ROM%" --mode bg --hold-seconds 15
		goto :eof
	)
	start "Silver mGBA" /min "%MGBA_EXE%" --script "%SCRIPT%" "%ROM%"
) else if /I "%GS_SILVER_WINDOW%"=="min" (
	start "Silver mGBA" /min "%MGBA_EXE%" --script "%SCRIPT%" "%ROM%"
) else (
	start "Silver mGBA" "%MGBA_EXE%" --script "%SCRIPT%" "%ROM%"
)
