<#
    Static checks for the failure modes in this stack that are SILENT at
    runtime. Every assertion below corresponds to a bug that shipped in a
    sibling mod and was found only by reading a rendered prompt.

    Run after every build:
        powershell -ExecutionPolicy Bypass -File "tools\check.ps1"
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo 'src\scripts'
$pexDir = Join-Path $repo 'Scripts'
$pluginDir = Join-Path $repo 'SKSE\Plugins\SkyrimNet\config\plugins\SkyrimNet Kinship'
$promptDir = Join-Path $repo 'SKSE\Plugins\SkyrimNet\prompts'

$fail = 0
function Bad($msg) { $script:fail++; Write-Host "  FAIL  $msg" -ForegroundColor Red }
function Good($msg) { Write-Host "  ok    $msg" -ForegroundColor DarkGray }

# --- 1. Config keys: manifest <-> settings.yaml <-> compiled .pex ----------
# A key must be in the manifest AND settings.yaml to be readable at all, and
# must survive compilation in EXACT CASE or the lookup silently returns its
# default forever (Papyrus interns strings case-insensitively).
Write-Host "`nConfig keys"
$manifest = Get-Content (Join-Path $pluginDir 'manifest.yaml') -Raw
$settings = Get-Content (Join-Path $pluginDir 'settings.yaml') -Raw
$paths = [regex]::Matches($manifest, '(?m)^\s*path:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
if (-not $paths) { Bad "no config paths found in manifest.yaml" }

$allPex = ''
Get-ChildItem $pexDir -Filter '*.pex' -File | ForEach-Object {
    $allPex += [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($_.FullName))
}

foreach ($p in $paths) {
    if ($p -match '\.') { Bad "manifest path '$p' contains a dot - dotted paths collapse to their last segment" }
    if ($settings -notmatch "(?m)^\s*$([regex]::Escape($p))\s*:") {
        Bad "'$p' is in manifest.yaml but NOT settings.yaml - it will never be tunable"
    } elseif ($allPex.Contains($p)) {
        Good "$p (manifest + settings + .pex, exact case)"
    } else {
        # Absent entirely is a dead key; present in another case is the folding trap.
        if ($allPex.ToLower().Contains($p.ToLower())) {
            Bad "'$p' appears in a .pex but NOT in exact case - string-table folding, lookup will return the default forever"
        } else {
            Bad "'$p' is advertised in the manifest but READ BY NOTHING"
        }
    }
}

# --- 2. Papyrus source traps ----------------------------------------------
Write-Host "`nPapyrus source"
foreach ($f in Get-ChildItem $src -Filter 'SNKin_*.psc' -File) {
    $text = Get-Content $f.FullName -Raw
    # Only \" and \\ are legal escapes. A literal \n compiles to the two
    # characters and renders as garbage in a prompt.
    #
    # The legal forms are matched FIRST so the pair in \\ is consumed whole.
    # A naive '\\(?!["\\])' consumes only the first backslash of \\ and then
    # tests the second against whatever follows, flagging every correct \\ that
    # is not followed by a quote - which is how this checker's own docstring
    # about escape sequences became its first failure.
    # A trailing backslash is Papyrus line continuation, also legal.
    $badEscapes = [regex]::Matches($text, '\\(?:["\\]|\r?\n)|(\\)') | Where-Object { $_.Groups[1].Success }
    if ($badEscapes.Count -gt 0) {
        Bad "$($f.Name): $($badEscapes.Count) unsupported escape sequence(s) - only \"" and \\ exist; build newlines with StringUtil.AsChar(10)"
    } else { Good "$($f.Name): no unsupported escapes" }

    if ($text -match '(?m)^\s*Continue\s*$') { Bad "$($f.Name): Papyrus has no Continue statement" }

    # A literal opening brace INSIDE a { } docstring closes it, and everything
    # after is then parsed as code - which fails somewhere further down with a
    # message pointing at the wrong line entirely. Writing a JSON example in a
    # docstring cost a build here; the compiler said
    # "required (...)+ loop did not match anything" 40 lines away.
    $inDoc = $false; $ln = 0; $docBad = 0
    foreach ($line in ($text -split "`r?`n")) {
        $ln++
        if (-not $inDoc) {
            if ($line -match '^\s*\{') {
                $rest = $line -replace '^\s*\{', ''
                if ($rest -match '\}') { continue }        # opened and closed on one line
                if ($rest -match '\{') { Bad "$($f.Name):${ln}: '{' inside a docstring - it CLOSES the docstring"; $docBad++ }
                $inDoc = $true
            }
        } else {
            if ($line -match '\{') { Bad "$($f.Name):${ln}: '{' inside a docstring - it CLOSES the docstring"; $docBad++ }
            if ($line -match '\}') { $inDoc = $false }
        }
    }
    if ($docBad -eq 0) { Good "$($f.Name): no braces inside docstrings" }
}

# A function must never share a name with a config path it reads - they
# collide in the string table and the identifier wins. The "kin" prefix on
# every path is what makes this structurally impossible; assert it holds.
Write-Host "`nFunction/config collisions"
$funcs = @()
foreach ($f in Get-ChildItem $src -Filter 'SNKin_*.psc' -File) {
    $funcs += [regex]::Matches((Get-Content $f.FullName -Raw), '(?im)^\s*(?:\w+\s+)?Function\s+(\w+)') | ForEach-Object { $_.Groups[1].Value }
}
$collided = $false
foreach ($p in $paths) {
    foreach ($fn in $funcs) {
        if ($fn -ieq $p) { Bad "function '$fn' collides case-insensitively with config path '$p'"; $collided = $true }
    }
}
if (-not $collided) { Good "no function name collides with a config path" }

# --- 3. Prompt traps -------------------------------------------------------
Write-Host "`nPrompts"
foreach ($f in Get-ChildItem $promptDir -Filter '*.prompt' -Recurse -File) {
    $lines = Get-Content $f.FullName
    $head = ($lines | Select-Object -First 5) -join "`n"
    if ($head -notmatch 'render_mode') {
        Bad "$($f.Name): no render_mode guard in the first 5 lines - SkyrimNet scans only that far"
    } else { Good "$($f.Name): render_mode guard present" }

    $body = $lines -join "`n"
    # player_name is a TRIGGER-only global. In a prompt it renders blank and
    # silently - the worst kind of wrong.
    if ($body -match '\{\{\s*player_name\s*\}\}') {
        Bad "$($f.Name): uses {{ player_name }} - that is trigger-only and renders BLANK in a prompt; use {{ player.name }}"
    }
    # Jinja2 has `is defined`; Inja does not. Use default().
    if ($body -match '\bis\s+defined\b') {
        Bad "$($f.Name): uses 'is defined' - Inja is not Jinja2 and has no such test; use default()"
    }
    # A lowercase JSON boolean from Papyrus cannot be trusted; the prompts
    # must compare Ints.
    if ($body -match '==\s*(true|false)\b') {
        Bad "$($f.Name): compares against a JSON boolean - Papyrus cannot emit one reliably; compare == 1"
    }
}

Write-Host ""
if ($fail -gt 0) {
    Write-Host "$fail check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All checks passed." -ForegroundColor Green
