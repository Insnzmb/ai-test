param(
    [Parameter(Mandatory=$true)]
    [string]$Root
)
$ErrorActionPreference = 'Stop'
$Root = [System.IO.Path]::GetFullPath($Root)
$DevDebug = Join-Path $Root '_devdebug'
$Manifest = Join-Path $DevDebug 'manifest.csv'
$ExcludePattern = '\\_devdebug\\|\\node_modules\\|\\.git\\|\\venv\\|\\.venv\\'
if(-not (Test-Path $DevDebug)){ throw "Missing _devdebug folder at $DevDebug" }
New-Item -ItemType Directory -Force -Path (Join-Path $DevDebug 'logs\sessions') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DevDebug 'state') | Out-Null
$records = [System.Collections.Generic.List[object]]::new()
if(Test-Path $Manifest){
    Import-Csv $Manifest | ForEach-Object { $records.Add($_) }
}
function Get-RelativePath([string]$fromDir,[string]$toPath){
    $fromUri = [Uri]((Resolve-Path $fromDir).Path.TrimEnd('\\') + '\\')
    $toUri   = [Uri]((Resolve-Path $toPath).Path)
    $rel = $fromUri.MakeRelativeUri($toUri).ToString()
    return [Uri]::UnescapeDataString($rel).Replace('/','\\')
}
$batchFiles = Get-ChildItem -Path $Root -Filter *.bat -Recurse | Where-Object {
    $_.FullName -notmatch $ExcludePattern -and
    $_.Name -notmatch '\.__orig__\.bat$' -and
    $_.Name -notin @('install_debug_dev.bat','uninstall_debug_dev.bat','open_debug_screen.bat','open_dev_screen.bat')
}
$wrappedCount = 0
foreach($file in $batchFiles){
    $orig = Join-Path $file.DirectoryName ($file.BaseName + '.__orig__.bat')
    if(Test-Path $orig){
        Write-Host "Skipping already wrapped: $($file.FullName)"
        continue
    }
    $relativeDevDebug = Get-RelativePath $file.DirectoryName $DevDebug
    Move-Item -LiteralPath $file.FullName -Destination $orig
    $wrapper = @"
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "DEVDEBUG_DIR=%~dp0$relativeDevDebug"
call "%DEVDEBUG_DIR%\bootstrap.bat" "%~f0"
set "ORIG_BAT=%~dp0$($file.BaseName).__orig__.bat"
>>"%DEBUG_SESSION_LOG%" echo ==================================================
>>"%DEBUG_SESSION_LOG%" echo START: %DATE% %TIME%
>>"%DEBUG_SESSION_LOG%" echo WRAPPER: %~f0
>>"%DEBUG_SESSION_LOG%" echo ORIG: %ORIG_BAT%
>>"%DEBUG_SESSION_LOG%" echo ARGS: %*
>>"%DEBUG_SESSION_LOG%" echo --------------------------------------------------
if not exist "%ORIG_BAT%" (
  >>"%DEBUG_SESSION_LOG%" echo ERROR: missing original batch file "%ORIG_BAT%"
  >>"%DEVDEBUG_DIR%\logs\errors.log" echo [%DATE% %TIME%] %~f0 missing original batch file "%ORIG_BAT%"
  endlocal & exit /b 9009
)
call "%ORIG_BAT%" %* >>"%DEBUG_SESSION_LOG%" 2>>&1
set "EXITCODE=%ERRORLEVEL%"
>>"%DEBUG_SESSION_LOG%" echo --------------------------------------------------
>>"%DEBUG_SESSION_LOG%" echo EXITCODE: %EXITCODE%
>>"%DEVDEBUG_DIR%\logs\all_output.log" echo [%DATE% %TIME%] %~f0 EXITCODE %EXITCODE%
if not "%EXITCODE%"=="0" (
  >>"%DEVDEBUG_DIR%\logs\errors.log" echo [%DATE% %TIME%] %~f0 EXITCODE %EXITCODE%
)
endlocal & exit /b %EXITCODE%
"@
    Set-Content -LiteralPath $file.FullName -Value $wrapper -Encoding ASCII
    $records.Add([pscustomobject]@{
        WrapperPath = $file.FullName
        OriginalPath = $orig
        RelativeDevDebug = $relativeDevDebug
        WrappedAt = (Get-Date).ToString('s')
    })
    $wrappedCount++
    Write-Host "Wrapped: $($file.FullName)"
}
$records | Sort-Object WrapperPath | Export-Csv -NoTypeInformation -Path $Manifest
Write-Host ''
Write-Host "Done. Wrapped $wrappedCount batch file(s)." -ForegroundColor Green
Write-Host 'Run any batch file normally. The debug/dev screens will auto-open.' -ForegroundColor Green
