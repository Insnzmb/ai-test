@echo off
setlocal
set "ROOT=%~dp0"
set "MGBA_DIR="
set "ROM="
set "GS_COOP_PORT=%~1"

if "%GS_COOP_PORT%"=="" set "GS_COOP_PORT=58777"
if "%GS_BG_INPUT%"=="" set "GS_BG_INPUT=1"
if "%GS_BG_INPUT_PORT%"=="" set "GS_BG_INPUT_PORT=58891"

for /d %%D in ("%ROOT%..\mGBA-build-*-win32-*") do (
	set "MGBA_DIR=%%~fD"
	goto :mgba_found
)

:mgba_found
if not defined MGBA_DIR (
	echo Could not find mGBA build folder under "%ROOT%.."
	exit /b 1
)

for %%F in ("%ROOT%..\Pokemon - Gold Version*.gbc") do (
	set "ROM=%%~fF"
	goto :rom_found
)

:rom_found
if not defined ROM (
	echo Could not find Gold ROM under "%ROOT%.."
	exit /b 1
)

set "MGBA_EXE=%MGBA_DIR%\mGBA.exe"
set "SCRIPT=%ROOT%scripts\gs_coop_host.lua"

if not exist "%MGBA_EXE%" (
	echo Missing "%MGBA_EXE%"
	exit /b 1
)

start "" "%MGBA_EXE%" --script "%SCRIPT%" "%ROM%"
