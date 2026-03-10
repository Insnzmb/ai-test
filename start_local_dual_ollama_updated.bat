@echo off
setlocal
set "ROOT=%~dp0"
set "MODEL=%~1"
set "NAME_SLOT=%~2"
set "KB_TARGET=%~3"
set "SILVER_MODE=%~4"
if "%MODEL%"=="" set "MODEL=llama3.2"
if "%NAME_SLOT%"=="" set "NAME_SLOT=0"
if "%SILVER_MODE%"=="" set "SILVER_MODE=visible"
if "%GS_BG_KEYBOARD%"=="" set "GS_BG_KEYBOARD=0"
if "%KB_TARGET%"=="" set "KB_TARGET=none"
if /I "%KB_TARGET%"=="none" set "GS_BG_KEYBOARD=0"
if "%GS_TILE_WINDOWS%"=="" set "GS_TILE_WINDOWS=1"
set "GS_FASTSTART=1"

rem Resolve project root and save locations.
set "GAME_ROOT=%ROOT%.."
if exist "%ROOT%Pokemon - Gold Version (USA, Europe) (SGB Enhanced) (GB Compatible).gbc" set "GAME_ROOT=%ROOT%"
set "SAVE_BACKUP_DIR=%ROOT%save-backups"
if not exist "%SAVE_BACKUP_DIR%" set "SAVE_BACKUP_DIR=%GAME_ROOT%\coop\save-backups"
set "GOLD_BASENAME=Pokemon - Gold Version (USA, Europe) (SGB Enhanced) (GB Compatible)"
set "SILVER_BASENAME=Pokemon - Silver Version (USA, Europe) (SGB Enhanced) (GB Compatible)"
set "GOLD_SAV=%GAME_ROOT%\%GOLD_BASENAME%.sav"
set "SILVER_SAV=%GAME_ROOT%\%SILVER_BASENAME%.sav"
set "SILVER_SA2=%GAME_ROOT%\%SILVER_BASENAME%.sa2"

call :ensure_saves

rem Prevent duplicate controllers from steering both windows.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$items = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and ($_.CommandLine -match 'silver_ollama_agent.py|dual_bg_keyboard.py|silver_session_wrapper.py') }; foreach($p in $items){ try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }"

call "%ROOT%start_gold_host.bat"
timeout /t 2 /nobreak >nul
if /I "%SILVER_MODE%"=="bg" (
	call "%ROOT%start_silver_ai_background.bat" "127.0.0.1" "%MODEL%" "%NAME_SLOT%"
) else (
	call "%ROOT%start_silver_ai_visible.bat" "127.0.0.1" "%MODEL%" "%NAME_SLOT%"
)
if /I not "%GS_TILE_WINDOWS%"=="0" (
	powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class W { [DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);}'; Add-Type -AssemblyName System.Windows.Forms; $scr=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $w=[int]($scr.Width/2); $h=$scr.Height; $x0=$scr.X; $x1=$scr.X+$w; $y0=$scr.Y; $SWP_NOZORDER=0x0004; $SWP_SHOWWINDOW=0x0040; for($i=0; $i -lt 16; $i++){ $g=Get-Process mGBA -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'Gold Version' } | Select-Object -First 1; $s=Get-Process mGBA -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'Silver Version' } | Select-Object -First 1; if($g){ [W]::SetWindowPos($g.MainWindowHandle,[IntPtr]::Zero,$x0,$y0,$w,$h,$SWP_NOZORDER -bor $SWP_SHOWWINDOW) | Out-Null }; if($s){ [W]::SetWindowPos($s.MainWindowHandle,[IntPtr]::Zero,$x1,$y0,$w,$h,$SWP_NOZORDER -bor $SWP_SHOWWINDOW) | Out-Null }; if($g -and $s){ break }; Start-Sleep -Milliseconds 350 }"
)

if /I "%GS_BG_KEYBOARD%"=="0" goto :done

where python >nul 2>nul
if errorlevel 1 goto :done
set "PYTHON_EXE="
for /f "delims=" %%P in ('where python') do (
	set "PYTHON_EXE=%%~fP"
	goto :py_found
)
:py_found
if not defined PYTHON_EXE goto :done

set "BG_SCRIPT=%ROOT%ai\dual_bg_keyboard.py"
if not exist "%BG_SCRIPT%" goto :done
start "GS Background Keyboard" "%PYTHON_EXE%" "%BG_SCRIPT%" --host 127.0.0.1 --gold-port 58891 --silver-port 58892 --target %KB_TARGET%

goto :eof

:done
exit /b 0

:ensure_saves
if not exist "%SAVE_BACKUP_DIR%" mkdir "%SAVE_BACKUP_DIR%" >nul 2>nul
call :backup_if_live "%GOLD_SAV%" "%SAVE_BACKUP_DIR%\%GOLD_BASENAME%_prelaunch.sav"
call :backup_if_live "%SILVER_SAV%" "%SAVE_BACKUP_DIR%\%SILVER_BASENAME%_prelaunch.sav"
call :restore_latest "%SAVE_BACKUP_DIR%\%GOLD_BASENAME%_*.sav" "%GOLD_SAV%"
call :restore_latest "%SAVE_BACKUP_DIR%\%SILVER_BASENAME%_*.sav" "%SILVER_SAV%"
if not exist "%SILVER_SAV%" if exist "%GAME_ROOT%\%SILVER_BASENAME%.sav.bak" copy /y "%GAME_ROOT%\%SILVER_BASENAME%.sav.bak" "%SILVER_SAV%" >nul
if exist "%SILVER_SAV%" copy /y "%SILVER_SAV%" "%SILVER_SA2%" >nul
exit /b 0

:backup_if_live
if exist "%~1" copy /y "%~1" "%~2" >nul
exit /b 0

:restore_latest
powershell -NoProfile -ExecutionPolicy Bypass -Command "$dest = '%~2'; $src = Get-ChildItem -Path '%~1' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($src) { if (!(Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $src.FullName -Destination $dest -Force } else { $destItem = Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue; if ($destItem -and $src.LastWriteTime -gt $destItem.LastWriteTime) { Copy-Item -LiteralPath $src.FullName -Destination $dest -Force } } }"
exit /b 0
