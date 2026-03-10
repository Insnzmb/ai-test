param(
    [Parameter(Mandatory=$true)]
    [string]$Root
)
$ErrorActionPreference = 'Stop'
$Root = [System.IO.Path]::GetFullPath($Root)
$DevDebug = Join-Path $Root '_devdebug'
$Manifest = Join-Path $DevDebug 'manifest.csv'
if(-not (Test-Path $Manifest)){
    Write-Host 'No manifest found. Nothing to restore.' -ForegroundColor Yellow
    exit 0
}
$rows = Import-Csv $Manifest
$restored = 0
foreach($row in $rows){
    if((Test-Path $row.WrapperPath) -and (Test-Path $row.OriginalPath)){
        Remove-Item -LiteralPath $row.WrapperPath -Force
        Move-Item -LiteralPath $row.OriginalPath -Destination $row.WrapperPath
        $restored++
        Write-Host "Restored: $($row.WrapperPath)"
    }
}
Remove-Item -LiteralPath $Manifest -Force
Write-Host ''
Write-Host "Done. Restored $restored batch file(s)." -ForegroundColor Green
