[CmdletBinding()]
param(
    [string]$AListVersion = "v3.64.0",
    [switch]$NoAutostart,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$runtimeRoot = Join-Path $env:LOCALAPPDATA "Plinth"
$alistRoot = Join-Path $runtimeRoot "alist"
$alistData = Join-Path $runtimeRoot "alist-data"
$logRoot = Join-Path $runtimeRoot "logs"
$bridgeData = Join-Path $HOME ".cloud-drive-fp-data"
$alistExe = Join-Path $alistRoot "alist.exe"
$bridgeScript = Join-Path $repo "macos\server\alist-bridge.js"
$engineExe = Join-Path $PSScriptRoot "bin\Plinth.Windows.exe"
$passwordFile = Join-Path $bridgeData "alist-admin-pass.txt"
$runAlist = Join-Path $runtimeRoot "run-alist.cmd"
$runBridge = Join-Path $runtimeRoot "run-bridge.cmd"

function Require-Command([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "$Name is required but was not found in PATH." }
    return $command.Source
}

function Wait-Http([string]$Url, [int]$Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) { return }
        } catch { }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Url"
}

function Wait-Port([int]$Port, [int]$Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(500) -and $client.Connected) {
                $client.EndConnect($async)
                $client.Close()
                return
            }
        } catch { } finally { $client.Close() }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for localhost:$Port"
}

Write-Host "[1/5] Build Windows CFAPI frontend"
$runningProviders = @()
$needsBuild = -not (Test-Path $engineExe)
if (-not $needsBuild) {
    $engineStamp = (Get-Item $engineExe).LastWriteTimeUtc
    $needsBuild = @(Get-ChildItem (Join-Path $PSScriptRoot "Plinth.Windows") -Filter *.cs | Where-Object { $_.LastWriteTimeUtc -gt $engineStamp }).Count -gt 0
}
if ($needsBuild) {
    Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq "Plinth.Windows.exe" } | ForEach-Object {
        if ($_.CommandLine -match "--provider\s+([^\s]+)") { $runningProviders += $Matches[1].Trim('"') }
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 300
    & (Join-Path $PSScriptRoot "build.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
    Write-Host "      existing engine is up to date"
}

Write-Host "[2/5] Provision private AList runtime"
New-Item -ItemType Directory -Force -Path $runtimeRoot, $alistRoot, $alistData, $logRoot, $bridgeData | Out-Null

if (-not (Test-Path $alistExe)) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    $asset = "alist-windows-$arch.zip"
    $url = "https://github.com/AlistGo/alist/releases/download/$AListVersion/$asset"
    $zip = Join-Path $env:TEMP "plinth-$asset"
    Write-Host "      downloading $AListVersion ($arch)"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $alistRoot -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $passwordFile) -or -not (Test-Path (Join-Path $alistData "data.db"))) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $raw = (& $alistExe admin random --data $alistData 2>&1 | Out-String)
    $alistExit = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($alistExit -ne 0) { throw "AList admin initialization failed with exit code $alistExit." }
    $clean = $raw -replace "\x1B\[[0-9;?]*[ -/]*[@-~]", ""
    $matches = [regex]::Matches($clean, "(?im)password:\s*(\S+)")
    if ($matches.Count -eq 0) { throw "AList initialized but its generated admin password could not be captured." }
    $generated = $matches[$matches.Count - 1].Groups[1].Value.Trim()
    [IO.File]::WriteAllText($passwordFile, $generated, [Text.Encoding]::ASCII)
}

$configPath = Join-Path $alistData "config.json"
if (-not (Test-Path $configPath)) { throw "AList config was not created: $configPath" }
$config = Get-Content -Raw $configPath | ConvertFrom-Json
$alistConfigChanged = $false
if ($config.scheme.address -ne "127.0.0.1") {
    $config.scheme.address = "127.0.0.1"
    $json = $config | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($configPath, $json, (New-Object Text.UTF8Encoding($false)))
    $alistConfigChanged = $true
}

$node = Require-Command "node.exe"

[IO.File]::WriteAllLines($runAlist, @(
    "@echo off",
    "`"$alistExe`" server --data `"$alistData`" >> `"$logRoot\alist.log`" 2>&1"
), [Text.Encoding]::ASCII)

[IO.File]::WriteAllLines($runBridge, @(
    "@echo off",
    "set `"FP_DATA_DIR=$bridgeData`"",
    "`"$node`" `"$bridgeScript`" >> `"$logRoot\bridge.log`" 2>&1"
), [Text.Encoding]::ASCII)

Write-Host "[3/5] Configure logon startup"
if (-not $NoAutostart) {
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name "Plinth AList" -Value "cmd.exe /c `"$runAlist`""
    Set-ItemProperty -Path $runKey -Name "Plinth Bridge" -Value "cmd.exe /c `"$runBridge`""

    Get-ChildItem -Path $runtimeRoot -Filter "run-*.cmd" -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -notin @("run-alist.cmd", "run-bridge.cmd")) {
            $provider = $_.BaseName.Substring(4)
            Set-ItemProperty -Path $runKey -Name ("Plinth " + $provider) -Value ("cmd.exe /c `"" + $_.FullName + "`"")
        }
    }
}

Write-Host "[4/5] Start runtime"
if (-not $NoStart) {
    if ($alistConfigChanged) {
        Get-NetTCPConnection -State Listen -LocalPort 5244 -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    }

    $alistReady = $false
    try {
        $ping = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5244/ping" -TimeoutSec 1
        $alistReady = $ping.Content.Trim() -eq "pong"
    } catch { }
    if (-not $alistReady) {
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$runAlist`"") -WindowStyle Hidden
        Wait-Http "http://127.0.0.1:5244/ping"
    }

    # Always restart the bridge so an installer rerun immediately picks up
    # repository updates instead of keeping an older Node process until logout.
    Get-NetTCPConnection -State Listen -LocalPort 8081 -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$runBridge`"") -WindowStyle Hidden
    Wait-Port 8081

    foreach ($provider in ($runningProviders | Select-Object -Unique)) {
        $runner = Join-Path $runtimeRoot ("run-" + $provider + ".cmd")
        if (Test-Path $runner) {
            Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", "`"$runner`"") -WindowStyle Hidden
        }
    }
}

Write-Host "[5/5] Installed"
Write-Host "      AList:  $alistExe"
Write-Host "      Bridge: http://127.0.0.1:8081"
Write-Host "      Engine: $engineExe"
Write-Host "      AList is managed by CloudWeft; users do not need to install it separately."
