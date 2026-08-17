# Backlog

Deferred deliberately, plus an honest record of what has and has not been
exercised in play.

---

## Verified in play

Each of these was confirmed against a live save rather than reasoned about.

- **Automatic capture, end to end.** Conception → labour → maturation →
  recorded mother, with no intervention. First done for Gaius (Jarl Elisif the
  Fair), then Geira (Aia Arria).
- **Both halves of the rendering.** A child's bio states its parents; a
  parent's bio states their children, singular and plural. Elisif volunteered
  her son's name and sex unprompted, from an open question that gave away
  neither.
- **The in-game picker.** Crosshair assignment writes through to the store and
  on into dialogue - Camilla Valerius' two children were assigned that way.
- **The SKSE panel.** Inline editing with staged Save, sourced from our own
  roster rather than Fertility Mode's.
- **Tie shortlists.** Danica Pure-Spring and Nilsine Shatter-Shield matured
  about a game minute apart; both children were recorded with a two-candidate
  shortlist rather than a guess.

## Not yet exercised

- **A female-player playthrough.** The storage model is parent-agnostic and an
  NPC father gets a FormID and a reverse index, but no save has actually run
  that way. This is the largest untested surface.
- **The timeline warning.** Records dated after the current save point are
  detected and offered for deletion; no real rewind has yet triggered it.
- **A second playthrough claiming its own store.** The per-save split works in
  principle - the first save claims the existing file, later ones get their own
  - but only one save has ever claimed.

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

- **Six children have no recoverable mother.** Runa, Marcia, Titus and Leif
  were recorded by builds that predated the `CurrentFather` fix, so no labour
  was ever captured for them; Brennen and Yrsa lost their shortlists to an
  early version of the panel that deleted candidates on assignment. All are
  fixable by hand and none is recoverable automatically.
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
