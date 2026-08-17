# Building `SNKin_Integration.esp` in the Creation Kit

One quest, one alias, no masters beyond vanilla. About ten minutes.

**This is the only part of the mod that cannot be built from the command line.**
Everything else — scripts, prompt, manifest, settings — is already compiled and
deployed. Until this plugin exists there is no quest to host `SNKin_Bridge`, so
nothing runs at all.

The plugin is deliberately tiny: the bridge resolves Fertility Mode's storage
quest at runtime with
`Game.GetFormFromFile(0x0D62, "Fertility Mode.esm")` behind a
`Game.GetModByName` guard, so **Fertility Mode is not a master** and the plugin
loads (inert, decorator answering `known:0`) without it. Nothing else
references a foreign form.

---

## Step 0 — put the scripts where CK can see them

CK reads compiled `.pex` to discover a script's properties.

Copy from the repo into your **game Data folder**:

| From | To |
|---|---|
| `Scripts\SNKin_Bridge.pex` | `Data\Scripts\` |
| `Scripts\SNKin_PlayerAlias.pex` | `Data\Scripts\` |

*(The deploy step has already done this — see `tools\deploy.ps1`.)*

**Copy the `.pex` only — do NOT copy our `.psc` into `Data\Scripts\Source`.**
That folder is on the Papyrus compiler's import path, so a stale copy there
will **shadow the build**: the compiler resolves the script name from the copy
instead of the file it was handed and emits a `.pex` that silently does not
match source. It compiles cleanly and reports success.

> If CK cannot find `SNKin_Bridge` in the script list at Step 3, this is why.

---

## Step 1 — new plugin

1. Launch **CreationKit.exe**.
2. **File → Data…**
3. Tick **Skyrim.esm ONLY.**

   Not the DLC, not `Fertility Mode.esm`, not `SkyrimNet.esp`. This plugin
   references exactly two things — a new quest and `PlayerRef` — and
   `PlayerRef` lives in `Skyrim.esm`. Loading `Fertility Mode.esm` here risks
   putting an unwanted master on the plugin, which would make Kinship a hard
   dependency and defeat the soft-dependency design.

4. Do **not** set an active file. Click **OK**.
5. Expect a couple of minutes and a pile of warnings. Dismiss them.

> **If a "File in use" dialog appears** naming a path in the *game root* rather
> than `Data\`, with an elapsed-time counter and only a **Cancel** button: that
> is CK's version-control checkout prompt polling a path that does not exist.
> It will wait forever. If the status bar reads "Finished validating forms",
> the load already completed and **Cancel** simply dismisses it.

---

## Step 2 — create the quest

1. **Object Window** → **Character → Quest**.
2. Right-click in the list → **New**.
3. Set:
   - **ID**: `SNKin_Kinship`
   - **Quest Name**: *leave empty* — otherwise it appears in the player's journal
   - **Priority**: `0`
   - ✅ **Start Game Enabled**
   - ❌ **Run Once** — must stay unchecked, or it will not restart
4. Leave every other tab alone. No stages, no objectives — this quest exists
   only to host a script.

> The ID matters: `SetParentage` is dispatched by quest editor ID over the web
> API, and `SNKin_Kinship` is the name used in the README's examples.

---

## Step 3 — attach the bridge script

> **Create the quest first, THEN attach the script.** Filling in the quest and
> attaching a script in one pass before the first OK has been observed to crash
> CK 1.6.1378.1 on save. Two passes works.

1. Reopen `SNKin_Kinship`.
2. **Scripts** tab → **Add** → choose the existing `SNKin_Bridge` (not
   *[New Script]*).
3. **There are no properties to fill.** The script deliberately declares none.
   If CK prompts you for a property value, you have attached the wrong script.
4. **OK** to save the quest.

---

## Step 4 — the player alias

This alias is not optional garnish. Decorator and ModEvent registrations do
**not** survive a save/load, and a Quest script never receives
`OnPlayerLoadGame` — it is an Actor/alias event only. Without this alias the
mod works until the first reload and then silently stops noticing births.

1. Reopen `SNKin_Kinship` → **Quest Aliases**.
2. Right-click → **New Reference Alias**.
3. Set:
   - **Alias Name**: `PlayerAlias`
   - **Fill Type**: **Unique Actor** → **Player**
     *(**Forced Reference → PlayerRef** also works.)*
   - ❌ **Optional**
4. In that alias window's **Scripts** box: **Add** → `SNKin_PlayerAlias`.
5. **No properties to fill** — the alias finds the bridge through
   `GetOwningQuest()`.
6. **OK** out of the alias, then **OK** out of the quest.

---

## Step 5 — save

1. **File → Save** (there is no *Save As…*; with no active file set, plain
   Save prompts for a filename — that is how a new plugin is created).
2. Filename: `SNKin_Integration.esp`
3. It writes to your game `Data` folder.

> Clicking **OK** in the quest dialog commits the record in memory only. Until
> File → Save, nothing exists on disk.

---

## Step 6 — flag it ESL (optional, recommended)

**Do this BEFORE loading a save with the plugin active.** Flagging ESL moves
the plugin out of the normal load order into `FE:xxx` space, which changes
every record's runtime FormID — `XX000D62` becomes `FExxxD62`. A save that
already recorded the old one orphans that quest instance. The fallout here is
mild (the quest is Start Game Enabled so a fresh one starts, and the parentage
store is a file on disk keyed by *actor* FormIDs, so nothing is lost), but it
leaves a dead script instance in the save for no reason.

- **In CK:** **File → Convert Active File to Light Master**.
- **In xEdit:** select the plugin, expand **File Header** → **Record Header** →
  **Record Flags**, and tick **ESL**. Then `Ctrl+S`.

  > Older SSEEdit builds had a right-click **Add ESL flag to plugin**. Current
  > xEdit does not — right-click only offers **Compact FormIDs for ESL**, which
  > is a different and unnecessary operation here. The Record Flags checkbox is
  > the canonical route.

**No compaction needed.** ESL requires every new record to sit in
`0x800`–`0xFFF`. This plugin contains exactly one new record — the quest, at
local FormID `0x000D62` — which is inside that range. If you ever add records
and CK pushes one past `0xFFF`, *then* Compact FormIDs becomes relevant.

To confirm the flag landed, the TES4 header's Record Flags should read
`0x00000200`.

*(The quest's `0x000D62` happening to match Fertility Mode's handler quest ID
is coincidence. FormIDs are per-plugin and nothing resolves ours by ID —
`SetParentage` is dispatched by the quest's editor ID, `SNKin_Kinship`.)*

---

## Step 7 — verify before playing

**Restart the game fully.** A save reload reuses cached scripts; only a full
restart picks up new `.pex`.

Console:

```
help SNKin_Kinship 4
```

You should get a form ID. Then:

```
sqv SNKin_Kinship
```

Expect the quest **Running** with the alias filled by the player.

Then check `Data\SKSE\Plugins\SkyrimNet Kinship\logs\snkin.log` for:

```
Bridge ready. FMR storage resolved. Watch armed (0.5h).
First sweep: seeding existing children with the player as father.
```

If instead you see *"Fertility Mode Reloaded not found - kinship inert"*, the
plugin is running correctly but cannot see FMR — check load order.

If the log file does not exist at all, the quest is not running: re-check
**Start Game Enabled** and that **Run Once** is unchecked.

---

## Common failure modes

| Symptom | Cause |
|---|---|
| `SNKin_Bridge` missing from the script list | Step 0 skipped — `.pex` not in `Data\Scripts` |
| Quest never starts | **Start Game Enabled** unticked, or **Run Once** ticked |
| Works once, dead after reload | Alias missing, wrong fill type, or script not attached to it — that alias is the only thing re-registering decorators and ModEvents |
| CK refuses to save, complains about masters | A form from `Fertility Mode.esm` got referenced; nothing in this plugin should reference it |
| Log says ready, but no children recorded | Seeding was off (`kinSeedExisting: false`) when first run — existing children were added to the `ignored` list permanently |
