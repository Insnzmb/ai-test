@echo off
setlocal
set "ROOT=%~dp0"
if "%GS_TILE_WINDOWS%"=="" set "GS_TILE_WINDOWS=1"
call "%ROOT%start_gold_host.bat"
timeout /t 2 /nobreak >nul
call "%ROOT%start_silver_client.bat"
if /I not "%GS_TILE_WINDOWS%"=="0" (
	powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class W { [DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);}'; Add-Type -AssemblyName System.Windows.Forms; $scr=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $w=[int]($scr.Width/2); $h=$scr.Height; $x0=$scr.X; $x1=$scr.X+$w; $y0=$scr.Y; $SWP_NOZORDER=0x0004; $SWP_SHOWWINDOW=0x0040; for($i=0; $i -lt 16; $i++){ $g=Get-Process mGBA -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'Gold Version' } | Select-Object -First 1; $s=Get-Process mGBA -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'Silver Version' } | Select-Object -First 1; if($g){ [W]::SetWindowPos($g.MainWindowHandle,[IntPtr]::Zero,$x0,$y0,$w,$h,$SWP_NOZORDER -bor $SWP_SHOWWINDOW) | Out-Null }; if($s){ [W]::SetWindowPos($s.MainWindowHandle,[IntPtr]::Zero,$x1,$y0,$w,$h,$SWP_NOZORDER -bor $SWP_SHOWWINDOW) | Out-Null }; if($g -and $s){ break }; Start-Sleep -Milliseconds 350 }"
)
