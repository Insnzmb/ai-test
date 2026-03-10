@echo off
setlocal
set "ROOT=%~dp0"
set "HOST=%~1"
set "MODEL=%~2"
set "NAME_SLOT=%~3"

if "%HOST%"=="" set "HOST=127.0.0.1"
if "%MODEL%"=="" set "MODEL=llama3.2"
if "%NAME_SLOT%"=="" set "NAME_SLOT=0"

if "%GS_SILVER_WINDOW%"=="" set "GS_SILVER_WINDOW=bg"
call "%ROOT%start_silver_ollama_client.bat" "%HOST%" "%MODEL%" "%NAME_SLOT%"
