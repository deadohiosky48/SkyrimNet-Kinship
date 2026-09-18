# Backlog

Deferred deliberately, plus an honest record of what has and has not been
exercised in play.

Findings below come from a development save. They are described by mechanism
rather than by character, because the mechanism is the part that generalises.

---

## Verified in play

Each of these was confirmed against a live save rather than reasoned about.

- **Automatic capture, end to end.** Conception → labour → maturation →
  recorded mother, with no intervention at any step. Repeated across separate
  births.
- **Both halves of the rendering.** A child's bio states its parents; a
  parent's bio states their children, singular and plural. In the strongest
  case a mother volunteered her child's name and sex unprompted, from an open
  question that gave away neither — the record reached her persona, not just
  the transcript.
- **The in-game picker.** Crosshair assignment writes through to the store and
  on into dialogue.
- **The SKSE panel.** Inline editing with staged Save, sourced from our own
  roster rather than Fertility Mode's.
- **Tie shortlists.** Two mothers matured about a game minute apart; both
  children were recorded with a two-candidate shortlist rather than a guess.
  This is the failing-closed rule doing exactly its job.
- **The per-save split.** A second character claimed a store of their own; the
  original save kept the file it had already claimed. Both exist on disk.
- **The Papyrus contract closing a real fail-open.** One child had an actor in
  the world, had followed the player, and was absent from Fertility Mode's
  reference cache - so `SNKin_Bound` read 0 and always would have. She now
  reads `IsPlayerChild=1 Bound=0`, which is the whole reason the contract
  exists rather than reusing the binding flag.

## Not yet exercised

- **A female-player playthrough.** The storage model is parent-agnostic and an
  NPC father gets a FormID and a reverse index, but no save has actually run
  that way. This is the largest untested surface.
- **The timeline warning.** Records dated after the current save point are
  detected and offered for deletion; no real rewind has yet triggered it.
- **The schema migration lock.** Shipped in 1.4.0 to close a race between the
  several script instances that bootstrap together, and it has never run under
  an actual migration - the save it was verified on was already at schema 5 with
  a matching fingerprint, so the guard was never entered. Exercising it is
  cheap: toggle any small ESL off, load, then on and load again. That moves the
  plugin count, trips the fingerprint and runs the repair for real. The tell is
  a *single* `Load order changed` line rather than two.
## Diagnosed and fixed from a live birth

Two children, Decimus and Aulus, were recorded in one sweep with a shortlist
naming **neither** of the mothers who had just delivered. Three separate defects
were behind it, all now fixed.

**1. The tie was false, and the evidence to break it was being discarded.**
`SNKin_AwaitingAt` was stamped with `Utility.GetCurrentGameTime()` - the moment
the SWEEP ran, not the moment of birth. The sweep runs hourly, so every mother
noticed in one pass got an identical timestamp. Fenja Secret-Fire and Hermir
Strong-Heart delivered an hour apart (`BabyAdded` 181.5910 against 181.6342) and
were recorded as indistinguishable. Now stamped from her own `BabyAdded`, which
is the birth itself and separates them cleanly.

**2. Stale flags outranked the birth that was actually happening.**
`SNKin_Awaiting` is cleared on the success path and nowhere else, so a mother
whose child was assigned by hand stays flagged forever - and since the winner is
the EARLIEST awaiting, a stale flag always wins. Danica Pure-Spring and Nilsine
Shatter-Shield had been sitting flagged from an earlier birth; the tie was
computed among those two, and both new children got a shortlist that named
neither real mother. The picker could not have produced the right answer.
Flags now expire after a full baby duration plus slack.

**3. Concurrent sweeps doubled everything.** `_sweeping` is a member variable
and guards one instance against itself only - the same limitation `MigrateStore`
already documents. Every log line for that birth appeared twice, and the
three-entry shortlist was copied onto each child twice, giving six. The sweep
now takes the same process-wide lock the schema migration does.

The two affected children were repaired by hand. Nothing else on the roster was
touched by any of this.

---

## Shipped since this was written

### Durable form identity — done in 1.4.0

Kept below because the reasoning is still the reasoning, and because the
migration it describes is now something a user's save has already been through
rather than something planned.

**The old model broke silently on any load order change**, and it had already
happened on the development save.

A runtime FormID encodes the plugin's load order position in its top byte, and
for a light plugin the top *three* hex digits. Add or remove a plugin and every
ESL-sourced FormID shifts. Two hand-entered mothers - both `0xFE...` - became
unresolvable after an unrelated mod was removed and re-added. Every
vanilla-space mother on the same roster (`0x00...`) survived untouched, which is
exactly the signature.

Nothing was lost: the names are still stored, so the links are re-enterable by
hand. But a parent link that quietly stops resolving, with no error and no
warning, is the failure mode this mod exists to avoid.

The fix is to store what `GetFormFromFile` takes - the source plugin's filename
and the local FormID - and resolve at read time. That is load-order-independent
by construction. It applies to `motherId`, `fatherId`, `child.N.refId`, the
`parent.<id>.kids` reverse index and the `person.<id>` roster, so it is a schema
migration rather than a patch, and 2.0 is the moment to do it: before life-stage
data is layered on top of the same keys.

Migration had to be lenient. A stale ESL FormID cannot be decoded after the fact
- the index it referred to is gone - so existing records convert only where the
FormID still resolves, and the rest fall back to the stored name.

**What shipped**, schema 5: the source plugin is captured *while the form is
still alive*, a load-order fingerprint gates the repair pass, duplicates left by
earlier load orders are folded on name plus local ID, and the hotkey menu
carries a manual repair for the pure-reorder case a fingerprint cannot see.

On the development save: 219 people → 206, 13 duplicates folded, 0 orphaned,
and two genuinely different Kaylas plus two genuinely different Salonias
correctly kept apart, because a shared display name is never sufficient to
merge.

**One caveat carried forward.** Decoding a *dead* ESL FormID does not fail - it
returns a confidently wrong plugin. Three dead entries for one follower decoded
to `cowperktree.esp`, `companionsskillltree.esp` and `mawassets.esp`. Only a
round-trip diagnostic caught that before the migration was built on top of it.
Any future work that reads a FormID's plugin index must assume the same.

---

## Life stages — the remaining work

The record layer shipped in 1.3.0 and is complete: stages advance on a game-day
clock, evidence beats arithmetic where evidence exists, and both keys publish.
`kinStagesEnabled` ships **off**.

What is missing is everything downstream of the record. In dependency order:

### 1. Size children to their stage

**Skyrim has one child body for every age**, so toddler, child and adolescent
are visually identical - the one thing the record layer cannot show, and the
reason a stage is currently invisible no matter how well it is stored.

Scale is the only lever that needs no new assets, and it works here for a
specific reason: **the mesh being scaled is already a child's.** The usual
objection - that a child is not a small adult, head-to-body being roughly 1:4
at birth against 1:7.5 grown - applies to shrinking an *adult*, which reads as a
dwarf. Shrinking the child mesh interpolates inside a proportion set that is
already correct, and reads as a younger child.

`ObjectReference.SetScale`, **not** NiOverride, and the reason is where the
state lives. NiOverride's node transforms serialise into the **co-save** - the
same store that had to be rebuilt by hand after a deployment corrupted it, and
which does not follow the roster. `SetScale` is a property of the reference in
the main save. FMR reaches for NiOverride/NetImmerse itself but only on
`NPC Belly` and the breast nodes under its own key, and never touches
whole-actor scale, so there is nothing to collide with.

| Stage | Scale | Why |
|---|---|---|
| newborn, infant | — | no actor exists; FMR carries a baby *item* |
| toddler | 0.82 | |
| child | **1.00** | pinned: the busiest stage pays no artifacts at all |
| adolescent | 1.12 | |
| adult | 1.00 | restore path |

Every artifact of scaling - furniture alignment, foot sliding on an authored
stride - is proportional to the distance from 1.0, which is why the middle is
pinned and the neighbours stay close.

Four things that have to hold, all now implemented:

- **The baseline is write-once.** `child.N.baseScale` records the actor's own
  scale before it is ever touched, so repeated sweeps cannot compound.
- **Switching off puts it back.** `RefreshChildStage` visits the size even on
  its stages-disabled early return; otherwise a scaled child stays shrunk
  forever, changed by a setting that is no longer on.
- **Adult restores to full.** FMR's `SummonAdultChild` can re-use the same
  reference, and a scale left behind there is a permanently stunted adult.
- **Clamped to 0.5–1.5.** These are user-editable numbers and a typo of 0.082
  for 0.82 produces an actor that cannot path, cannot use furniture and may not
  be clickable.

Scaling does **not** affect `Actor.IsChild()`, which reads the race off the 3D -
so all the existing evidence logic is unaffected by anything done here.

**Deferred: per-child height variance.** `child.N.scaleVar` is already read and
defaults to 1.0; nothing writes it yet. It is multiplicative rather than
additive on purpose, so a tall toddler is still tall as an adolescent *and* as
an adult - stage 5's base is 1.0, so an adult's size becomes exactly their
variance and adult height variation falls out for free. Reserving the hook now
costs one lookup; retrofitting it later would mean revisiting every scale
already written.

### 1b. Take FMR's baby item — done, and the trigger fixed

> **The original trigger was circular and the feature did nothing.**
> `CheckBabyItem` ran from `RefreshChildStage`, which only visits children on
> the roster - and a child reached the roster only when FMR called
> `PlayerChildAdd`, from **inside** `CheckBabyGrowth`'s day-ten spawn branch.
> That is the event confiscation exists to prevent. Fixed by owning the birth
> (1c); recorded here because the shape of the mistake is worth keeping.

Fertility Mode's childhood is: baby armor, wait `BabyDuration`, spawn a child
NPC. Life stages are a different childhood and **the two cannot both be true** -
left alone, FMR matures the child on day ten while this mod still has it
recorded as an infant, and the player is looking at a walking child whose own
bio calls it a newborn.

`kinStageConfiscate` takes the item. Read out of FMR's source rather than
assumed: `CheckBabyGrowth` gates the entire spawn on

```papyrus
if (baby && ((now - Storage.BabyAdded[i]) as int) >= BabyDuration.GetValueInt())
```

where `baby` is whichever `BirthBabyRace` armor is found **in the inventory**.
No item, no spawn. The `EventLock` taken on entry is released unconditionally
at the end of the function, so exiting down that path cannot wedge FMR.

`BabyAdded` is cleared as well as the item removed. Without that, FMR's
`BabyAdded > 0` gate keeps `CheckBabyGrowth` running for that mother on every
poll forever - a full inventory scan and a `Debug.Trace` each pass, plus an
`FMR_BabyStatus` event every game day advertising a baby that will never grow.
`CheckInactiveConditions` only shields the mother while the baby is younger than
`BabyDuration`, so clearing it changes nothing that day ten would not.

Indexed by `TrackedActors.Find`, which is the convention at **every** FMR call
site including the player's - the `+1` on `BabyAdded.Length` is slack, not a
second convention. Guessing wrong here would zero a different mother's clock.

A **separate opt-in** from `kinStagesEnabled`, and off by default, because it
cannot be undone: turning it back off does not hand the baby back.

### 1c. Own the birth — done

**FMR registers a child at maturation, not at birth.** So suppressing that
registration means this mod must create the record itself, from the
`FertilityModeLabor` event it already listens to (`OnLabor`, which stamps
`SNKin_Awaiting`). Everything else follows from that.

| Piece | Today | After |
|---|---|---|
| Gender | FMR picks it at spawn, `Utility.RandomInt(0,1)` | this mod chooses and stores it at birth |
| Race index | FMR computes it | `_JSW_BB_Utility.GetRaceIndex(Race, bool, Actor)` - public, same handler quest `ResolveStorage` already reaches |
| Name | FMR prompts at spawn | prompt at birth, store on the record |
| The actor | FMR's `TrySpawnChild` | `PlaceActorAtMe(Storage.Children[2 * raceIndex + gender])` directly - `TrySpawnChild` randomises gender internally and cannot be steered |

**Spawn at the toddler transition, not at FMR's `BabyDuration`.** Stages 0-1
have no body by design; spawning at FMR's ten days puts a walking actor on a
child the record calls an infant, which is the contradiction this exists to
remove. Shorten the newborn and infant durations to get them sooner.

All three of the hazards identified up front are handled:

- **Prompt timing.** Labour fires wherever the mother is - mid-combat, or on
  the far side of Skyrim. The record takes a placeholder and raises
  `needsName`; `PromptPendingNames` asks one child per sweep, only outside
  menus and combat, and generates a name if declined so it never asks twice.
  A child is not given a body until it has a real name.
- **Double registration.** If confiscation ever fails, FMR still registers at
  day ten. `NoteNewChildren` now refuses to record a name while a claimed birth
  sits inside FMR's own `BabyDuration` window, and logs why. A duplicate child
  is far worse than a missing one - it renders as two people with no signal
  anywhere that they are the same.
- **Hearthfire adoption is explicitly out of scope.** Not emulated, not
  deferred - dropped. The mod supersedes it: any number of children, none of
  them frozen as permanent child actors. That trade is deliberate, and it
  removes the only reason to care whether the `SpawnedChild` keyword lives on
  the base.

  > **Half of this was answered later, and the half that was right is the half
  > that stayed.** EMULATING adoption is still dropped, for exactly these
  > reasons. TAKING OVER a child some other mod has already adopted shipped in
  > 1.9.0, because it is a different question: the child exists, the adoption
  > owns their home and their alias, and all this mod adds is the record, the
  > stage clock and the persona. It touches nothing the adoption is doing -
  > `SendChildHome` and `SetHomeHere` refuse outright for these children,
  > because an alias package outranks ours and the two children genuinely at
  > home on the development save were the two adopted ones.
  >
  > An adopted child is also the only population here whose reference is
  > PERSISTENT, so it is the one case where the succession in 1d could work as
  > designed rather than being blocked by a `0xFF` ref.

**Known risk, untested:** `PromptPendingNames` calls a modal `ShowTextInput`
from inside the sweep, so the sweep is blocked until the player answers.
Re-entry is already guarded, and the prompt fires at most once per birth, but
this is the least exercised path in the feature.

### 1d. Growing up, and the identity question it raises

With adoption gone, **children ageing out of the child body is the feature**,
not an edge case. Stage 5 currently only restores scale to 1.0, which would
leave a grown child as a normal-sized child. Two ways to give them an adult
body, and they differ in something that matters more than appearance:

**A new actor from `Storage.AdultChildren`** is what FMR does
(`SummonAdultChild`), and it is the straightforward implementation. But
SkyrimNet keys persona identity to the **reference FormID** - measured on this
save, `bio_template_name` derives from it (`lyra_611` from `0xFF00A611`). A new
reference means the grown child arrives with no memory of their own childhood
and none of the personality that accumulated during it. They share a name and a
parentage with the child who existed yesterday and nothing else.

**`Actor.SetRace()` on the existing reference** keeps the FormID, so everything
SkyrimNet holds survives the transition. The cost is appearance: face data is
race-specific, so the grown child gets close to the new race's default head and
the parent-matched hair colour has to be re-applied (`SetHairColor`, which FMR
already does at spawn). Likely needs a 3D reset to take.

A useful property either way: `IsChild()` reads the race off the 3D, so after a
race swap the existing "body beats the clock" logic agrees with the new reality
for free.

This is a values question rather than a technical one - whether a grown child is
the *same person* to the game - and it should be settled before either path is
built, because it is not cheaply reversible once children start growing up.

### 2. Carry the stage in the decorator payload - done

`ChildPayload` and `ParentPayload` do not emit a stage, so the prompt cannot ask
for one however it is written. Add the stage name and number, gated on
`StagesEnabled()` so the fields are absent when the feature is off and the
template's `default()` guards render nothing.

### 3. Render it - done

`0340_kinship.prompt` does not mention stages. The design constraint is the
same one the record layer already respects and a careless template would throw
away: **render disposition, never an age in years, and never a number.** A
toddler and an adolescent wear one body, so a bio asserting "you are three"
contradicts what the player can see.

Which implies stages do not all render alike:

- **newborn, infant** — parent's side only. No persona exists to render.
- **toddler, child, adolescent** — the child's side, as how they engage.
- **adult** — nothing new; the existing parentage block is already right.

Plasticity stays machine-facing. Telling a model "you are 70% malleable" is a
stat, not a character.

### 4. Correct a stage from the panel - done

**This was a defect, not unbuilt work, and it is now closed.** Two shipped surfaces already tell users
to do it - the `kinStagesEnabled` manifest description, and the runtime warning
in `RefreshChildStage` ("Correct it in the panel if that is wrong") - and the
control does not exist. `Store::Child` does not parse `stage`,
`KinshipPanel.cpp` has no stage column, and `SNKin_Picker.psc` contains the
string zero times.

The write path must call `PlantStage` rather than setting the value, or the
clock recomputes over it on the next sweep.

### Sequencing note

Size before rendering, and rendering before the panel. Size has an answer you
can *see* immediately, where prompt text has to be judged from LLM output; and
the panel should not be built for a feature that has not yet proved worth
having.

`kinStagesEnabled` stays **off by default** throughout. The backfill is a guess
about every existing child, and flipping the default would silently relabel
rosters that are currently correct.

### The cheapest available test

**Titus and Leif are engine-identical brothers** - same class, race and gender,
distinguished by nothing the engine renders. Planting one as toddler and the
other as adolescent isolates stage from every other variable, because there is
no other variable. If a stage does not visibly change how they play, that is
worth knowing before more is built on it.

---

## Let players remap the hotkey from a menu

Today the key lives in SkyrimNet's config (`kinHotkey` / `kinHotkeyModifier`)
and is read at `Bootstrap`. That is fine for development and a poor answer for
a released mod, where players expect to rebind from a UI.

Two constraints any implementation must respect, both learned the hard way:

1. **A modifier does NOT consume the base key.** `kinHotkeyModifier` is checked
   only inside our own `OnKeyDown`; whatever else owns the base key still
   receives the press. LAlt+K was chosen on the assumption a chord could not
   collide, and it collided immediately.
2. **An MCM page may never render.** SkyUI's mod registry is a Papyrus array
   capped at 128 entries. Past that a menu registers and never displays - and
   MCM Helper's own keybind can then never be bound, because binding happens on
   the page that will not open. NPC Renamer hit this and kept a direct
   `RegisterForKey` fallback regardless.

So the shape is: keep direct registration as the source of truth and let a UI
*edit the value*. Anything that makes the key depend on a page rendering will
fail on exactly the load orders this mod is aimed at.

The SKSE panel is the more natural home for it now that it exists.

---

## Known gaps, accepted

- **Children created before the fixes landed cannot be repaired
  automatically.** On the development save six of them: four predate the
  `CurrentFather` fix, so no labour was ever captured for them, and two lost
  their candidate shortlists to an early build of the panel that deleted
  candidates on assignment. All are fixable by hand in the panel. None is
  recoverable without it.
- **Every recovery path that reads Fertility Mode's arrays is on a timer.** FMR
  prunes a mother from tracking within game hours of her child maturing, and
  `lastBirth` resets entirely if she conceives again. The durable paths are the
  ones that do not depend on FMR still remembering: our own people roster, the
  crosshair, and the candidate shortlist once written.
- **`child.N.race` is always empty.** FMR's `PlayerChildRace` array is short on
  the save this was built against. Cosmetic; the prompt does not use it.
- **Fertility Mode reuses one actor for two children** that share a class, race
  and gender - `SpawnedChildActorRefs` is keyed by appearance archetype, not by
  child. `BindChildRef` refuses the second binding rather than giving one NPC
  two identities, so the second child simply stays unbound.
- **Forking cannot be disabled** on a public repository. That is inherent to
  public hosting, not a gap in the settings.
- **The exported flag and the records live in different places.**
  `SNKin_IsPlayerChild` is a StorageUtil value, so it lives in the co-save and
  follows save state; the roster is a JsonUtil file, so it is per-install and
  does not. Loading an earlier save reverts one and not the other. The sweep now
  re-stamps every child with a recorded reference, so the flag is durable after
  first contact - but a child who has never been resolved once still reads 0,
  and that is inherent to a push-model flag over a set that cannot be
  enumerated.
