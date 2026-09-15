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

    # A JsonUtil path is resolved against StorageUtilData and nothing else, so
    # a "../" in one points at a file that is not there. It does not throw: the
    # read returns zero entries, and a caller that treats "no data" as a reason
    # to fall back does so forever.
    #
    # THIS IS NOT HYPOTHETICAL. NamesFile() returned "../SNKin_Names" from 1.5.0
    # and the name-list feature was dead the whole time, because its failure
    # mode - offer a text box instead - is identical to the feature being
    # switched off. Two months and one live birth to notice.
    # DOCSTRINGS STRIPPED FIRST, or the comment above NamesFile() explaining
    # this very bug would trip the guard that exists because of it. Safe to
    # match with '\{[^}]*\}' precisely because the next check forbids a brace
    # inside a docstring.
    # PAPYRUS HAS NO None ARRAY. `Return None` from a function declared to
    # return an array type compiles clean and fails at RUNTIME with
    # "Cannot cast from None to String[]" - visible only in Papyrus.0.log,
    # which this mod does not read. Everything downstream then operates on a
    # value that is not an array.
    #
    # COST TWO BUILDS AND TWO LIVE BIRTHS. NamePool used None as "no list
    # here"; 305 names arrived as nothing and the naming prompt silently fell
    # back to a text box. The fix that followed tested `== None`, which is the
    # same mistake, so it could not have worked either.
    #
    # Return a count and fetch the array separately, or return a real empty
    # array. Reading an array PROPERTY that is None is a different thing and
    # stays legal - this only looks at what a function hands back.
    $noneArray = 0
    $fnArray = $false
    $ln2 = 0
    foreach ($line in ($text -split "`r?`n")) {
        $ln2++
        if ($line -match '(?i)^\s*[A-Za-z_]+\[\]\s+Function\s') { $fnArray = $true }
        elseif ($line -match '(?i)^\s*(Function|Event)\s|^\s*[A-Za-z_]+\s+Function\s') { $fnArray = $false }
        if ($fnArray -and $line -match '(?i)^\s*Return\s+None\s*$') {
            Bad "$($f.Name):${ln2}: 'Return None' from an array-returning function - Papyrus has no None array; it fails at runtime, not build"
            $noneArray++
        }
    }
    if ($noneArray -eq 0) { Good "$($f.Name): no None returned as an array" }

    $code = [regex]::Replace($text, '\{[^}]*\}', '')
    $upPaths = [regex]::Matches($code, '"[^"]*\.\./[^"]*"')
    if ($upPaths.Count -gt 0) {
        Bad "$($f.Name): $($upPaths.Count) path literal(s) containing '../' - JsonUtil resolves against StorageUtilData only: $(($upPaths | ForEach-Object { $_.Value }) -join ', ')"
    } else { Good "$($f.Name): no '../' in path literals" }

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

# The manifest's declared TYPE must match how Papyrus reads the key.
#
# A mismatch is silent in the worst possible way: the mod behaves correctly,
# because GetConfigFloat coerces the YAML number happily - but the DASHBOARD
# honours the declared type, refuses the stored value, and shows the manifest
# default instead. The player edits a box, saves, comes back, and their value
# has apparently reverted. It had not: it was on disk the whole time, being
# displayed as the default and then written back over.
#
# Every numeric field in this mod shipped as type "string" for months for
# exactly this reason. SkyrimNet supports "float" and "int" - its own core
# plugin uses twelve and nine of them - and those are what a numeric field must
# declare.
Write-Host "`nManifest type vs Papyrus read"
$declared = @{}
foreach ($m in [regex]::Matches($manifest, '(?s)path:\s*"(kin[A-Za-z0-9_]+)".*?type:\s*"([a-z]+)"')) {
    $declared[$m.Groups[1].Value] = $m.Groups[2].Value
}
$readAs = @{}
foreach ($f in Get-ChildItem $src -Filter 'SNKin_*.psc' -File) {
    $body = Get-Content $f.FullName -Raw
    foreach ($m in [regex]::Matches($body, 'GetConfig(Bool|Int|Float|String)\(\s*CFG\(\)\s*,\s*"(kin[A-Za-z0-9_]+)"')) {
        $readAs[$m.Groups[2].Value] = $m.Groups[1].Value.ToLower()
    }
}
$mismatch = 0
foreach ($k in ($readAs.Keys | Sort-Object)) {
    $want = $readAs[$k]
    $have = $declared[$k]
    if (-not $have) {
        Bad "$k is read from Papyrus but not declared in manifest.yaml"; $mismatch++
    } elseif ($have -ne $want) {
        Bad "$k : manifest says type `"$have`" but Papyrus reads it as $want - the dashboard will show the default and silently discard edits"
        $mismatch++
    }
}
if ($mismatch -eq 0) {
    Good "all $($readAs.Count) config key(s) declare the type Papyrus reads"
}

# The manifest's defaultValue and the Papyrus fallback must be the SAME NUMBER.
#
# These are two independent statements of one default, and they drifted: the
# hotkey read 70 in Papyrus while the manifest said 10 and BOTH files carried a
# comment explaining that 70 is Scroll Lock, which NPC Renamer claims. Also
# adrift were the modifier (0 vs 42), the poll interval (0.5 vs 1.0) and the
# adolescent scale (1.12 vs 1.25).
#
# It went unnoticed for as long as settings.yaml was SHIPPED, because a value
# present in that file means the Papyrus fallback is never reached. Version
# 1.5.0 stopped shipping it - correctly, so a mod-manager update cannot reset a
# player's config - and in doing so made every one of these fallbacks reachable
# on a fresh install, for as long as it takes SkyrimNet to generate the file
# from the manifest. The safety net became the live default.
Write-Host "`nManifest default vs Papyrus fallback"
$mfDefault = @{}
foreach ($m in [regex]::Matches($manifest, '(?s)path:\s*"(kin[A-Za-z0-9_]+)".*?defaultValue:\s*([^\r\n]+)')) {
    $mfDefault[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
}
$psFallback = @{}
foreach ($f in Get-ChildItem $src -Filter 'SNKin_*.psc' -File) {
    $body = Get-Content $f.FullName -Raw
    foreach ($m in [regex]::Matches($body, 'GetConfig(?:Bool|Int|Float|String)\(\s*CFG\(\)\s*,\s*"(kin[A-Za-z0-9_]+)"\s*,\s*([^)]+)\)')) {
        $psFallback[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
    }
}
# Compare as VALUES, not as text: 1.0 and 1 are the same default, and Papyrus
# writes True where YAML writes true.
function Normalize($v) {
    $v = $v.Trim()
    if ($v -match '^(?i)(true|false)$') { return $v.ToLower() }
    $d = 0.0
    if ([double]::TryParse($v, [ref]$d)) { return $d.ToString('G17') }
    return $v
}
$drift = 0
foreach ($k in ($psFallback.Keys | Sort-Object)) {
    if (-not $mfDefault.ContainsKey($k)) { continue }
    $a = Normalize $mfDefault[$k]
    $b = Normalize $psFallback[$k]
    if ($a -ne $b) {
        Bad "$k : manifest defaultValue is $($mfDefault[$k]) but the Papyrus fallback is $($psFallback[$k]) - a fresh install uses the Papyrus value until SkyrimNet writes settings.yaml"
        $drift++
    }
}
if ($drift -eq 0) { Good "all $($psFallback.Count) default(s) agree between manifest and Papyrus" }

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

# The registration decides WHICH event fires, and the two do not interchange:
#
#     RegisterForSingleUpdate(seconds)       -> OnUpdate()
#     RegisterForSingleUpdateGameTime(hours) -> OnUpdateGameTime()
#
# Registering one and implementing the other raises no error, no warning, and
# no event. This mod shipped that way from the start: it registered game-time
# updates and implemented OnUpdate, so the hourly poll never fired ONCE. It
# went unnoticed because Bootstrap also sweeps and Bootstrap runs on every game
# load - which, during development, is every few minutes.
Write-Host "`nUpdate registration"
foreach ($f in Get-ChildItem $src -Filter 'SNKin_*.psc' -File) {
    # COMMENTS ARE NOT CODE, and this check has to know the difference. Its own
    # first run failed on the docstring above that EXPLAINS the trap, because
    # that docstring names RegisterForSingleUpdate(seconds) as an example. A
    # static check that reads prose reports on prose.
    #
    # Papyrus has ; to end of line and { } for docstrings. Strip both.
    $body = Get-Content $f.FullName -Raw
    $body = [regex]::Replace($body, '\{[^}]*\}', ' ', 'Singleline')
    $body = [regex]::Replace($body, ';[^\r\n]*', ' ')
    $wantsGame = $body -match 'RegisterForSingleUpdateGameTime\s*\('
    $wantsReal = $body -match 'RegisterForSingleUpdate\s*\('
    $hasGame   = $body -match '(?im)^\s*Event\s+OnUpdateGameTime\s*\('
    $hasReal   = $body -match '(?im)^\s*Event\s+OnUpdate\s*\('
    if ($wantsGame -and -not $hasGame) {
        Bad "$($f.Name): registers RegisterForSingleUpdateGameTime but has no OnUpdateGameTime event - the poll will never fire"
    } elseif ($wantsGame) {
        Good "$($f.Name): OnUpdateGameTime present for its game-time registration"
    }
    if ($wantsReal -and -not $hasReal) {
        Bad "$($f.Name): registers RegisterForSingleUpdate but has no OnUpdate event - the poll will never fire"
    }
    if ($hasReal -and -not $wantsReal) {
        Bad "$($f.Name): implements OnUpdate but never registers a real-time update - dead code, or the game-time event was meant"
    }
}

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

Write-Host "`nBeta 25 plugin id"
# The archive ships prompts\ for Beta 24 and external\<id>\ for Beta 25, and
# package.ps1 and deploy.ps1 each carry the id as a default. If they disagree,
# local testing exercises one folder name and players get another - and since
# each SkyrimNet build reads only one of the two layouts, the mismatch is
# invisible on whichever build the author happens to run.
#
# A CHANGED ID IS NOT AN UPDATE. Beta 25 keys a plugin by its id, so renaming
# it after release makes every player see a new plugin sitting alongside the old
# one rather than an update to it.
$idPkg = [regex]::Match((Get-Content (Join-Path $PSScriptRoot 'package.ps1') -Raw),
                        '(?m)^\s*\[string\]\$PluginId\s*=\s*''([^'']+)''')
$idDep = [regex]::Match((Get-Content (Join-Path $PSScriptRoot 'deploy.ps1') -Raw),
                        '(?m)^\s*\[string\]\$PluginId\s*=\s*''([^'']+)''')
if (-not $idPkg.Success -or -not $idDep.Success) {
    Bad "could not read `$PluginId from package.ps1 and deploy.ps1"
} elseif ($idPkg.Groups[1].Value -ne $idDep.Groups[1].Value) {
    Bad "plugin id differs: package.ps1 '$($idPkg.Groups[1].Value)', deploy.ps1 '$($idDep.Groups[1].Value)'"
} elseif ($idPkg.Groups[1].Value -notmatch '^[a-z0-9_-]+\.[a-z0-9_-]+$') {
    Bad "plugin id '$($idPkg.Groups[1].Value)' is not '{author}.{slug}', lowercase [a-z0-9_-] with one dot"
} else {
    Good "package.ps1 and deploy.ps1 agree on '$($idPkg.Groups[1].Value)'"
}

Write-Host ""
if ($fail -gt 0) {
    Write-Host "$fail check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All checks passed." -ForegroundColor Green
