# SkyrimNet Kinship

Makes parent–child relationships from **Fertility Mode Reloaded** permanent and
visible to **SkyrimNet**, so a child's dialogue knows who its parents are and a
mother never forgets the child she bore — however much time has passed.

Soft dependency on both. Without Fertility Mode the plugin loads inert and the
decorator answers `known:0`; nothing errors and no prompt breaks.

---

## The bug this fixes

A birth reached SkyrimNet only as a **memory**, and only when the player
happened to be present — e.g. *"Fastred gave birth to her baby at Riverside
Lodge. I witnessed her fear… (Importance 0.5)"*. Memories are a rolling window.
They decay, and the mother then speaks as though it never happened.

Meanwhile the children have **no persona at all**. Of 3,151 cached character
bios on this install, not one mentions the player's children or the player as a
parent. Fertility Mode renames the *reference*, not the ActorBase — Nicollette's
base is still literally `Player's Nord Mage Daughter` — and SkyrimNet keys its
bio cache off the base, so a renamed dynamic reference never gets an authored
persona.

**The permanent layer is the character bio, and nothing wrote to it.** That is
what this mod does: `0340_kinship.prompt` renders from our own store on every
single bio build, so it cannot decay and cannot be forgotten.

---

## How the birth signal is obtained

**Not** via UILib, which the original spec recommended. That route was measured
and rejected — see the header comment in `src/scripts/SNKin_Bridge.psc`:
`_JSW_BB_Utility.GenerateName` only reaches `ShowTextInput` when the MCM
"Desktop Mode" global `UseKeyboardInput == 1`. The **default** path is
`ShowVRNameMenuSimple` (a UIExtensions list), and the duplicate-name fallback is
a UIExtensions list too. A UILib listener hears nothing on a stock config.

Instead, all verified against Fertility Mode Reloaded 1.0.3 sources:

| Signal | Carries | Used for |
|---|---|---|
| `FertilityModeConception` | mother, mother name, **father name**, index | the only moment the father is reliably known |
| `FertilityModeLabor` | mother, index | who delivered, and when |
| `FMR_MotherDeath` | mother, was-pregnant, had-baby | stop watching; records are kept |
| direct reads of `_JSW_BB_Storage` | child list, `BabyAdded`, spawned child refs | pairing a new child record to the mother who delivered |

Storage is reached the same way the shipped SeverActions FM bridge reaches it:
`Game.GetFormFromFile(0x0D62, "Fertility Mode.esm") as _JSW_BB_Storage`, behind
a `Game.GetModByName` guard. That is a **proven** third-party read of FMR state,
which answers the spec's two open questions affirmatively.

### An actual bug in Fertility Mode, worth knowing about

`_JSW_BB_HandlerQuestAliasScript` **clears** `Storage.LastFather[actorIndex]`
at line 1636 and then reads it into `fatherName` at line 1655. Every child born
through the normal automatic path is therefore recorded by FMR with father
`"Unknown"`. The MCM path in `_JSW_BB_ConfigQuestScript` reads it *before*
clearing (line 3111) and is correct.

This mod does not depend on that field. It captures the father at **conception**
and only falls back to FMR's value when it is not `"Unknown"`.

---

## Failing closed

Maternity is recorded only when exactly **one** mother is awaiting a child
record. Zero or two candidates records the father and leaves the mother blank.

That is deliberate and is the single most important behaviour in the mod. A
blank mother is visible, is logged as a warning, and can be fixed with one API
call. A **wrong** mother is permanent, renders in the child's own bio as
established fact, and would never be noticed.

The prompt reflects the same principle: a child whose mother is unknown reads as
*a child who has not been told*, never as a child with no mother.

---

## Install

1. Build the ESP — **required, and the only manual step**. See
   [`docs/BUILD_PLUGIN.md`](docs/BUILD_PLUGIN.md). One quest, one alias, no
   masters beyond vanilla, about ten minutes in the Creation Kit.
2. Everything else is already deployed by `tools\deploy.ps1`.
3. **Restart the game fully.** A save reload reuses cached scripts.

---

## Working on it

```bash
powershell -ExecutionPolicy Bypass -File "tools\build.ps1"
```

```bash
powershell -ExecutionPolicy Bypass -File "tools\check.ps1"
```

```bash
powershell -ExecutionPolicy Bypass -File "tools\deploy.ps1"
```

`check.ps1` is not optional garnish — every assertion in it corresponds to a
failure mode in this stack that is **silent at runtime**: config keys that
case-fold in the string table and return their default forever, dotted manifest
paths that collapse onto each other, `{{ player_name }}` rendering blank in a
prompt, a missing `render_mode` guard, JSON booleans Papyrus cannot emit
reliably.

Deploy cadence: `.prompt` hot-reloads, YAML needs a UI reload from disk, `.pex`
needs a **full game restart**.

---

## Manual entry for existing children

Children who already existed when this was installed are seeded with the player
as father. Their **mothers are genuinely unrecoverable** — Fertility Mode never
stored the link — so they must be entered by hand.

Use the helper — it handles every trap below for you:

```bash
powershell -ExecutionPolicy Bypass -File "tools\set-parentage.ps1" -Child Toryy -MotherFormId 0xFE21C812
```

It converts the FormID, posts the call, waits for Papyrus, and prints the
confirmation line from `snkin.log`.

> **Do not paste a `curl` command into PowerShell.** `curl` is an *alias for
> `Invoke-WebRequest`* there, so the bash flags are parsed as PowerShell
> parameters and it dies with
> `Cannot bind parameter 'Headers'`. That is not an error from the mod.

### Why there are two entry points

`SetParentage(String, Actor)` works only when the mother is **currently
loaded**. Measured against the live game — a nearby NPC's FormID echoes back as
an Actor with value `0x000198a2`, while an absent one echoes value `null`, and
SkyrimNet then abandons the dispatch **without entering Papyrus at all**, so not
even an error reaches the log. True with and without the `0x` prefix.

Since every child predating this mod needs its mother entered by hand, and
those mothers are scattered across Skyrim, `SetParentageById(String, Int)`
exists: an Int survives the boundary, and the form lookup happens in Papyrus via
`Game.GetFormEx` (not `GetForm`, which mangles anything above `0x7FFFFFFF` —
that is every ESL reference and every runtime spawn).

The Int must be the **signed** form: `0xFE21C812` → `-31307758`. The helper
script does that conversion.

Also available: `SetFatherName(childName, fatherName)` and `DumpRoster()`.

**Verified working on a live save.** Three calls produced, in `snkin.log`:

```
SetFatherName: Toryy -> father Haruk.
SetFatherName: Nicollette -> father Haruk.
SetFatherName: no child named 'NoSuchChild' on the roster.
```

Two things about this endpoint that will otherwise cost you an afternoon:

> **The response tells you nothing. Read `snkin.log` instead.** `result` comes
> back as `0` for every call — a success, a failure, and a deliberately invalid
> child name are indistinguishable. Papyrus return values are not marshalled at
> all, so a `String`-returning function like `DumpRoster` also reports `0`.
>
> **Dispatch is asynchronous.** The call returns
> `"message": "Function executed successfully"` before Papyrus has run the
> function. Checking the log immediately shows nothing and looks exactly like a
> dead endpoint — it isn't; wait a second or two.
>
> `execute-quest-script-function` also cannot call `Global` functions and does
> not apply Papyrus default parameter values, so the argument count must match
> the signature exactly. These three are instance functions with every
> parameter explicit for that reason.

---

## What it exposes

`get_kinship(actorUUID)` — full record for the current speaker or target.

```json
{"known":1,"role":"child","name":"Toryy","father":"Haruk","mother":"Fastred",
 "motherKnown":1,"gender":"son","race":"Nord","born":201.4}
```

```json
{"known":1,"role":"mother","count":2,"children":[{"name":"Toryy","father":"Haruk",...}]}
```

`kinship_is_child(actorUUID)` and `kinship_is_parent(actorUUID)` return the
strings `"1"` / `"0"` for cheap prompt guards.

**Ints, never JSON booleans.** A hand-written lowercase `true` does not survive
Papyrus compilation — strings intern case-insensitively, so the literal folds to
whatever casing holds the slot and can ship as `True`, which is not valid JSON.
One bad token makes *every* `kin.*` field undefined at once, silently. This is a
deliberate departure from the spec's `{"known":false}`.

**Decorators only resolve for the current speaker or target.** Never call
`get_kinship` inside a `get_nearby_npc_list` loop — it returns null there and
SkyrimNet throws `json.exception.type_error.302`.

That limit also excludes **`transform` render mode**, which is why the
submodule's `render_mode` guard omits it. Measured on the live save, same NPC,
same conversation:

```
KINDEBUG actor=Toryy known=1     role=child mode=full
KINDEBUG actor=Toryy known=UNDEF role=UNDEF mode=transform
```

`UNDEF` rather than `0` is the tell — `0` would mean the decorator ran and said
"nothing recorded", while `UNDEF` means the field was absent entirely and the
decorator never resolved. Rendering there produced nothing anyway; all it added
was a failing lookup on every dialogue transformation, degrading silently to
blank because of the `default()` guards.

---

## Storage

| Where | What | Why |
|---|---|---|
| `StorageUtil.json` co-save | Ints, Floats, Forms only | these survive a save reload |
| `StorageUtilData/SNKin_Parentage.json` | every string | StorageUtil **strings do not survive a reload** — this cost the sibling Romantasy mod its entire disposition history before it was found |

Children are keyed by their position in **our own roster** — a list we only ever
append to. Not FMR's index, because `PlayerChildRemove` shifts every later entry
down; and not anything derived from the name, for the reason below.

### Why nothing here decomposes a string

Schema 1 built the record key by walking the child's name character by
character — uppercase it, keep only `A-Z0-9`. On the first live save that
produced keys that were lossy and case-scrambled:

| Name | Key it produced |
|---|---|
| `Nicollette` | `colLETTE` |
| `Toryy` | `toYY` |
| `Ragnar` | `aa` |
| `Rognir` | `O` |
| `Inga` | `A` |

The letters **B, G, I, N, P and R** were dropped everywhere, independent of
position. The names themselves round-tripped through the same JsonUtil store
perfectly — `child.a.name` really was `"Inga"` — so the corruption lived
entirely in the per-character rebuild. It is consistent with the
case-insensitive string-table folding this stack is already scarred by, but the
exact mechanism was never pinned down from outside the game.

It did not need to be. Schema 2 removed the character loop and `Upper()`
entirely: keys are integers and names are only ever copied whole. **Do not
reintroduce a character loop without testing its output against a real name in
a live save first.**

The store carries a `schema` value; a mismatch wipes and rebuilds it from FMR
on the next sweep. Everything in it is regenerable except a mother entered by
hand, so the migration is safe as long as it runs before any exist.

---

## Scope

Deliberately **not** part of SkyrimNet-Romantasy Integration: different
dependencies, different audience, and that mod excludes children on purpose.
Kinship exposes a decorator instead, which Romantasy, AgencyEngine or anything
else can consume as a soft dependency without taking on Fertility Mode.

It does **not** enroll children in any romance system, modify Fertility Mode's
scripts, or write to SkyrimNet's SQLite database.

---

## Licence

[MIT](LICENSE) — covering **this mod's own code**: the `SNKin_*` Papyrus
scripts, the SKSE panel under `SKSE_Source/src`, the `0340_kinship.prompt`
submodule, and the tooling.

It does **not** cover the dependencies, which are each under their own terms
and are deliberately **not redistributed here**. Four headers are vendored
locally so this code can compile against their types, and all four are
gitignored:

| File | Comes from |
|---|---|
| `SkyrimNetApi.psc` | SkyrimNet |
| `_JSW_BB_Storage.psc` | Fertility Mode Reloaded |
| `UILIB_1.psc` | SkyUILib, shipped with Fertility Mode Reloaded |
| `SKSEMenuFramework.h` | SKSE Menu Framework |

[`docs/BUILD_DLL.md`](docs/BUILD_DLL.md) says where to obtain each. A first
build therefore needs those mods installed — a slightly worse setup experience,
and the correct position on other people's work.
