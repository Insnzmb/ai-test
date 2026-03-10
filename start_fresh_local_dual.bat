@echo off
setlocal
set "ROOT=%~dp0"
set "TARGET=%ROOT%.."
set "BACKUP_DIR=%ROOT%save-backups"

if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%"

for %%F in ("%TARGET%\Pokemon - Gold Version*.sav") do (
	if exist "%%~fF" (
		echo Backing up and clearing: %%~nxF
		powershell -NoProfile -Command "$t=Get-Date -Format 'yyyyMMdd_HHmmss'; $d=('%BACKUP_DIR%\\%%~nF_' + $t + '.sav'); Copy-Item -LiteralPath '%%~fF' -Destination $d -Force"
		del /f /q "%%~fF"
	)
)

for %%F in ("%TARGET%\Pokemon - Silver Version*.sav") do (
	if exist "%%~fF" (
		echo Backing up and clearing: %%~nxF
		powershell -NoProfile -Command "$t=Get-Date -Format 'yyyyMMdd_HHmmss'; $d=('%BACKUP_DIR%\\%%~nF_' + $t + '.sav'); Copy-Item -LiteralPath '%%~fF' -Destination $d -Force"
		del /f /q "%%~fF"
	)
)

call "%ROOT%start_local_dual.bat"
