@echo off
setlocal
set "ROOT=%~dp0"
set "PORT=58902"
if not "%~1"=="" set "PORT=%~1"

where python >nul 2>nul
if errorlevel 1 (
	echo Python was not found in PATH.
	exit /b 1
)

python "%ROOT%ai\live_reload.py" --port %PORT% --cmd reload
exit /b %errorlevel%

