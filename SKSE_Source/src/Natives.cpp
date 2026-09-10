#include "Natives.h"

#include "PCH.h"

namespace Kinship::Natives {

    namespace {

        constexpr auto kScript = "SNKin_Native";

        // Sets a linked reference, the one thing Papyrus cannot do.
        //
        // WRITTEN THROUGH ExtraLinkedRef, which is where the engine keeps them:
        // a small array of (keyword, reference) pairs on the source reference's
        // extra data. GetLinkedRef reads exactly this, so a link written here is
        // indistinguishable from one placed in the Creation Kit - which is what
        // makes the read-back verification in SNKin_Bridge meaningful.
        //
        // A null target REMOVES the entry rather than storing a null, because a
        // package that resolves its anchor to nothing behaves worse than one
        // with no anchor at all: the actor stands still wherever it happens to
        // be instead of falling through to the next package.
        void SetLinkedRef(RE::StaticFunctionTag*,
                          RE::TESObjectREFR* a_ref,
                          RE::TESObjectREFR* a_target,
                          RE::BGSKeyword*    a_keyword) {
            if (!a_ref) {
                return;
            }

            auto& extra = a_ref->extraList;
            auto* linked = extra.GetByType<RE::ExtraLinkedRef>();
            if (!linked) {
                if (!a_target) {
                    return;   // nothing stored, nothing to clear
                }
                linked = new RE::ExtraLinkedRef();
                extra.Add(linked);
            }

            // Replace an existing entry for this keyword rather than appending a
            // second one. The engine reads the FIRST match, so a duplicate would
            // silently pin the actor to whichever link was written earliest -
            // exactly the stale-anchor bug this whole feature exists to avoid.
            for (std::uint32_t i = 0; i < linked->linkedRefs.size(); ++i) {
                if (linked->linkedRefs[i].keyword == a_keyword) {
                    if (a_target) {
                        linked->linkedRefs[i].refr = a_target;
                    } else {
                        linked->linkedRefs.erase(&linked->linkedRefs[i]);
                    }
                    return;
                }
            }

            if (a_target) {
                RE::ExtraLinkedRef::LinkedRef entry{ a_keyword, a_target };
                linked->linkedRefs.push_back(entry);
            }
        }
        // The race a vampire race is built on, or None.
        //
        // RNAM, the "armor parent". It exists so a vampire can wear the same
        // armour as the race they were turned from, which means every sane
        // vampire race - vanilla or modded - points at its base. That is a far
        // better bet than pattern-matching an EditorID for "Vampire", which is
        // what a script would otherwise be reduced to.
        //
        // Returns None rather than the race itself when there is no parent, so
        // the caller can tell "no vampire relationship" from "already a base
        // race" without comparing forms.
        RE::TESRace* GetParentRace(RE::StaticFunctionTag*, RE::TESRace* a_race) {
            if (!a_race) {
                return nullptr;
            }
            auto* parent = a_race->armorParentRace;
            return (parent && parent != a_race) ? parent : nullptr;
        }
    }

    void Register(const SKSE::PapyrusInterface* a_papyrus) {
        if (!a_papyrus) {
            return;
        }
        a_papyrus->Register(+[](RE::BSScript::IVirtualMachine* a_vm) {
            a_vm->RegisterFunction("SetLinkedRef", kScript, SetLinkedRef);
            a_vm->RegisterFunction("GetParentRace", kScript, GetParentRace);
            SKSE::log::info("Registered {}.SetLinkedRef and .GetParentRace", kScript);
            return true;
        });
    }
}
