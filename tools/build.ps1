<#
    Compiles the SkyrimNet-Kinship Papyrus sources.

    Inherited wholesale from the Romantasy mod's build.ps1, including three
    non-obvious things it discovered the hard way:

      1. TESV_Papyrus_Flags.flg lives in Data/source/scripts (the AE layout),
         NOT Data/Scripts/Source. Pointing -f at the wrong one produces a
         misleading "Unknown user flag Hidden" for every base script.

      2. Actor.psc exists ONLY in Data/Scripts/Source (legacy layout), while
         other base scripts exist in both. Neither folder alone is sufficient.

      3. AssociationType.psc is missing from BOTH folders on a stock install.
         Actor.psc references it, so every compile fails with "unknown type
         associationtype" until the full source set is extracted from
         Data/Scripts.zip. That extraction is cached under .build/.

    Plus one of our own: _JSW_BB_Storage.psc is vendored into src/scripts as a
    COMPILE-ONLY header so SNKin_Bridge can type its reference to FMR's live
    storage quest. It must never be emitted as .pex - doing so would overwrite
    Fertility Mode Reloaded's own script through a Vortex conflict and break
    that mod outright. The -Filter below is what prevents it.

    Usage (Windows PowerShell 5.1 - `pwsh` is PS7 and is NOT installed here):
        powershell -ExecutionPolicy Bypass -File "tools\build.ps1"
        powershell -ExecutionPolicy Bypass -File "tools\build.ps1" -Clean
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$SkyrimRoot = Resolve-SkyrimRootOrThrow -Override $SkyrimRoot
$repo = Split-Path -Parent $PSScriptRoot
$data = Join-Path $SkyrimRoot 'Data'
$compiler = Join-Path $SkyrimRoot 'Papyrus Compiler\PapyrusCompiler.exe'
$flags = Join-Path $data 'source\scripts\TESV_Papyrus_Flags.flg'

$srcDir = Join-Path $repo 'src\scripts'
$outDir = Join-Path $repo 'Scripts'
$buildDir = Join-Path $repo '.build'
$vanilla = Join-Path $buildDir 'vanilla_src\Source\Scripts'

foreach ($p in @($compiler, $flags)) {
    if (-not (Test-Path $p)) { throw "Not found: $p`nPass -SkyrimRoot if your install is elsewhere." }
}

# --- Vanilla source set (cached) -----------------------------------------
if ($Clean -and (Test-Path $buildDir)) {
    Remove-Item $buildDir -Recurse -Force
}
if (-not (Test-Path (Join-Path $vanilla 'AssociationType.psc'))) {
    $zip = Join-Path $data 'Scripts.zip'
    if (-not (Test-Path $zip)) { throw "Missing $zip - needed for AssociationType.psc and friends." }
    Write-Host 'Extracting vanilla script sources from Scripts.zip (one time)...'
    New-Item -ItemType Directory -Force -Path (Join-Path $buildDir 'vanilla_src') | Out-Null
    Expand-Archive -Path $zip -DestinationPath (Join-Path $buildDir 'vanilla_src') -Force
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ORDER IS LOAD-BEARING. Data\Scripts\Source holds the SKSE-EXTENDED base
# scripts - it is the only copy of Form.psc that declares RegisterForModEvent,
# and the only copy of Actor.psc anywhere. The other two folders carry plain
# vanilla versions that SHADOW it if they come first, producing the very
# confusing "RegisterForModEvent is not a function or does not exist".
#
# The extracted Scripts.zip set therefore goes LAST: it exists only to fill
# genuine gaps (AssociationType.psc, absent from both on-disk folders), never
# to override a live SKSE definition.
#
# $srcDir MUST COME FIRST. Data\Scripts\Source accumulates copies of our own
# .psc files (the Creation Kit needs them there to see the scripts), and if
# that folder is searched first the compiler silently resolves "SNKin_Bridge"
# from the STALE copy and compiles that instead of the file it was handed -
# producing a .pex that does not match source, with no error.
$imports = @(
    $srcDir                                # ours wins, always
    (Join-Path $data 'Scripts\Source')     # SKSE-extended: Form, Actor
    (Join-Path $data 'source\scripts')     # AE additions
    $vanilla                               # gap-filler only
) -join ';'

# Compile ONLY our own scripts. src\scripts also holds vendored dependency
# headers (SkyrimNetApi.psc, _JSW_BB_Storage.psc) so our code compiles against
# them - but emitting .pex for those would overwrite the owning mods' real
# scripts through a Vortex conflict. They are imports, never output.
$sources = Get-ChildItem -Path $srcDir -Filter 'SNKin_*.psc' -File
if (-not $sources) { throw "No SNKin_*.psc files in $srcDir" }

Write-Host "Compiling $($sources.Count) script(s) -> $outDir`n"
$failed = 0
foreach ($s in $sources) {
    $out = & $compiler $s.FullName -f="$flags" -i="$imports" -o="$outDir" 2>&1
    if ($out -match 'Compilation succeeded') {
        Write-Host ("  OK    " + $s.Name)
    } else {
        $failed++
        Write-Host ("  FAIL  " + $s.Name) -ForegroundColor Red
        $out | Where-Object { $_ -match '\.psc\(' } | Select-Object -First 8 | ForEach-Object {
            Write-Host ("        " + $_) -ForegroundColor DarkYellow
        }
    }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "$failed script(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All scripts compiled." -ForegroundColor Green
