param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\frontend\src\protocol\generated'),
    [switch]$Experimental
)

$ErrorActionPreference = 'Stop'

$resolvedOutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $resolvedOutDir | Out-Null

$arguments = @('app-server', 'generate-ts', '--out', $resolvedOutDir)
if ($Experimental) {
    $arguments += '--experimental'
}

& codex @arguments
if ($LASTEXITCODE -ne 0) {
    throw "codex app-server generate-ts failed with exit code $LASTEXITCODE"
}

Write-Output "Generated Codex app-server TypeScript bindings in $resolvedOutDir"

