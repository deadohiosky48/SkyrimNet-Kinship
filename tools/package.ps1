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
        pwsh -ExecutionPolicy Bypass -File "tools\package.ps1"
#>
[CmdletBinding()]
param(
    [string]$SkyrimRoot = '',
    [string]$Version,
    [string]$OutDir,
    # SkyrimNet Beta 25 plugin id: author.slug, lowercase, exactly one dot. The
    # external folder must be named this exactly or Beta 25 rejects the whole
    # folder. Changing it after release makes players see a NEW plugin instead
    # of an update, so it is fixed here rather than derived from anything that
    # might drift.
    [string]$PluginId = 'deadohiosky48.kinship'
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


    # STRIP THE BUILD MACHINE'S IDENTITY. The Papyrus compiler writes the
    # compiling account's username and the computer name into every .pex header.
    # Nothing surfaces it and no text search finds it, because .pex is binary -
    # so it shipped in this mod's first three releases before anyone noticed.
    # Scrubbing the STAGED copies leaves the build output alone.
    & (Join-Path $PSScriptRoot 'sanitize-pex.ps1') -Path (Join-Path $stage 'Scripts') -Recurse

    # --- 3. prompt and manifest --------------------------------------------
    Copy-Item (Join-Path $repo 'SKSE') $stage -Recurse -Force

    # SETTINGS.YAML IS DELIBERATELY NOT SHIPPED.
    #
    # It is LIVE STATE. Shipping it means every version installed through a mod
    # manager replaces the player's configuration with defaults - silently, and
    # with no way for this mod to prevent it, because replacing a mod's files is
    # exactly what installing a mod means. That happened here: a Vortex update
    # turned life stages, sizing and confiscation all back off mid-playthrough.
    #
    # SkyrimNet GENERATES the file from manifest.yaml when it is missing, and
    # then never overwrites it. Verified against SeverActions, which ships only
    # a manifest and has a live settings.yaml anyway - which is why its settings
    # survive updates and ours did not.
    #
    # The repo copy stays: it carries the reasoning behind every default, and
    # tools/deploy.ps1 uses it for local work while preserving live values.
    $shipped = Join-Path $stage 'SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Kinship\settings.yaml'
    if (Test-Path $shipped) {
        Remove-Item $shipped -Force
    }

    # --- 3b. the Beta 25 content layer, GENERATED from the tree above -------
    #
    # SkyrimNet Beta 25 stopped reading prompts\ and reads a plugin library
    # instead; older builds have never heard of the plugin library. So the
    # archive carries BOTH layouts and each build reads only the one it knows -
    # old files are "ignored, not deleted" on Beta 25, and external\ is an
    # unknown folder to Beta 24. No version detection anywhere, and a player can
    # upgrade SkyrimNet whenever they like without touching this mod.
    #
    # ONLY prompts\ MOVES. The settings manifest under config\plugins\ is a
    # different subsystem that Beta 25 did not change, so it stays exactly where
    # it is - copying it into the content layer would be wrong, and Beta 25
    # would reject it anyway for living outside the four content folders.
    #
    # GENERATED, NEVER HAND-MAINTAINED. Two copies of the same file that must
    # stay identical is a drift bug waiting to happen, and the drift would be
    # INVISIBLE: each SkyrimNet build reads exactly one of the copies, so a
    # stale duplicate misbehaves only for the half of the audience you are not
    # testing on. The repo keeps one source of truth and this builds the other.
    $snRoot = Join-Path $stage 'SKSE\Plugins\SkyrimNet'
    $ext    = Join-Path $snRoot "external\$PluginId"
    New-Item -ItemType Directory -Force -Path $ext | Out-Null

    # Prompts keep their sub-paths verbatim: prompts\submodules\character_bio\
    # is still where a submodule lives on Beta 25.
    Copy-Item (Join-Path $snRoot 'prompts') $ext -Recurse -Force

    # The manifest. Folder name must equal `id` exactly, and `author` must equal
    # the id's author segment, so both come from $PluginId.
    #
    # `version` must be strict semver or Beta 25 rejects the plugin.
    $semver = [regex]::Match($Version, '^\d+\.\d+\.\d+')
    if (-not $semver.Success) { throw "Version '$Version' has no semver core for the plugin manifest." }
    $manifest = [ordered]@{
        id                    = $PluginId
        type                  = 'bundle'
        title                 = 'SkyrimNet Kinship'
        tagline               = 'Children know who their parents are, and mothers never forget.'
        description           = 'The character-bio submodule for SkyrimNet Kinship. Requires the Kinship mod itself.'
        author                = ($PluginId -split '\.')[0]
        tags                  = @('family', 'dialogue')
        nsfw                  = $false
        icon                  = 'sparkles'
        version               = $semver.Value
        min_skyrimnet_version = '0.25.0'
        mods                  = @(@{ name = 'SkyrimNet Kinship'; file = 'SNKin_Integration.esp'; required = $true })
    }
    # -Depth matters: without it PowerShell flattens the nested `mods` entry to
    # a type name string and the manifest ships silently malformed.
    #
    # WRITTEN WITHOUT A BOM, and not with Set-Content -Encoding UTF8, whose
    # behaviour DEPENDS ON THE HOST: Windows PowerShell 5.1 emits a BOM, pwsh 7
    # does not. A BOM is three bytes before the opening brace - still valid
    # UTF-8, not valid JSON to a strict parser - and the failure is the whole
    # plugin folder rejected with nothing pointing at the cause.
    #
    # THE HOST DEPENDENCY IS THE TRAP, not the encoding. The usage line at the
    # top of this file says `powershell`, which is 5.1, so the documented way to
    # run this script was the way that produced a BOM - while any build driven
    # by a pwsh 7 shell came out clean. Same script, same repo, two different
    # artifacts depending on what typed the command.
    #
    # ONE WRITE, and version is correct before it. An earlier shape wrote the
    # file and then read it back to substitute the semver, which doubled the
    # encoding decision, pulled a BOM into a string through Get-Content -Raw,
    # and matched a '"version": "..."' literal that any formatting change would
    # break. Resolving $semver before the hashtable removes all three at once.
    $manifestPathOut = Join-Path $ext 'manifest.json'
    [System.IO.File]::WriteAllText(
        $manifestPathOut,
        ($manifest | ConvertTo-Json -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))

    # ASSERTED IN BYTES, because the bug is host-dependent and so is most of the
    # machinery that could check it. System.Text.Json is .NET Core only and is
    # simply absent under 5.1 - a check that throws on the very host the bug
    # appears on is not a check. Comparing the first byte to 0x7B is arithmetic
    # and works anywhere; ConvertFrom-Json then confirms the content parses.
    $mBytes = [System.IO.File]::ReadAllBytes($manifestPathOut)
    if ($mBytes.Length -lt 1 -or $mBytes[0] -ne 0x7B) {
        $head = ($mBytes[0..([Math]::Min(3, $mBytes.Length - 1))] |
                 ForEach-Object { $_.ToString('X2') }) -join ' '
        throw "manifest.json does not start with '{' (first bytes: $head) - a BOM or stray prefix would have Beta 25 reject the whole plugin folder."
    }
    try {
        $null = [System.Text.Encoding]::UTF8.GetString($mBytes) | ConvertFrom-Json
    } catch {
        throw "manifest.json is not valid JSON: $($_.Exception.Message)"
    }

    # EVERY LEGACY CONTENT FILE MUST HAVE A COUNTERPART, compared by hash.
    #
    # The copies cannot drift - they are generated - so this is not guarding
    # against edits. It guards against a file the generator does not know about:
    # add a prompts\ sub-folder, a knowledge pack, a triggers\ directory, and
    # the old layer would ship it while the new one silently would not. That
    # failure only shows up for players on the OTHER SkyrimNet build from the
    # one being tested, which is the worst possible place to discover it.
    $legacy = @(Get-ChildItem (Join-Path $snRoot 'prompts') -Recurse -File)
    $extHashes = @{}
    foreach ($f in (Get-ChildItem $ext -Recurse -File)) {
        if ($f.Name -eq 'manifest.json') { continue }
        $extHashes[(Get-FileHash $f.FullName).Hash] = $f.Name
    }
    foreach ($f in $legacy) {
        $h = (Get-FileHash $f.FullName).Hash
        if (-not $extHashes.ContainsKey($h)) {
            throw "Beta 25 layer is missing '$($f.Name)'. The generator in package.ps1 does not cover it - every content file must exist in both layouts."
        }
    }
    if ($extHashes.Count -ne $legacy.Count) {
        throw "Layer file counts differ: legacy $($legacy.Count), Beta 25 $($extHashes.Count)."
    }
    Write-Host ("  Beta 25   external\{0}  (both layouts carry the same {1} content file(s))" -f $PluginId, $legacy.Count)

    # --- 3c. the optional SKSE panel, if it has been built -----------------
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
    # LICENSE ships too. The terms are reserved-rights with enumerated
    # permissions rather than a permissive licence, so what a user may and may
    # not do is no longer obvious from convention - it has to travel with the
    # files rather than living only in a repository they may never visit.
    Copy-Item (Join-Path $repo 'LICENSE') $docOut

    # --- 5b. REFUSE TO SHIP THE BUILD MACHINE'S IDENTITY --------------------
    # Section 3c reads text files only, which is exactly how the first releases of
    # this mod shipped the build account's username and computer name: the Papyrus
    # compiler stamps both into every .pex header, .pex is binary, and no text
    # search can see it. sanitize-pex.ps1 above removes it; this proves it is gone,
    # and covers every other file too - the .esl, anything added later.
    #
    # The tokens are read from the ENVIRONMENT, never written down. This script is
    # published, so hardcoding the names to search for would itself be the leak,
    # and would only ever protect one machine. Derived this way it protects
    # whoever runs it.
    $identity = @($env:USERNAME, $env:COMPUTERNAME, $env:USERDOMAIN) |
        Where-Object { $_ -and $_.Length -ge 4 } | Sort-Object -Unique

    $found = @()
    foreach ($file in (Get-ChildItem $stage -Recurse -File)) {
        # Latin-1 maps every byte to exactly one char, so a byte scan and a text
        # scan are the same scan. UTF-8 would mangle high bytes and could split a
        # match; ASCII would drop them.
        # GetEncoding(28591) rather than ::Latin1 - the named property exists only
        # in PowerShell 7, and this must run under Windows PowerShell 5.1 too,
        # where it silently evaluates to null and takes the guard offline.
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString(
                    [System.IO.File]::ReadAllBytes($file.FullName))
        foreach ($token in $identity) {
            if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $found += "$($file.Name) contains the build machine's identity"
            }
        }
    }
    if ($found) {
        Write-Host ""
        Write-Host "  REFUSING TO PACKAGE - build machine identity in shipped files:" -ForegroundColor Red
        $found | Sort-Object -Unique | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        throw "Identifying strings would be published. Fix them, then re-run."
    }

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
