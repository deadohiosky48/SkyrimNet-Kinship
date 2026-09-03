<#
.SYNOPSIS
    Snapshot and restore the live Kinship settings.

.DESCRIPTION
    settings.yaml is LIVE STATE that ships inside the mod archive. Installing a
    new version through a mod manager replaces the whole folder, settings
    included, so every update silently reverts the configuration to shipped
    defaults - stages off, scaling off, confiscation off.

    tools/deploy.ps1 already preserves live values across a direct deploy. It
    cannot help with a Vortex install, which replaces the staging folder
    wholesale and is Vortex doing exactly what installing a mod means.

    So: snapshot before installing, restore after.

        .\tools\settings.ps1 save
        # ... install the new version through Vortex ...
        .\tools\settings.ps1 restore

    The snapshot lives in tools/ and is not shipped. Only keys that still exist
    in the newly installed file are restored, so a value for a setting that has
    been removed is dropped rather than resurrected.

.PARAMETER Action
    save    - record the current live values
    restore - put the recorded values back
    show    - print live values next to the snapshot, changing nothing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('save', 'restore', 'show')]
    [string]$Action,

    [string]$SkyrimRoot
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not $SkyrimRoot) {
    $key = 'HKLM:\SOFTWARE\WOW6432Node\Bethesda Softworks\Skyrim Special Edition'
    $SkyrimRoot = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'installed path'
}
if (-not $SkyrimRoot -or -not (Test-Path $SkyrimRoot)) {
    throw "Could not find the Skyrim install. Pass -SkyrimRoot."
}

$live = Join-Path $SkyrimRoot 'Data\SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Kinship\settings.yaml'
$snap = Join-Path $PSScriptRoot '.settings-snapshot.txt'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Read-Values($path) {
    $map = [ordered]@{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*(kin[A-Za-z0-9_]+)\s*:\s*(.+?)\s*$') { $map[$Matches[1]] = $Matches[2] }
    }
    return $map
}

if (-not (Test-Path $live)) { throw "No live settings at: $live" }
$current = Read-Values $live

switch ($Action) {
    'save' {
        $out = foreach ($k in $current.Keys) { "$k=$($current[$k])" }
        [System.IO.File]::WriteAllLines($snap, $out, $utf8)
        Write-Host "Saved $($current.Count) setting(s) to tools\.settings-snapshot.txt"
        foreach ($k in $current.Keys) { Write-Host ("  {0,-24} {1}" -f $k, $current[$k]) }
    }

    'restore' {
        if (-not (Test-Path $snap)) { throw "No snapshot. Run '.\tools\settings.ps1 save' first." }
        $want = [ordered]@{}
        foreach ($line in [System.IO.File]::ReadAllLines($snap, [System.Text.Encoding]::UTF8)) {
            if ($line -match '^(kin[A-Za-z0-9_]+)=(.*)$') { $want[$Matches[1]] = $Matches[2] }
        }
        $changed = 0
        $out = foreach ($line in [System.IO.File]::ReadAllLines($live, [System.Text.Encoding]::UTF8)) {
            if ($line -match '^\s*(kin[A-Za-z0-9_]+)\s*:\s*(.+?)\s*$' -and $want.Contains($Matches[1])) {
                $key = $Matches[1]
                if ($Matches[2] -ne $want[$key]) {
                    Write-Host ("  {0,-24} {1}  ->  {2}" -f $key, $Matches[2], $want[$key]) -ForegroundColor Cyan
                    $changed++
                }
                "${key}: $($want[$key])"
            } else { $line }
        }
        [System.IO.File]::WriteAllLines($live, $out, $utf8)
        if ($changed -gt 0) {
            Write-Host "Restored $changed setting(s). A full game restart is NOT required - SkyrimNet reads this file live."
        } else {
            Write-Host "Nothing to restore; live settings already match the snapshot."
        }
    }

    'show' {
        $want = Read-Values $live
        $saved = @{}
        if (Test-Path $snap) {
            foreach ($line in [System.IO.File]::ReadAllLines($snap, [System.Text.Encoding]::UTF8)) {
                if ($line -match '^(kin[A-Za-z0-9_]+)=(.*)$') { $saved[$Matches[1]] = $Matches[2] }
            }
        }
        Write-Host ("{0,-24} {1,-12} {2}" -f 'KEY', 'LIVE', 'SNAPSHOT')
        foreach ($k in $current.Keys) {
            $s = if ($saved.ContainsKey($k)) { $saved[$k] } else { '-' }
            $mark = if ($s -ne '-' -and $s -ne $current[$k]) { '  <- differs' } else { '' }
            Write-Host ("{0,-24} {1,-12} {2}{3}" -f $k, $current[$k], $s, $mark)
        }
    }
}
