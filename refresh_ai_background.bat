@echo off
setlocal
set "ROOT=%~dp0"
set "MODEL=%~1"
set "NAME_SLOT=%~2"
set "KB_TARGET=%~3"

if "%MODEL%"=="" set "MODEL=llama3.2"
if "%NAME_SLOT%"=="" set "NAME_SLOT=0"
if "%KB_TARGET%"=="" set "KB_TARGET=none"

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

powershell -NoProfile -ExecutionPolicy Bypass -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and ($_.CommandLine -match 'silver_ollama_agent.py|dual_bg_keyboard.py') -and ($_.CommandLine -notmatch 'silver_session_wrapper.py') }; foreach($p in $items){ try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }"

set "AGENT_SCRIPT=%ROOT%ai\silver_ollama_agent.py"
set "KNOWLEDGE_FILE=%ROOT%ai\silver_knowledge.txt"
set "WALKTHROUGH_FILE=%ROOT%ai\silver_walkthrough.txt"
set "KEYBOARD_SCRIPT=%ROOT%ai\dual_bg_keyboard.py"

start "Silver Ollama Agent" "%PYTHON_EXE%" "%AGENT_SCRIPT%" --host 127.0.0.1 --port 58888 --model %MODEL% --name-slot %NAME_SLOT% --knowledge "%KNOWLEDGE_FILE%" --walkthrough "%WALKTHROUGH_FILE%"
if /I "%KB_TARGET%"=="none" goto :done
start "GS Background Keyboard" "%PYTHON_EXE%" "%KEYBOARD_SCRIPT%" --host 127.0.0.1 --gold-port 58891 --silver-port 58892 --target %KB_TARGET%

:done
if /I "%KB_TARGET%"=="none" (
	echo Refreshed Silver AI controller without restarting mGBA.
) else (
	echo Refreshed Silver AI + keyboard controller without restarting mGBA.
)
