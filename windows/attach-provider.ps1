[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)] [string]$Provider,
    [string]$SyncRoot = "",
    [switch]$NoAutostart
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$catalog = Get-Content -Raw (Join-Path $repo "macos\Shared\providers.json") | ConvertFrom-Json
$entry = @($catalog.providers | Where-Object { $_.id -eq $Provider }) | Select-Object -First 1
if (-not $entry) { throw "Unknown provider: $Provider" }

$engineExe = Join-Path $PSScriptRoot "bin\Plinth.Windows.exe"
if (-not (Test-Path $engineExe)) {
    & (Join-Path $PSScriptRoot "build.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ([string]::IsNullOrWhiteSpace($SyncRoot)) {
    $SyncRoot = Join-Path $HOME "Plinth\$Provider"
}
$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("plinth:plinth"))
$status = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8081/control/providers/$Provider" -Headers @{ Authorization = "Basic $auth" } -TimeoutSec 15

if (-not $status.configured) {
    throw "AList has no storage at $($entry.mountPath). Configure it in AList first."
}
if (-not $status.healthy) {
    throw "AList storage $($entry.mountPath) is not healthy: $($status.status)"
}
$runtimeRoot = Join-Path $env:LOCALAPPDATA "Plinth"
$logRoot = Join-Path $runtimeRoot "logs"
$runner = Join-Path $runtimeRoot "run-$Provider.cmd"
$engineLog = Join-Path $logRoot "$Provider-engine.log"
New-Item -ItemType Directory -Force -Path $runtimeRoot, $logRoot, $SyncRoot | Out-Null

$q = [char]34
$line = $q + $engineExe + $q + " --provider " + $Provider + " --base http://127.0.0.1:8081/dav/" + $Provider + "/ --root " + $q + $SyncRoot + $q + " >> " + $q + $engineLog + $q + " 2>&1"
[IO.File]::WriteAllLines($runner, @("@echo off", $line), [Text.Encoding]::ASCII)

if (-not $NoAutostart) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name "Plinth $Provider" -Value ("cmd.exe /c " + $q + $runner + $q)
}
Get-CimInstance Win32_Process |
    Where-Object { $_.Name -ieq "Plinth.Windows.exe" -and $_.CommandLine -like "*--provider $Provider*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", ($q + $runner + $q)) -WindowStyle Hidden
Start-Sleep -Milliseconds 800

$running = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -ieq "Plinth.Windows.exe" -and $_.CommandLine -like "*--provider $Provider*" } |
    Select-Object -First 1

if (-not $running) {
    throw "$Provider CFAPI engine did not stay running. Check $engineLog"
}

Get-ChildItem -LiteralPath $SyncRoot -Force -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "$($entry.displayName) ready."
Write-Host "Open in Explorer: $SyncRoot"
Start-Process explorer.exe -ArgumentList ($q + $SyncRoot + $q)
