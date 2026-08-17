<#
    Copies built artefacts into the live game Data folder.

    DEPLOY CADENCE - this drives the whole iteration loop:

      .prompt files        nothing, hot-reload (or "Reload prompts" in the UI)
      trigger/action YAML  reload from disk in the SkyrimNet UI, no restart
      .pex scripts         FULL GAME RESTART - a save reload reuses cached
                           scripts and will run the OLD code while showing you
                           the new file on disk

    DO NOT run this while Skyrim is running if -Scripts is included: the game
    holds .pex open and a half-written script is worse than a stale one. The
    guard below refuses rather than trusting you to remember.

    Usage:
        powershell -ExecutionPolicy Bypass -File "tools\deploy.ps1"
        powershell -ExecutionPolicy Bypass -File "tools\deploy.ps1" -PromptsOnly
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [switch]$PromptsOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$SkyrimRoot = Resolve-SkyrimRootOrThrow -Override $SkyrimRoot
$repo = Split-Path -Parent $PSScriptRoot
$data = Join-Path $SkyrimRoot 'Data'
if (-not (Test-Path $data)) { throw "Not found: $data" }

$running = Get-Process -Name 'SkyrimSE' -ErrorAction SilentlyContinue
if ($running -and -not $PromptsOnly) {
    throw "Skyrim is running. Close it before deploying scripts, or pass -PromptsOnly (prompts hot-reload safely)."
}

function Copy-Tree($from, $to, $label) {
    if (-not (Test-Path $from)) { Write-Host "  skip  $label (nothing at $from)"; return }
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
    Write-Host "  ok    $label"
}

Write-Host "Deploying to $data`n"

# Prompts, manifest and settings - all hot-reloadable.
Copy-Tree (Join-Path $repo 'SKSE') (Join-Path $data 'SKSE') 'SKSE tree (prompt, manifest, settings)'

if (-not $PromptsOnly) {
    Copy-Tree (Join-Path $repo 'Scripts') (Join-Path $data 'Scripts') 'compiled scripts'
    Write-Host "`n  NOTE: scripts changed - a FULL GAME RESTART is required." -ForegroundColor Yellow
    Write-Host "        Reloading a save reuses cached scripts and runs the old code." -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Green
