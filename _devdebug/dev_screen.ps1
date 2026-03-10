param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$Host.UI.RawUI.WindowTitle = 'Project Dev Screen'
$settingsFile = Join-Path $PSScriptRoot 'settings.env'
$manifestFile = Join-Path $PSScriptRoot 'manifest.csv'
function Get-Setting([string]$name,[string]$default){
    if(Test-Path $settingsFile){
        $m = Select-String -Path $settingsFile -Pattern "set \"$name=(.*)\"" -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 1
        if($m){ return $m.Matches[0].Groups[1].Value }
    }
    return $default
}
while($true){
    $refresh = [int](Get-Setting 'DEV_REFRESH_SECONDS' '5')
    Clear-Host
    Write-Host '=== DEV SCREEN ===' -ForegroundColor Cyan
    Write-Host ('Time:           ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ('Machine:        ' + $env:COMPUTERNAME)
    Write-Host ('User:           ' + $env:USERNAME)
    Write-Host ('Project Root:   ' + $Root)
    Write-Host ('PowerShell:     ' + $PSVersionTable.PSVersion)
    Write-Host ('Auto Debug:     ' + (Get-Setting 'AUTO_OPEN_DEBUG' '1'))
    Write-Host ('Auto Dev:       ' + (Get-Setting 'AUTO_OPEN_DEV' '1'))
    Write-Host ('Debug Refresh:  ' + (Get-Setting 'DEBUG_REFRESH_SECONDS' '2') + 's')
    Write-Host ('Dev Refresh:    ' + (Get-Setting 'DEV_REFRESH_SECONDS' '5') + 's')
    Write-Host ''

    $batchFiles = Get-ChildItem -Path $Root -Filter *.bat -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\_devdebug\\|\\node_modules\\|\\.git\\|\\venv\\|\\.venv\\' }
    $wrapped = @()
    if(Test-Path $manifestFile){
        $wrapped = Import-Csv $manifestFile
    }
    Write-Host ('Visible batch files: ' + ($batchFiles | Measure-Object).Count) -ForegroundColor Green
    Write-Host ('Wrapped batch files: ' + ($wrapped | Measure-Object).Count) -ForegroundColor Green
    Write-Host ''
    Write-Host 'Latest wrapped files:' -ForegroundColor Green
    if($wrapped.Count -gt 0){
        $wrapped | Select-Object -Last 12 | ForEach-Object {
            $status = if(Test-Path $_.WrapperPath){ 'OK' } else { 'MISSING' }
            Write-Host (('{0,-8} {1}' -f $status, $_.WrapperPath)) -ForegroundColor ($(if($status -eq 'OK'){'Gray'}else{'Red'}))
        }
    } else {
        Write-Host '(manifest empty - run install_debug_dev.bat)' -ForegroundColor DarkGray
    }
    Write-Host ''
    $allLog = Join-Path $PSScriptRoot 'logs\all_output.log'
    Write-Host 'Recent activity:' -ForegroundColor Yellow
    if(Test-Path $allLog){
        Get-Content $allLog -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host '(no activity yet)' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host 'Tip: edit _devdebug\settings.env to change refresh or auto-open behavior.' -ForegroundColor DarkGray
    Start-Sleep -Seconds $refresh
}
