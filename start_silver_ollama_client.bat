@echo off
setlocal
set "ROOT=%~dp0"
set "HOST=%~1"
set "MODEL=%~2"
set "NAME_SLOT=%~3"

if "%HOST%"=="" set "HOST=127.0.0.1"
if "%MODEL%"=="" set "MODEL=llama3.2"
if "%NAME_SLOT%"=="" set "NAME_SLOT=0"

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

rem Ensure only one Silver agent process is active.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and ($_.CommandLine -match 'silver_ollama_agent.py|silver_session_wrapper.py') }; foreach($p in $items){ try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }"

set "GS_SILVER_AGENT=1"
set "GS_SILVER_AGENT_PORT=58888"
set "GS_BG_INPUT=0"
if "%GS_BG_INPUT_PORT%"=="" set "GS_BG_INPUT_PORT=58892"
set "GS_FASTSTART=1"
set "GS_SILVER_LOCK_INPUT=1"
set "AGENT_SCRIPT=%ROOT%ai\silver_ollama_agent.py"
set "KNOWLEDGE_FILE=%ROOT%ai\silver_knowledge.txt"
set "WALKTHROUGH_FILE=%ROOT%ai\silver_walkthrough.txt"

if not exist "%AGENT_SCRIPT%" (
	echo Missing "%AGENT_SCRIPT%"
	exit /b 1
)

start "Silver Ollama Agent" "%PYTHON_EXE%" "%AGENT_SCRIPT%" --host 127.0.0.1 --port %GS_SILVER_AGENT_PORT% --model %MODEL% --name-slot %NAME_SLOT% --knowledge "%KNOWLEDGE_FILE%" --walkthrough "%WALKTHROUGH_FILE%"
timeout /t 1 /nobreak >nul
call "%ROOT%start_silver_client.bat" "%HOST%"
