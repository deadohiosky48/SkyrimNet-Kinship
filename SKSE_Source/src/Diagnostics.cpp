#include "Diagnostics.h"

#include "PCH.h"
#include "Store.h"

#include <cstdint>

namespace Kinship::Diagnostics {

    namespace {

        // The running package, reached defensively.
        //
        // An actor only has a current package while it has a live AI process,
        // and an unloaded actor has none - which is not a failure, it is the
        // answer to a different question and has to be reported as such rather
        // than as "no package".
        RE::TESPackage* RunningPackage(RE::Actor* a_actor, bool& a_hadProcess) {
            a_hadProcess = false;
            if (!a_actor) {
                return nullptr;
            }
            // GetActorRuntimeData(), not the bare member. CommonLibSSE-NG
            // builds against several runtimes whose Actor layouts differ, so
            // currentProcess lives behind a versioned accessor; touching it
            // directly does not compile in an NG build.
            auto* proc = a_actor->GetActorRuntimeData().currentProcess;
            if (!proc) {
                return nullptr;
            }
            a_hadProcess = true;
            return proc->GetRunningPackage();
        }

        std::string Describe(RE::TESForm* a_form) {
            if (!a_form) {
                return "none";
            }
            std::string out = std::format("0x{:08X}", a_form->GetFormID());
            // EditorIDs are stripped from the runtime unless something caches
            // them; po3's Tweaks does, and is present in most load orders. An
            // empty answer is not an error, it just means the form id has to
            // carry the identification on its own - which it can.
            const auto edid = a_form->GetFormEditorID();
            if (edid && *edid) {
                out += " ";
                out += edid;
            }
            // Which FILE the form came from is the single most useful fact
            // here: it names the mod responsible without any guesswork.
            if (auto* file = a_form->GetFile(0); file && file->GetFilename().data()) {
                out += " [";
                out += file->GetFilename();
                out += "]";
            } else if ((a_form->GetFormID() & 0xFF000000) == 0xFF000000) {
                out += " [dynamic/runtime]";
            }
            return out;
        }

        std::string CellOf(RE::TESObjectREFR* a_ref) {
            if (!a_ref) {
                return "";
            }
            if (auto* cell = a_ref->GetParentCell()) {
                return std::string(cell->GetName() ? cell->GetName() : "");
            }
            return "";
        }
    }

    std::string DumpPackages() {
        Store::RefreshIfChanged();

        int seen = 0;
        int noBody = 0;
        int unloaded = 0;

        SKSE::log::info("================ package diagnostic ================");
        for (const auto& c : Store::Children()) {
            if (!c.hasBody) {
                ++noBody;
                continue;
            }
            // refId is stored as a signed int by Papyrus, which has no unsigned
            // type; the top bit of a 0xFF dynamic form id therefore arrives
            // negative. Mask back to 32 bits rather than sign-extending.
            const auto id = static_cast<RE::FormID>(
                static_cast<std::uint32_t>(c.refId));
            auto* form = RE::TESForm::LookupByID(id);
            auto* actor = form ? form->As<RE::Actor>() : nullptr;
            if (!actor) {
                SKSE::log::info("  {:<14} refId 0x{:08X} does not resolve to an actor",
                                c.name, id);
                continue;
            }
            ++seen;

            bool hadProcess = false;
            auto* pkg = RunningPackage(actor, hadProcess);
            if (!hadProcess) {
                ++unloaded;
            }

            const auto pos = actor->GetPosition();
            SKSE::log::info("  {:<14} pkg {:<52} {} at {:.0f},{:.0f},{:.0f} cell '{}'",
                            c.name,
                            hadProcess ? Describe(pkg) : std::string("(no AI process - unloaded)"),
                            c.home.empty() ? "home:none" : "home:" + c.home,
                            pos.x, pos.y, pos.z,
                            CellOf(actor));

            // WHAT THE PACKAGE IS ACTUALLY ANCHORED TO.
            //
            // DefaultSandboxLinkCustom02512 sandboxes at the actor's LinkCustom02
            // linked reference, so the package winning the stack proves nothing on
            // its own - a correct package on a wrong anchor parks the child in the
            // wrong place just as firmly. Ten children turned up on this package
            // standing within two units of each other despite living in five
            // different houses, which is only explicable by the link, and the link
            // was the one thing the log did not report.
            if (auto* kw = RE::TESForm::LookupByID<RE::BGSKeyword>(0x0005D5E7)) {
                auto* anchor = actor->GetLinkedRef(kw);
                if (anchor) {
                    const auto apos = anchor->GetPosition();
                    SKSE::log::info("                 -> linked to {} at {:.0f},{:.0f},{:.0f} cell '{}'",
                                    Describe(anchor), apos.x, apos.y, apos.z, CellOf(anchor));
                } else {
                    SKSE::log::info("                 -> NO LinkCustom02 anchor");
                }
            }
        }
        SKSE::log::info("  {} with a body, {} of those unloaded, {} without a body",
                        seen, unloaded, noBody);
        SKSE::log::info("====================================================");

        return std::format("{} child(ren) inspected, {} unloaded - see SkyrimNetKinship.log",
                           seen, unloaded);
    }
}
