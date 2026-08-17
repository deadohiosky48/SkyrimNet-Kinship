<#
    Records a child's mother, for children that predate this mod.

    Exists because doing this by hand has three separate traps:

      1. `curl` in PowerShell is an ALIAS FOR Invoke-WebRequest, so a
         copy-pasted bash command fails with "Cannot bind parameter 'Headers'".
      2. The web API cannot marshal an Actor that is not currently loaded - it
         echoes {"type":"Actor","value":null} and abandons the dispatch without
         entering Papyrus, logging nothing at all. So this calls
         SetParentageById with an Int instead of SetParentage with an Actor.
      3. The response is useless. `result` is 0 for success, failure and a
         deliberately invalid name alike, and dispatch is ASYNCHRONOUS, so the
         only truth is snkin.log a second or two later. This waits and reads it.

    Usage:
        .\tools\set-parentage.ps1 -Child Toryy -MotherFormId 0xFE21C812
        .\tools\set-parentage.ps1 -Child Toryy -MotherFormId FE21C812
        .\tools\set-parentage.ps1 -Child Inga  -MotherFormId 0x000198A2 -Father Haruk

    Find a mother's reference FormID by clicking her in the console, or from
    `Invoke-WebRequest "http://127.0.0.1:8080/game-data?api=nearby-actors"`.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Child,
    [string]$MotherFormId,
    [string]$FatherFormId,
    [string]$Father,
    [string]$Api = 'http://127.0.0.1:8080',
    [string]$SkyrimRoot = 'G:\SteamLibrary\steamapps\common\Skyrim Special Edition'
)
if (-not $MotherFormId -and -not $FatherFormId -and -not $Father) {
    throw "Give at least one of -MotherFormId, -FatherFormId or -Father."
}

$ErrorActionPreference = 'Stop'
$log = Join-Path $SkyrimRoot 'Data\SKSE\Plugins\SkyrimNet Kinship\logs\snkin.log'

# Hex -> signed 32-bit Int. Papyrus Ints are signed, so 0xFE21C812 must arrive
# as -31307758; sending 4263659538 would overflow and resolve to nothing.
function ConvertTo-SignedFormId($value, $label) {
    $hex = $value -replace '^0[xX]', ''
    if ($hex -notmatch '^[0-9A-Fa-f]{1,8}$') { throw "$label '$value' is not a hex FormID." }
    $u = [uint32]::Parse($hex, 'AllowHexSpecifier')
    $signed = [int]$u
    Write-Host ("{0,-14} 0x{1:X8} -> {2} (signed)" -f $label, $u, $signed)
    if ($u -lt 0xFE000000) {
        Write-Host "  NOTE: that looks like a BASE record, not a placed reference." -ForegroundColor Yellow
        Write-Host "        A reference is usually 0xFF... (runtime spawn) or 0xFE... (ESL)." -ForegroundColor Yellow
    }
    return $signed
}

$before = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }

function Send-Fn($fn, $argsJson) {
    $body = '{"questEditorId":"SNKin_Kinship","scriptName":"SNKin_Bridge","functionName":"' + $fn + '","arguments":' + $argsJson + '}'
    $r = Invoke-WebRequest -UseBasicParsing -Uri "$Api/game-data?api=execute-quest-script-function" `
            -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 30
    ($r.Content | ConvertFrom-Json).result
}

$childJson = ($Child | ConvertTo-Json)   # quotes and escapes the name safely

# SetParentById(child, formId, isFather) - 0 mother, 1 father. An Int rather
# than a Bool because that is what survives the web API cleanly.
if ($MotherFormId) {
    $id = ConvertTo-SignedFormId $MotherFormId 'MotherFormId'
    Send-Fn 'SetParentById' "[$childJson,$id,0]" | Out-Null
}
if ($FatherFormId) {
    $id = ConvertTo-SignedFormId $FatherFormId 'FatherFormId'
    Send-Fn 'SetParentById' "[$childJson,$id,1]" | Out-Null
}
# Name-only correction, for a father who has no reference to point at.
if ($Father) { Send-Fn 'SetFatherName' "[$childJson,$($Father | ConvertTo-Json)]" | Out-Null }

# The game must be UNPAUSED for Papyrus to run the queued call. Alt-tabbed with
# the game paused, this waits and reports nothing rather than hanging.
Write-Host "`nWaiting for Papyrus (game must be running, not paused)..."
$deadline = (Get-Date).AddSeconds(20)
$found = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 800
    if (-not (Test-Path $log)) { continue }
    if ((Get-Item $log).Length -le $before) { continue }
    $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    $null = $fs.Seek($before, 'Begin')
    $new = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
    $fs.Close()
    $lines = $new -split "`r?`n" | Where-Object { $_ -match 'SetParentage|SetFatherName' }
    if ($lines) {
        Write-Host ""
        $lines | ForEach-Object {
            $colour = if ($_ -match 'no child named|is not an Actor') { 'Red' } else { 'Green' }
            Write-Host "  $_" -ForegroundColor $colour
        }
        $found = $true
        break
    }
}
if (-not $found) {
    Write-Host "`n  No confirmation in snkin.log after 20s." -ForegroundColor Yellow
    Write-Host "  Most likely the game is PAUSED (alt-tabbed or in a menu) - Papyrus does not"
    Write-Host "  run while paused, so the call is queued rather than lost. Unpause and re-run."
}
