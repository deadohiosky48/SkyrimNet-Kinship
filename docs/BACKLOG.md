# Backlog

Deferred deliberately. Ordered by what blocks a release.

---

## Migrate the UI to SKSE Menu Framework

**The intended direction, deferred until kinship associations are proven
end-to-end.** UILIB_1 lists work — the picker opened and navigated correctly on
2026-08-15 — but they are a chain of modal list prompts, which is a poor shape
for a job that is really "browse a table of children and fill in the blanks".
An ImGui panel showing every child and both parents at once, with search, is
the right interface for this. Lover's Ledger is the working precedent:
`LoversLedger.dll` is storage only, and its UI is SKSE Menu Framework.

What that migration costs, so it is decided with open eyes:

- **A C++ SKSE plugin.** SKSE Menu Framework ships no Papyrus scripts — only a
  DLL, ini, pdb and JSON — so registering a menu is a C++ API call. There is no
  Papyrus route in.
- **A toolchain that does not exist on this machine.** No CMake, no MSVC, no
  vcpkg, no Visual Studio. That is Build Tools plus CommonLibSSE-NG plus vcpkg
  before a line of mod code.
- **A per-runtime maintenance burden** that the current all-Papyrus build does
  not have.

The data model is already UI-agnostic: `SNKin_Bridge` exposes Globals
(`SetParentStatic`, `SetParentByIdStatic`, `ChildIndex`, `ParentPath`) and the
store is JSON on disk, so a new front end replaces `SNKin_Picker` only. Keep it
that way — nothing UI-shaped should leak into the bridge.

## Let players remap the hotkey

**Superseded in part by the above** — a Menu Framework panel would own its own
binding. Kept because the hotkey must survive whatever the UI turns out to be.

Today the key lives in SkyrimNet's own config (`kinHotkey` / `kinHotkeyModifier`)
and is read at `Bootstrap`. That is fine for development — it needs no extra
dependency and can be re-armed live by calling `RegisterHotkey` over the web API
— but it is a poor answer for a released mod, where players expect to rebind
from a menu.

Two constraints that any implementation has to respect, both learned the hard
way and neither obvious:

1. **A modifier does NOT consume the base key.** `kinHotkeyModifier` is only
   checked inside our own `OnKeyDown`; whatever else owns the base key still
   receives the press. LAlt+K was chosen on the assumption that a chord could
   not collide, and it collided immediately because K was already taken. A
   remap UI must therefore help the player find a *genuinely free* key rather
   than implying a chord makes a taken one safe.

2. **The MCM page may never render.** SkyUI's mod registry is a Papyrus array
   capped at 128 entries. On a load order at that ceiling the menu registers and
   never displays — and MCM Helper's own keybind can then never be bound,
   because binding happens on the page that will not open. NPC Renamer
   (`_CV_NPCRenamer`) hit this and had to keep a direct `RegisterForKey`
   fallback regardless.

So the shape is: keep the direct registration as the source of truth, and let
an MCM *edit the value* rather than own the binding. Anything that makes the
key depend on the page rendering will fail on exactly the load orders this mod
is aimed at.

Note `MCM_ConfigBase.psc` is not on disk anywhere — it ships inside
`MCMHelper.bsa`, so building an MCM script means sourcing that header first.

---

## Untested paths

- **The picker's WRITE path.** The menu renders and navigates (confirmed
  2026-08-15, `UILIB_1.ShowList` works), but no assignment made through it has
  reached the store yet. The one recorded mother came from
  `RecoverMotherByRecentBirth`, not from the UI. Until a picker-driven
  `SetParent` line appears in `snkin.log`, that path is unproven.
- **Parent-side rendering.** Sapphire is the first parent ever recorded, so
  `## Your Child` has never produced output.
- **The father side.** No NPC father has been recorded yet, so the symmetry
  work in schema 3 is unexercised in play. Needs a female-player save, or a
  father assigned by hand.
- **Automatic end-to-end capture.** Wylandriah's pregnancy is the first watched
  from conception; nothing has yet gone conception → labor → maturation →
  recorded mother without intervention.

---

## Known gaps, accepted

- **Runa and Marcia have no recoverable mothers.** Both were recorded under the
  old build, before the `CurrentFather` fix, so no labour was ever captured for
  them. Confirmed unrecoverable by `DumpMothers` on 2026-08-15: identifying a
  just-named child's mother requires the signature `lastBirth > 0` with
  `babyAdded == 0`, and **no tracked actor shows it** — their mothers have
  either been auto-removed from tracking or conceived again, which resets
  `lastBirth` to 0. Assign by hand if known.

- **A wrong answer was written and withdrawn.** `RecoverMotherByRecentBirth`
  assigned Sapphire to Marcia. It searched around *now*, but a child named now
  was born `BabyDuration` days earlier, so it compared opposite ends of a
  ten-day pipeline; Sapphire was still carrying her own baby at the time. Fixed
  by `RecoverMotherByBirthAge`, undone with `ClearParent`. Worth remembering
  that the automatic path recorded nothing for either child — every wrong
  answer in this episode came from the bolted-on heuristic, not the pipeline.
- **`child.N.race` is always empty.** FMR's `PlayerChildRace` array is short on
  this save. Cosmetic; the prompt does not use it.
- **The 23 seeded children cannot have mothers recovered.** FMR never stored the
  link. This is the original diagnosis, not a regression.
