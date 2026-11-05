[CmdletBinding()]
param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$src = Join-Path $PSScriptRoot "Plinth.Windows"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "bin\Plinth.Windows.exe"
}
$out = [IO.Path]::GetFullPath($OutputPath)
$outDir = Split-Path $out -Parent
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path $csc)) {
    throw ".NET Framework 4.8 C# compiler not found at $csc"
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$sources = @(
    (Join-Path $src "NativeCfApi.cs"),
    (Join-Path $src "DavClient.cs"),
    (Join-Path $src "SyncEngine.cs"),
    (Join-Path $src "Program.cs")
)

& $csc /nologo /target:exe "/out:$out" /reference:System.Xml.Linq.dll @sources
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Built $out"
