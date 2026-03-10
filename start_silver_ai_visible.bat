@echo off
setlocal
set "ROOT=%~dp0"
set "MGBA_DIR="
set "ROM="
set "HOST=%~1"
set "MODEL=%~2"
set "NAME_SLOT=%~3"

if "%HOST%"=="" set "HOST=127.0.0.1"
if "%MODEL%"=="" set "MODEL=llama3.2"
if "%NAME_SLOT%"=="" set "NAME_SLOT=0"

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

where python >nul 2>nul
if errorlevel 1 (
	echo Python was not found in PATH.
	exit /b 1
)
set "PYTHON_EXE="
for /f "delims=" %%P in ('where python') do (
	set "PYTHON_EXE=%%~fP"
	goto :py_found
)
:py_found
if not defined PYTHON_EXE (
	echo Could not resolve python executable.
	exit /b 1
)

rem Ensure only one Silver session/controller is active.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and ($_.CommandLine -match 'silver_ollama_agent.py|silver_session_wrapper.py') }; foreach($p in $items){ try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }"

set "GS_COOP_HOST=%HOST%"
if "%GS_COOP_PORT%"=="" set "GS_COOP_PORT=58777"
set "GS_FASTSTART=1"
set "GS_SILVER_AGENT=1"
set "GS_SILVER_AGENT_PORT=58888"
set "GS_BG_INPUT=0"
if "%GS_BG_INPUT_PORT%"=="" set "GS_BG_INPUT_PORT=58892"
set "GS_SILVER_LOCK_INPUT=1"
set "GS_SILVER_WINDOW=fg"

set "MGBA_EXE=%MGBA_DIR%\mGBA.exe"
set "LUA_SCRIPT=%ROOT%scripts\gs_coop_client.lua"
set "SESSION_WRAPPER=%ROOT%ai\silver_session_wrapper.py"
set "AGENT_SCRIPT=%ROOT%ai\silver_ollama_agent.py"
set "KNOWLEDGE_FILE=%ROOT%ai\silver_knowledge.txt"
set "WALKTHROUGH_FILE=%ROOT%ai\silver_walkthrough.txt"

if not exist "%MGBA_EXE%" (
	echo Missing "%MGBA_EXE%"
	exit /b 1
)
if not exist "%SESSION_WRAPPER%" (
	echo Missing "%SESSION_WRAPPER%"
	exit /b 1
)
if not exist "%AGENT_SCRIPT%" (
	echo Missing "%AGENT_SCRIPT%"
	exit /b 1
)
if not exist "%KNOWLEDGE_FILE%" (
	echo Missing "%KNOWLEDGE_FILE%"
	exit /b 1
)
if not exist "%WALKTHROUGH_FILE%" (
	echo Missing "%WALKTHROUGH_FILE%"
	exit /b 1
)

start "Silver AI Session" "%PYTHON_EXE%" "%SESSION_WRAPPER%" --python-exe "%PYTHON_EXE%" --agent-script "%AGENT_SCRIPT%" --knowledge "%KNOWLEDGE_FILE%" --walkthrough "%WALKTHROUGH_FILE%" --model %MODEL% --name-slot %NAME_SLOT% --agent-host 127.0.0.1 --agent-port 58888 --mgba "%MGBA_EXE%" --lua-script "%LUA_SCRIPT%" --rom "%ROM%"
