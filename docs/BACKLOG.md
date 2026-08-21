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

---

## Planned for 2.0

### Store parents as plugin + local FormID, not a runtime FormID

**The current model breaks silently on any load order change**, and it has
already happened on the development save.

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

Migration has to be lenient. A stale ESL FormID cannot be decoded after the fact
- the index it referred to is gone - so existing records convert only where the
FormID still resolves, and the rest fall back to the stored name, which is what
`RepairParentIds` already does.

### Life stages

See the design discussion: stages are data rather than geometry, gated behind a
config flag that is off by default, with the published Papyrus contract frozen
across the whole rewrite.

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
