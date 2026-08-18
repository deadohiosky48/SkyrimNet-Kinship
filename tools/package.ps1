<#
    Builds a Vortex-installable archive.

    ARCHIVE ROOT = Data ROOT. Vortex deploys the contents of the archive into
    the game's Data folder, so the layout inside the zip must mirror Data
    exactly - Scripts\, SKSE\, and the .esp loose at the top.

    The .esp is NOT in the repo. It is built by hand in the Creation Kit (see
    docs\BUILD_PLUGIN.md) and lives in the game Data folder, so it is pulled
    from there. That is the one artefact this script cannot regenerate, and a
    missing one is a hard error rather than a quiet omission - an archive
    without it installs cleanly and does absolutely nothing.

    Usage:
        powershell -ExecutionPolicy Bypass -File "tools\package.ps1"
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [string]$Version,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$SkyrimRoot = Resolve-SkyrimRootOrThrow -Override $SkyrimRoot
$repo = Split-Path -Parent $PSScriptRoot
$data = Join-Path $SkyrimRoot 'Data'
if (-not $OutDir) { $OutDir = Join-Path $repo 'dist' }

# Version comes from the manifest so the archive can never disagree with what
# the plugin reports to SkyrimNet's dashboard.
$manifestPath = Join-Path $repo 'SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Kinship\manifest.yaml'
if (-not $Version) {
    $m = [regex]::Match((Get-Content $manifestPath -Raw), '(?m)^\s*version:\s*"([^"]+)"')
    if (-not $m.Success) { throw "Could not read version from $manifestPath" }
    $Version = $m.Groups[1].Value
}

$stage = Join-Path $env:TEMP ("snkin_pkg_" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    # --- 1. the plugin -----------------------------------------------------
    $esp = Join-Path $data 'SNKin_Integration.esp'
    if (-not (Test-Path $esp)) {
        throw "SNKin_Integration.esp not found in $data.`nBuild it in the Creation Kit first - see docs\BUILD_PLUGIN.md."
    }
    Copy-Item $esp $stage

    # Refuse to ship a plugin that is not ESL-flagged if it could have been.
    # Not fatal, but the user asked for it once and should not have to notice
    # silently that a rebuild lost it.
    $b = [System.IO.File]::ReadAllBytes($esp)
    $espFlags = [BitConverter]::ToUInt32($b, 8)
    $eslNote = if ($espFlags -band 0x200) { 'ESL-flagged' } else { 'NOT ESL-flagged' }

    # --- 2. compiled scripts ----------------------------------------------
    $pex = Get-ChildItem (Join-Path $repo 'Scripts') -Filter 'SNKin_*.pex' -File
    if ($pex.Count -lt 3) { throw "Expected 3 SNKin_*.pex, found $($pex.Count). Run tools\build.ps1." }
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'Scripts') | Out-Null
    $pex | Copy-Item -Destination (Join-Path $stage 'Scripts')

    # --- 3. prompt, manifest, settings -------------------------------------
    Copy-Item (Join-Path $repo 'SKSE') $stage -Recurse -Force

    # --- 3b. the optional SKSE panel, if it has been built -----------------
    # Shipped IN THE ARCHIVE rather than hand-copied into Vortex staging.
    # Deploying it straight to a staging folder created an orphan directory
    # Vortex had never registered, so the DLL sat there and never reached Data -
    # it looked deployed and did nothing.
    #
    # Absent is normal: the DLL is optional and most builds of this mod will not
    # have one. Never fail packaging over it.
    $dll = Join-Path $repo 'SKSE_Source\build\Release\SkyrimNetKinship.dll'
    if (Test-Path $dll) {
        Copy-Item $dll (Join-Path $stage 'SKSE\Plugins')
        $dllNote = "included ($([math]::Round((Get-Item $dll).Length / 1KB)) KB)"
    } else {
        $dllNote = 'not built - Papyrus-only package'
    }

    # --- 3c. refuse to ship the builder's directory layout quietly ----------
    # __FILE__ and std::source_location bake ABSOLUTE source paths into the DLL.
    # 1.0.0 and 1.1.0 both shipped eight, including the full path to the
    # checkout that produced them. /d1trimfile: in CMakeLists.txt strips the
    # prefix - but it is an UNDOCUMENTED flag, so if a future MSVC stops
    # honouring it the build will NOT fail. It will quietly start leaking again,
    # which is exactly how the first two releases went out. Hence a check at the
    # only moment that matters: when the binary is about to be shipped.
    if (Test-Path $dll) {
        $ascii = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dll))
        $leaked = [regex]::Matches($ascii, '[A-Za-z]:\\[ A-Za-z0-9_.\\-]{6,150}') |
                    ForEach-Object { $_.Value } | Sort-Object -Unique
        if ($leaked) {
            $pathNote = "$($leaked.Count) ABSOLUTE PATH(S) EMBEDDED - see warning above"
            Write-Host "`n  WARNING: the DLL carries build-machine paths:" -ForegroundColor Yellow
            $leaked | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            Write-Host "  Verify /d1trimfile: is still applied in SKSE_Source\CMakeLists.txt." -ForegroundColor Yellow
        } else {
            $pathNote = 'clean'
        }
    } else {
        $pathNote = 'n/a'
    }

    # --- 4. source, for anyone who wants to patch this ---------------------
    # ONLY OURS. src\scripts also holds SkyrimNetApi.psc and _JSW_BB_Storage.psc,
    # which are SkyrimNet's and Fertility Mode's files respectively - shipping
    # either would overwrite the owning mod's copy through a Vortex conflict.
    #
    # Deliberately Source\Scripts (the AE layout) and NOT Scripts\Source (the
    # legacy one). Both are on the Papyrus compiler's import path, but
    # Scripts\Source is the folder that shadows a build when a stale copy of
    # our own script sits in it - the trap called out in build.ps1 and warned
    # about in BUILD_PLUGIN.md Step 0.
    $srcOut = Join-Path $stage 'Source\Scripts'
    New-Item -ItemType Directory -Force -Path $srcOut | Out-Null
    Get-ChildItem (Join-Path $repo 'src\scripts') -Filter 'SNKin_*.psc' -File |
        Copy-Item -Destination $srcOut

    # --- 5. documentation --------------------------------------------------
    # Under Docs\ rather than loose at the root, so it lands in
    # Data\Docs\SkyrimNet Kinship\ instead of scattering files into Data itself.
    #
    # README ONLY. The build docs stay in the repo and out of the archive: this
    # package already contains a built ESP and a built DLL, so a Creation Kit
    # walkthrough landing in a player's Data folder is instructions for work
    # they must never do. Anyone who actually wants to build has the repo.
    $docOut = Join-Path $stage 'Docs\SkyrimNet Kinship'
    New-Item -ItemType Directory -Force -Path $docOut | Out-Null
    Copy-Item (Join-Path $repo 'README.md') $docOut

    # --- 6. zip ------------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $zip = Join-Path $OutDir "SkyrimNet Kinship-$Version.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

    Write-Host "`nPackaged $($zip)" -ForegroundColor Green
    Write-Host "  version   : $Version"
    Write-Host "  plugin    : SNKin_Integration.esp ($eslNote)"
    Write-Host "  SKSE dll  : $dllNote"
    Write-Host "  dll paths : $pathNote"
    Write-Host "  size      : $([math]::Round((Get-Item $zip).Length / 1KB, 1)) KB"
}
finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
}
