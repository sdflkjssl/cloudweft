$ErrorActionPreference = "Stop"

$repo = Split-Path $PSScriptRoot -Parent
$token = [Guid]::NewGuid().ToString("N")
$temp = [IO.Path]::GetTempPath()
$exe = Join-Path $temp "Plinth.Windows.Verify-$token.exe"

& (Join-Path $PSScriptRoot "build.ps1") -OutputPath $exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$backend = Join-Path $temp "plinth-cfapi-backend-$token"
$sync = Join-Path $temp "plinth-cfapi-sync-$token"
$outside = Join-Path $temp "plinth-cfapi-outside-$token"
$serverLog = Join-Path $temp "plinth-cfapi-server-$token.log"
$engineLog = Join-Path $temp "plinth-cfapi-engine-$token.log"
$engineRestartLog = Join-Path $temp "plinth-cfapi-engine-restart-$token.log"
$serverErr = Join-Path $temp "plinth-cfapi-server-$token.err.log"
$engineErr = Join-Path $temp "plinth-cfapi-engine-$token.err.log"
$port = 18082

function Wait-Until([scriptblock]$Condition, [string]$Failure, [int]$Seconds = 8) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $Failure
}

New-Item -ItemType Directory -Force -Path (Join-Path $backend "remote-dir"), $sync, $outside | Out-Null
[IO.File]::WriteAllText((Join-Path $backend "remote.txt"), "remote original`n")
[IO.File]::WriteAllText((Join-Path $backend "remote-dir\\nested.txt"), "remote nested`n")

$server = $null
$engine = $null
try {
    $serverScript = Join-Path $repo "macos\\server\\plinth-server.js"
    $server = Start-Process node -ArgumentList @($serverScript, "--root", $backend, "--port", "$port") -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr
    Start-Sleep -Milliseconds 700

    $engine = Start-Process $exe -ArgumentList @("--provider", "verify", "--base", "http://127.0.0.1:$port/dav/", "--root", $sync) -PassThru -WindowStyle Hidden -RedirectStandardOutput $engineLog -RedirectStandardError $engineErr
    Wait-Until { Test-Path $sync } "sync root was not created"
    Start-Sleep -Milliseconds 700

    Get-ChildItem $sync | Out-Null
    Wait-Until { Test-Path (Join-Path $sync "remote.txt") } "root placeholders were not populated"
    if ([IO.File]::ReadAllText((Join-Path $sync "remote.txt")) -ne "remote original`n") { throw "hydration content mismatch" }

    $local = Join-Path $sync "local.txt"
    [IO.File]::WriteAllText($local, "created locally`n")
    Wait-Until {
        (Test-Path (Join-Path $backend "local.txt")) -and
        ([IO.File]::ReadAllText((Join-Path $backend "local.txt")) -eq "created locally`n")
    } "new local file was not uploaded"

    $localDir = Join-Path $sync "localdir"
    New-Item -ItemType Directory -Path $localDir | Out-Null
    Wait-Until { Test-Path (Join-Path $backend "localdir") } "new local directory was not uploaded"

    $nested = Join-Path $localDir "local-nested.txt"
    [IO.File]::WriteAllText($nested, "nested local`n")
    Wait-Until {
        (Test-Path (Join-Path $backend "localdir\\local-nested.txt")) -and
        ([IO.File]::ReadAllText((Join-Path $backend "localdir\\local-nested.txt")) -eq "nested local`n")
    } "nested local file was not uploaded"

    [IO.File]::WriteAllText((Join-Path $sync "remote.txt"), "edited locally`n")
    Wait-Until { [IO.File]::ReadAllText((Join-Path $backend "remote.txt")) -eq "edited locally`n" } "local modification was not uploaded"

    Rename-Item $local "local-renamed.txt"
    Wait-Until { Test-Path (Join-Path $backend "local-renamed.txt") } "rename was not propagated"

    Remove-Item (Join-Path $sync "local-renamed.txt")
    Wait-Until { -not (Test-Path (Join-Path $backend "local-renamed.txt")) } "delete was not propagated"

    # Materialize a nested placeholder, restart the engine, then verify that
    # FileIdentity + NormalizedPath rebuild the in-memory id/path cache.
    $remoteDir = Join-Path $sync "remote-dir"
    Get-ChildItem $remoteDir | Out-Null
    Wait-Until { Test-Path (Join-Path $remoteDir "nested.txt") } "nested placeholder was not populated"

    Stop-Process -Id $engine.Id -Force
    Wait-Process -Id $engine.Id -ErrorAction SilentlyContinue
    $engine = Start-Process $exe -ArgumentList @("--provider", "verify", "--base", "http://127.0.0.1:$port/dav/", "--root", $sync) -PassThru -WindowStyle Hidden -RedirectStandardOutput $engineRestartLog -RedirectStandardError $engineErr
    Start-Sleep -Milliseconds 700

    $nestedRemote = Join-Path $remoteDir "nested.txt"
    if ([IO.File]::ReadAllText($nestedRemote) -ne "remote nested`n") { throw "restart hydration content mismatch" }
    [IO.File]::WriteAllText($nestedRemote, "restart edited`n")
    Wait-Until { [IO.File]::ReadAllText((Join-Path $backend "remote-dir\\nested.txt")) -eq "restart edited`n" } "restart modification was not uploaded"
    Rename-Item $nestedRemote "restart-renamed.txt"
    Wait-Until { Test-Path (Join-Path $backend "remote-dir\\restart-renamed.txt") } "restart rename was not propagated"

    # A move outside the sync root is a cloud delete while retaining the local
    # file at its new destination.
    $moveSource = Join-Path $sync "remote.txt"
    $moveTarget = Join-Path $outside "remote.txt"
    Move-Item $moveSource $moveTarget
    Wait-Until {
        (Test-Path $moveTarget) -and (-not (Test-Path (Join-Path $backend "remote.txt")))
    } "move out of sync root did not delete the remote item"

    Write-Host "PASS: populate, hydrate, create file, create directory, nested create, modify, rename, delete, restart recovery, move-out"
    Write-Host "Engine logs: $engineLog ; $engineRestartLog"
}
finally {
    if ($engine -and -not $engine.HasExited) { Stop-Process -Id $engine.Id -Force -ErrorAction SilentlyContinue }
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 200
    & $exe --provider verify --root $sync --unregister 2>$null | Out-Null
    Remove-Item $backend, $sync, $outside -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}
