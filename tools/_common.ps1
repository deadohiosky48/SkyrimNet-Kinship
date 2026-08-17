<#
    Shared helpers for the build/deploy scripts.

    Dot-sourced rather than imported as a module: these are small standalone
    scripts a modder runs by hand, and a module would mean an install step for
    four functions.
#>

function Get-SkyrimRoot {
    <#
        .SYNOPSIS
        Finds the Skyrim Special Edition install.

        .DESCRIPTION
        Every script here used to default to the author's own drive, which
        worked on exactly one machine and failed silently everywhere else - a
        fine default while this lived in one folder, and a bug the moment the
        repository was public.

        Order: explicit override, then the registry key the game writes at
        install, then the usual Steam locations across all fixed drives.
        Returns $null when nothing is found, so callers can say so plainly
        rather than proceeding with a path that does not exist.
    #>
    [CmdletBinding()]
    param([string]$Override)

    if ($Override) { return $Override }
    if ($env:SKYRIM_FOLDER -and (Test-Path $env:SKYRIM_FOLDER)) { return $env:SKYRIM_FOLDER }

    # The registry key Bethesda's installer writes. Present for Steam and GOG
    # installs alike, and correct even when the library is on another drive.
    foreach ($key in @(
        'HKLM:\SOFTWARE\WOW6432Node\Bethesda Softworks\Skyrim Special Edition',
        'HKLM:\SOFTWARE\Bethesda Softworks\Skyrim Special Edition')) {
        try {
            $p = (Get-ItemProperty -Path $key -ErrorAction Stop).'Installed Path'
            if ($p -and (Test-Path $p)) { return $p.TrimEnd('\') }
        } catch { }
    }

    # Fall back to scanning fixed drives for a standard Steam library.
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null })) {
        $candidate = Join-Path $drive.Root 'SteamLibrary\steamapps\common\Skyrim Special Edition'
        if (Test-Path $candidate) { return $candidate }
        $candidate = Join-Path $drive.Root 'Program Files (x86)\Steam\steamapps\common\Skyrim Special Edition'
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

function Resolve-SkyrimRootOrThrow {
    param([string]$Override)
    $root = Get-SkyrimRoot -Override $Override
    if (-not $root) {
        throw @"
Could not find Skyrim Special Edition.

Pass it explicitly:
    -SkyrimRoot "D:\Games\Skyrim Special Edition"

or set it once for all these scripts:
    setx SKYRIM_FOLDER "D:\Games\Skyrim Special Edition"
"@
    }
    if (-not (Test-Path (Join-Path $root 'Data'))) {
        throw "No Data folder under '$root' - that does not look like a Skyrim install."
    }
    return $root
}
