[CmdletBinding()]
param(
    [string]$Provider = ""
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$providersFile = Join-Path $repo "macos\Shared\providers.json"
$passwordFile = Join-Path $HOME ".cloud-drive-fp-data\alist-admin-pass.txt"

try {
    $ping = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:5244/ping" -TimeoutSec 2
    if ($ping.Content.Trim() -ne "pong") { throw "unexpected response" }
} catch {
    throw "CloudWeft AList is not running. Run windows\install.ps1 first."
}

if (-not (Test-Path $passwordFile)) { throw "AList admin credential file is missing. Run windows\install.ps1 first." }
$password = [IO.File]::ReadAllText($passwordFile).Trim()
Set-Clipboard -Value $password

Write-Host "AList admin username: admin"
Write-Host "AList admin password has been copied to the clipboard."

if (-not [string]::IsNullOrWhiteSpace($Provider)) {
    $catalog = Get-Content -Raw $providersFile | ConvertFrom-Json
    $entry = @($catalog.providers | Where-Object { $_.id -eq $Provider }) | Select-Object -First 1
    if (-not $entry) { throw "Unknown provider: $Provider" }
    Write-Host "Configure in AList:"
    Write-Host "  Driver:     $($entry.driver)"
    Write-Host "  Mount path: $($entry.mountPath)"
}

Start-Process "http://127.0.0.1:5244/@manage/storages"
