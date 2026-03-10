@echo off
setlocal
set "ROOT=%~dp0"
set "WRAPPER=%ROOT%ai\silver_bg_wrapper.py"

if not exist "%WRAPPER%" exit /b 0

set "PYTHON_EXE="
for /f "delims=" %%P in ('where python 2^>nul') do (
	if not defined PYTHON_EXE set "PYTHON_EXE=%%~fP"
)
if not defined PYTHON_EXE exit /b 0

"%PYTHON_EXE%" "%WRAPPER%" --mode park --title-contains "Pokemon - Silver" --hold-seconds 4 --timeout 2
