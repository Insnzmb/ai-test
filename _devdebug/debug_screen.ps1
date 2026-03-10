param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$Host.UI.RawUI.WindowTitle = 'Project Debug Screen'
$settingsFile = Join-Path $PSScriptRoot 'settings.env'
function Get-Setting([string]$name,[string]$default){
    if(Test-Path $settingsFile){
        $m = Select-String -Path $settingsFile -Pattern "set \"$name=(.*)\"" -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 1
        if($m){ return $m.Matches[0].Groups[1].Value }
    }
    return $default
}
function Tail([string]$path,[int]$count){
    if(Test-Path $path){ Get-Content -Path $path -Tail $count -ErrorAction SilentlyContinue }
}
$logRoot = Join-Path $PSScriptRoot 'logs'
$stateRoot = Join-Path $PSScriptRoot 'state'
while($true){
    $refresh = [int](Get-Setting 'DEBUG_REFRESH_SECONDS' '2')
    $tailLines = [int](Get-Setting 'MAX_TAIL_LINES' '120')
    $currentScript = ''
    $currentLog = ''
    if(Test-Path (Join-Path $stateRoot 'current_script.txt')){ $currentScript = (Get-Content (Join-Path $stateRoot 'current_script.txt') -Raw).Trim() }
    if(Test-Path (Join-Path $stateRoot 'current_log.txt')){ $currentLog = (Get-Content (Join-Path $stateRoot 'current_log.txt') -Raw).Trim() }
    Clear-Host
    Write-Host '=== DEBUG SCREEN ===' -ForegroundColor Cyan
    Write-Host ('Time:          ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ('Project Root:  ' + $Root)
    Write-Host ('Active Script: ' + ($(if($currentScript){$currentScript}else{'(none)'})))
    Write-Host ('Session Log:   ' + ($(if($currentLog){$currentLog}else{'(none)'})))
    Write-Host ''
    $errFile = Join-Path $logRoot 'errors.log'
    Write-Host 'Recent errors / warnings:' -ForegroundColor Yellow
    if(Test-Path $errFile){
        $recentErr = Get-Content $errFile -Tail 12 -ErrorAction SilentlyContinue
        if($recentErr){ $recentErr | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
        else { Write-Host '(no error lines yet)' -ForegroundColor DarkGray }
    } else {
        Write-Host '(no error log yet)' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ('Live tail (' + $tailLines + ' lines):') -ForegroundColor Green
    if($currentLog -and (Test-Path $currentLog)){
        Tail $currentLog $tailLines | ForEach-Object {
            if($_ -match 'error|failed|exception'){ Write-Host $_ -ForegroundColor Red }
            elseif($_ -match 'warning'){ Write-Host $_ -ForegroundColor Yellow }
            else { Write-Host $_ }
        }
    } else {
        $latest = Get-ChildItem (Join-Path $logRoot 'sessions') -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if($latest){ Tail $latest.FullName $tailLines }
        else { Write-Host '(no session log yet)' -ForegroundColor DarkGray }
    }
    Start-Sleep -Seconds $refresh
}
