#include "KinshipPanel.h"

#include "PCH.h"
#include "Diagnostics.h"
#include "PapyrusBridge.h"
#include "Store.h"

#include "../include/SKSEMenuFramework.h"

#include <cstring>
#include <cstdlib>

// ImGui is provided BY SKSEMenuFramework through its own namespace rather than
// linked directly - the framework owns the ImGui context and the render hook.
using namespace ImGuiMCP;
namespace ImGui = ImGuiMCP::ImGui;

namespace Kinship::Panel {

    namespace {
        char g_search[128] = "";
        bool g_onlyUnresolved = false;
        int g_pendingChild = -1;      // roster index awaiting a candidate choice
        float g_refreshAt = 0.0f;     // see NoteWrite

        bool Matches(const Store::Child& aChild) {
            if (g_onlyUnresolved && !aChild.NeedsMother()) {
                return false;
            }
            if (g_search[0] == '\0') {
                return true;
            }
            auto contains = [](const std::string& hay, const char* needle) {
                if (hay.empty()) return false;
                std::string h = hay, n = needle;
                for (auto& ch : h) ch = static_cast<char>(::tolower(ch));
                for (auto& ch : n) ch = static_cast<char>(::tolower(ch));
                return h.find(n) != std::string::npos;
            };
            return contains(aChild.name, g_search) ||
                   contains(aChild.motherName, g_search) ||
                   contains(aChild.fatherName, g_search);
        }

        // Papyrus dispatch is asynchronous, so refreshing the instant a command
        // is sent shows the OLD value and looks like the write failed. This is
        // the same latency that made me wrongly conclude the web API was dead.
        // Schedule a reload shortly after instead.
        void NoteWrite() {
            // GetTime returns double; the explicit cast keeps /W4 quiet.
            g_refreshAt = static_cast<float>(ImGui::GetTime()) + 1.0f;
        }

        // Defined below with the row editor; declared here so the add-child
        // form can reuse exactly the same dropdown rather than a second copy.
        void DrawParentCombo(const char* aLabel, int aWantSex, const char* aCurrentName,
                             std::int32_t& aStaged, char* aHexBuf, std::size_t aHexLen);

        // ---- timeline mismatch --------------------------------------------
        bool g_confirmDelete = false;

        // Children recorded after the current game time, i.e. from a future
        // abandoned by loading an earlier save.
        //
        // WARNS, NEVER ACTS. Loading an old save to check something and going
        // straight back is ordinary play, and silently deleting a family built
        // over days would be unrecoverable. Two clicks, and the second names
        // exactly what is destroyed.
        void DrawTimelineWarning() {
            std::vector<const Store::Child*> future;
            // Game time in DAYS, matching the units Papyrus writes into born.
            auto* cal = RE::Calendar::GetSingleton();
            const float nowish = (cal ? cal->GetCurrentGameTime() : 0.0f) + 0.01f;
            if (!cal) {
                return;   // no clock, no honest comparison
            }
            for (const auto& c : Store::Children()) {
                if (c.born > nowish) {
                    future.push_back(&c);
                }
            }
            if (future.empty()) {
                g_confirmDelete = false;
                return;
            }

            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.45f, 0.35f, 1.0f));
            ImGui::Text("%d record(s) are dated AFTER this save point",
                        static_cast<int>(future.size()));
            ImGui::PopStyleColor();
            ImGui::TextWrapped(
                "An earlier save was probably loaded. Nothing has been changed. If you are "
                "going back to a later save, keep them - these are not duplicates, they are "
                "the same children.");

            std::string names;
            for (const auto* c : future) {
                if (!names.empty()) names += ", ";
                names += c->name;
            }
            ImGui::TextWrapped("Affected: %s", names.c_str());

            if (!g_confirmDelete) {
                if (ImGui::SmallButton("Delete these records...")) {
                    g_confirmDelete = true;
                }
            } else {
                ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.45f, 0.35f, 1.0f));
                ImGui::TextWrapped(
                    "This permanently erases who these children's parents were. "
                    "It cannot be undone from a later save.");
                ImGui::PopStyleColor();
                if (ImGui::SmallButton("Yes, delete permanently")) {
                    PapyrusBridge::ForgetFutureChildren();
                    g_confirmDelete = false;
                    NoteWrite();
                }
                ImGui::SameLine();
                if (ImGui::SmallButton("Cancel")) {
                    g_confirmDelete = false;
                }
            }
            ImGui::Separator();
        }

        // ---- manual add ----------------------------------------------------
        char g_newName[64] = "";
        char g_newChildHex[16] = "";
        std::int32_t g_newMother = 0;
        std::int32_t g_newFather = 0;
        char g_newMotherHex[16] = "";
        char g_newFatherHex[16] = "";

        void DrawAddChild() {
            if (!ImGui::CollapsingHeader("Add a child by hand")) {
                return;
            }
            // The undo for every automatic path - including a deletion the
            // player regrets. Without it "permanently deletes" would have no
            // way back at all.
            ImGui::TextWrapped(
                "For a birth that was never captured, or to restore one you deleted. "
                "The child's FormID is optional: without it the parents still know about "
                "the child, but the child's own dialogue will not until the name is matched "
                "to a spawned actor.");
            ImGui::SetNextItemWidth(180.0f);
            ImGui::InputTextWithHint("##name", "child's name", g_newName, sizeof(g_newName));
            ImGui::SameLine();
            ImGui::SetNextItemWidth(90.0f);
            ImGui::InputTextWithHint("##kid", "child FormID", g_newChildHex, sizeof(g_newChildHex),
                                     ImGuiInputTextFlags_CharsHexadecimal);

            DrawParentCombo("newmother", 1, "", g_newMother, g_newMotherHex, sizeof(g_newMotherHex));
            DrawParentCombo("newfather", 0, "", g_newFather, g_newFatherHex, sizeof(g_newFatherHex));

            const bool ok = g_newName[0] != '\0';
            if (!ok) ImGui::BeginDisabled();
            if (ImGui::Button("Create record")) {
                const char* s = g_newChildHex;
                if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
                const auto kid = *s ? static_cast<std::int32_t>(
                                          static_cast<std::uint32_t>(std::strtoul(s, nullptr, 16)))
                                    : 0;
                PapyrusBridge::AddChild(g_newName, kid, g_newMother, g_newFather);
                g_newName[0] = '\0';
                g_newChildHex[0] = '\0';
                g_newMother = 0;
                g_newFather = 0;
                NoteWrite();
            }
            if (!ok) ImGui::EndDisabled();
            ImGui::Separator();
        }

        void DrawUnresolvedQueue() {
            const auto pending = Store::Unresolved();
            if (pending.empty()) {
                return;
            }

            // Led with, and coloured, because it is the only part of this panel
            // that is a QUESTION the game is waiting on rather than a record to
            // read. Everything else can be browsed at leisure.
            ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.75f, 0.3f, 1.0f));
            ImGui::Text("%d child%s waiting on a mother", static_cast<int>(pending.size()),
                        pending.size() == 1 ? "" : "ren");
            ImGui::PopStyleColor();
            ImGui::TextWrapped(
                "Two mothers whose babies matured in the same moment cannot be told apart, "
                "so the birth was recorded with a shortlist instead of a guess. Pick who bore each child.");
            ImGui::Separator();

            for (const auto* child : pending) {
                ImGui::PushID(child->index);
                ImGui::Text("%s", child->name.c_str());
                ImGui::SameLine();
                for (std::size_t i = 0; i < child->candidateIds.size(); ++i) {
                    const char* who = i < child->candidateNames.size()
                                          ? child->candidateNames[i].c_str()
                                          : "(unnamed)";
                    ImGui::SameLine();
                    if (ImGui::SmallButton(who)) {
                        PapyrusBridge::SetParentById(child->name, child->candidateIds[i], 0);
                        NoteWrite();
                    }
                }
                ImGui::PopID();
            }
            ImGui::Spacing();
        }

        // EVERY RECORDED DECISION IS EDITABLE, not just unanswered ones.
        //
        // The first version of this panel only offered buttons for children
        // with no mother, and cleared the shortlist the moment one was chosen.
        // A single misclick then put Yrsa on the wrong mother with no way back:
        // the information needed to correct the mistake had been deleted BY the
        // mistake. Assignments are now kept alongside their alternatives, and
        // anything set can be changed or cleared.
        // ---- inline row editing -------------------------------------------
        //
        // STAGED, NOT IMMEDIATE. The first version wrote on every click, so a
        // misclick was already committed before you noticed - which is how Yrsa
        // ended up on the wrong mother. Selecting now only stages a value;
        // nothing reaches the store until Save, and Cancel discards.
        //
        // NOTHING HERE NEEDS THE ACTOR LOADED. Assignment goes through
        // SetParentByIdStatic, which resolves the FormID with Game.GetFormEx -
        // that works for an NPC on the far side of Skyrim, asleep in a cell
        // nobody has visited. The crosshair is for introducing someone the
        // store has never heard of, not for editing.
        int g_editIndex = -1;              // roster index being edited, -1 = none
        std::int32_t g_editMother = 0;
        std::int32_t g_editFather = 0;
        int g_editStage = -1;
        char g_editName[64] = "";   // the child's name, editable in the row
        // Row index awaiting a second click before a body is spawned. -1 = none.
        int g_spawnConfirm = -1;
        // Two-step guard for the bulk move. Separate from g_spawnConfirm, which
        // is per-row and holds a child index rather than a flag.
        bool g_sendAllConfirm = false;
        std::string g_diagResult;

        // 0..5, matching SNKin_Bridge.StageName. Kept here rather than derived
        // so the panel cannot drift out of step with the Papyrus names.
        constexpr const char* kStageNames[] = {
            "newborn", "infant", "toddler", "child", "adolescent", "adult"
        };
        const char* StageLabel(int aStage) {
            if (aStage < 0 || aStage > 5) {
                return "-";
            }
            return kStageNames[aStage];
        }
        char g_motherHex[16] = "";
        char g_fatherHex[16] = "";
        char g_personFilter[96] = "";

        const char* NameForId(std::int32_t aId, const char* aFallback) {
            if (aId == 0) return (aFallback && *aFallback) ? aFallback : "(unknown)";
            for (const auto& p : Store::People()) {
                if (p.id == aId) return p.name.c_str();
            }
            // Recorded but not in the roster: show the stored NAME rather than
            // a placeholder, so the combo still reads as the current value.
            return (aFallback && *aFallback) ? aFallback : "(not in roster)";
        }

        std::int32_t IdForName(const std::string& aName) {
            if (aName.empty()) return 0;
            for (const auto& p : Store::People()) {
                if (_stricmp(p.name.c_str(), aName.c_str()) == 0) return p.id;
            }
            return 0;
        }

        // One dropdown, populated ONLY from our own roster. Never from FMR's
        // tracked list, which is pruned within game hours of a birth maturing
        // and took Camilla, Ganna, Danica and Nilsine with it.
        // aWantSex: 1 for a mother, 0 for a father. Entries whose sex is unknown
        // (-1) are ALWAYS offered - an old roster entry we could not resolve
        // should never become unselectable just because we failed to look it up.
        void DrawParentCombo(const char* aLabel, int aWantSex, const char* aCurrentName,
                             std::int32_t& aStaged, char* aHexBuf, std::size_t aHexLen) {
            ImGui::PushID(aLabel);
            ImGui::SetNextItemWidth(150.0f);
            if (ImGui::BeginCombo("##pick", NameForId(aStaged, aCurrentName))) {
                ImGui::SetNextItemWidth(-1.0f);
                ImGui::InputTextWithHint("##f", "filter", g_personFilter, sizeof(g_personFilter));

                if (ImGui::Selectable("(unknown)", aStaged == 0)) {
                    aStaged = 0;
                }
                for (const auto& p : Store::People()) {
                    if (p.sex != -1 && p.sex != aWantSex) {
                        continue;
                    }
                    if (g_personFilter[0] != '\0') {
                        std::string h = p.name, n = g_personFilter;
                        for (auto& ch : h) ch = static_cast<char>(::tolower(ch));
                        for (auto& ch : n) ch = static_cast<char>(::tolower(ch));
                        if (h.find(n) == std::string::npos) continue;
                    }
                    ImGui::PushID(p.id);
                    if (ImGui::Selectable(p.name.c_str(), aStaged == p.id)) {
                        aStaged = p.id;
                    }
                    ImGui::PopID();
                }
                ImGui::EndCombo();
            }

            // Escape hatch for anyone the roster has never seen - type a
            // reference FormID and press Enter. Without it the panel could only
            // offer people it already knows, and a brand new NPC would still
            // force a trip across Skyrim to use the crosshair.
            ImGui::SameLine();
            ImGui::SetNextItemWidth(70.0f);
            if (ImGui::InputTextWithHint("##hex", "FormID", aHexBuf, aHexLen,
                                         ImGuiInputTextFlags_CharsHexadecimal |
                                         ImGuiInputTextFlags_EnterReturnsTrue)) {
                const char* s = aHexBuf;
                if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
                if (*s) {
                    // Parsed unsigned then reinterpreted signed: Papyrus has no
                    // unsigned type, so 0xFE21C812 must travel as -31307758.
                    const auto u = static_cast<std::uint32_t>(std::strtoul(s, nullptr, 16));
                    aStaged = static_cast<std::int32_t>(u);
                }
            }
            ImGui::PopID();
        }

        // One parent slot: a filterable list of everyone we know, plus Clear.
        //
        // The list is OUR roster, not FMR's. Sourcing it from FMR's tracked
        // actors is what made Camilla, Ganna, Danica and Nilsine unpickable
        // once FMR pruned them - within game hours of their children maturing.
        // Ours only ever grows.

        void BeginEdit(const Store::Child& aChild) {
            g_editIndex = aChild.index;
            g_editMother = aChild.motherId;
            g_editFather = aChild.fatherId;

            // PRESELECT THE CURRENT VALUE even when only a NAME was recorded.
            //
            // Older records carry a parent's name with no FormID - every father
            // predating the fatherId fix is "Haruk" with an id of 0 - so the
            // dropdown opened on "(unknown)" for a parent that plainly is known.
            // Resolving the name against the roster makes the combo default to
            // what is actually recorded, and leaves it at 0 only when the parent
            // genuinely is unset.
            if (g_editMother == 0) {
                g_editMother = IdForName(aChild.motherName);
            }
            if (g_editFather == 0) {
                g_editFather = IdForName(aChild.fatherName);
            }
            g_editStage = aChild.stage;
            // Seeded with the current name, so an untouched Save dispatches
            // nothing and the player edits rather than retypes.
            std::strncpy(g_editName, aChild.name.c_str(), sizeof(g_editName) - 1);
            g_editName[sizeof(g_editName) - 1] = '\0';
            g_motherHex[0] = '\0';
            g_fatherHex[0] = '\0';
            g_personFilter[0] = '\0';
        }

        // Commits both slots. Only what actually CHANGED is dispatched, so
        // saving an untouched row is a no-op rather than a pile of redundant
        // writes and log lines.
        void SaveEdit(const Store::Child& aChild) {
            if (g_editMother != aChild.motherId) {
                if (g_editMother == 0) {
                    PapyrusBridge::ClearParent(aChild.name, 0);
                } else {
                    PapyrusBridge::SetParentById(aChild.name, g_editMother, 0);
                }
            }
            if (g_editFather != aChild.fatherId) {
                if (g_editFather == 0) {
                    PapyrusBridge::ClearParent(aChild.name, 1);
                } else {
                    PapyrusBridge::SetParentById(aChild.name, g_editFather, 1);
                }
            }
            // ONLY ON A REAL CHANGE. Sending the current value back would still
            // re-plant the stage and reset the aging stamp, quietly restarting
            // the child's progress through a stage every time anyone opened the
            // row and saved without touching it.
            if (g_editStage != aChild.stage && g_editStage >= 0) {
                PapyrusBridge::SetChildStage(aChild.name, g_editStage);
            }
            // LAST, because every call above addresses the child BY NAME. Rename
            // first and those would be looking for a child that no longer exists
            // under that name, and would silently do nothing.
            if (g_editName[0] != '\0' && aChild.name != g_editName) {
                PapyrusBridge::RenameChild(aChild.name, g_editName);
            }
            g_editIndex = -1;
            NoteWrite();
        }

        void DrawTable() {
            constexpr auto flags = ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg |
                                   ImGuiTableFlags_ScrollY | ImGuiTableFlags_Resizable;
            if (!ImGui::BeginTable("kinship", 7, flags, ImVec2(0.0f, 420.0f))) {
                return;
            }
            ImGui::TableSetupColumn("Child");
            ImGui::TableSetupColumn("Relation");
            ImGui::TableSetupColumn("Mother");
            ImGui::TableSetupColumn("Father");
            ImGui::TableSetupColumn("Stage");
            ImGui::TableSetupColumn("Home");
            ImGui::TableSetupColumn("Edit");
            ImGui::TableSetupScrollFreeze(0, 1);
            ImGui::TableHeadersRow();

            for (const auto& c : Store::Children()) {
                if (!Matches(c)) {
                    continue;
                }
                const bool editing = (g_editIndex == c.index);
                ImGui::PushID(c.index);
                ImGui::TableNextRow();

                // THE ONE FIELD THAT HAD NO EDITOR until a child arrived that
                // the naming prompt had missed - "(unnamed 11)", with mother,
                // father and stage all correctable and the name not.
                ImGui::TableNextColumn();
                if (editing) {
                    ImGui::SetNextItemWidth(-FLT_MIN);
                    ImGui::InputText("##name", g_editName, sizeof(g_editName));
                } else {
                    ImGui::Text("%s", c.name.c_str());
                }
                ImGui::TableNextColumn();
                ImGui::TextUnformatted(c.gender.empty() ? "-" : c.gender.c_str());

                // An unknown parent is rendered as UNKNOWN, never blank. The
                // whole design refuses to guess a parent, so the interface
                // should show that refusal as a fact rather than as an empty
                // cell that reads like a rendering bug.
                ImGui::TableNextColumn();
                if (editing) {
                    DrawParentCombo("mother", 1, c.motherName.c_str(), g_editMother, g_motherHex, sizeof(g_motherHex));
                } else if (c.motherName.empty()) {
                    ImGui::TextDisabled("unknown");
                } else {
                    ImGui::Text("%s", c.motherName.c_str());
                }

                ImGui::TableNextColumn();
                if (editing) {
                    DrawParentCombo("father", 0, c.fatherName.c_str(), g_editFather, g_fatherHex, sizeof(g_fatherHex));
                } else if (c.fatherName.empty()) {
                    ImGui::TextDisabled("unknown");
                } else {
                    ImGui::Text("%s", c.fatherName.c_str());
                }

                // LIFE STAGE. The setting text and the runtime warning both
                // tell players to correct a stage here, which was a promise
                // with nothing behind it until now: a backfilled child is a
                // GUESS, because its recorded birth date is when this mod first
                // saw it rather than when it was born.
                ImGui::TableNextColumn();
                if (editing && c.stage >= 0) {
                    ImGui::SetNextItemWidth(-FLT_MIN);
                    if (ImGui::BeginCombo("##stage", StageLabel(g_editStage))) {
                        for (int s = 0; s <= 5; ++s) {
                            if (ImGui::Selectable(kStageNames[s], g_editStage == s)) {
                                g_editStage = s;
                            }
                        }
                        ImGui::EndCombo();
                    }
                } else if (c.stage < 0) {
                    // Not "newborn". Stages are off, or the sweep has not
                    // reached this child - either way we do not know, and
                    // guessing the youngest would be wrong for most of a roster.
                    ImGui::TextDisabled("-");
                } else {
                    ImGui::TextUnformatted(StageLabel(c.stage));
                }

                // WHERE THEY LIVE, AND LOUDLY WHEN THEY DO NOT.
                //
                // A child with no home is the case worth surfacing: "Send home"
                // silently declines for those, and without a column saying so
                // the button simply appears not to work. It happened on the live
                // save - one child whose mother had no home recorded either, and
                // nothing on screen explained why she stayed put.
                //
                // Read-only. The home belongs to SeverActions; this is a view of
                // it, copied into the store by the Papyrus side because the panel
                // cannot reach the co-save.
                ImGui::TableNextColumn();
                if (!c.hasBody) {
                    // No actor means nothing to ask about - not the same as
                    // having no home, and worth distinguishing.
                    ImGui::TextDisabled("-");
                } else if (c.home.empty()) {
                    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(1.0f, 0.65f, 0.35f, 1.0f));
                    ImGui::TextUnformatted("none");
                    ImGui::PopStyleColor();
                    if (ImGui::IsItemHovered()) {
                        ImGui::BeginTooltip();
                        ImGui::PushTextWrapPos(ImGui::GetFontSize() * 28.0f);
                        ImGui::TextUnformatted(
                            "No home is recorded for this child, so \"Send home\" has "
                            "nowhere to send them.\n\n"
                            "They inherit their mother's when she has one. If she has "
                            "none either, give her a home in SeverActions and press "
                            "\"Send home\" again.");
                        ImGui::PopTextWrapPos();
                        ImGui::EndTooltip();
                    }
                } else {
                    ImGui::TextUnformatted(c.home.c_str());
                }

                ImGui::TableNextColumn();
                if (editing) {
                    if (ImGui::SmallButton("Save")) {
                        SaveEdit(c);
                    }
                    ImGui::SameLine();
                    if (ImGui::SmallButton("Cancel")) {
                        g_editIndex = -1;   // discard; nothing was written
                    }
                } else {
                    if (ImGui::SmallButton("Edit")) {
                        BeginEdit(c);
                    }
                    // GIVE A BODY TO A CHILD THAT HAS NONE.
                    //
                    // Fertility Mode names a child and then waits for the player
                    // to send it to training or adopt it. Do neither and it stays
                    // a record forever - adoption is capped at two, and training
                    // is a one-way trip to adulthood. Thirty-six children were in
                    // that state on the save this was written for.
                    //
                    // Newborns and infants are excluded: they have no body in
                    // this model at all, and the Papyrus side refuses them too.
                    // stage < 0 means stages are off, and then there is no age to
                    // object to.
                    // BRING A CHILD THAT HAS A BODY TO THE PLAYER.
                    //
                    // The exact complement of the button below: that one exists
                    // because a child has no actor, this one because it has one
                    // and nobody knows where. A child is placed beside its
                    // mother or wherever the player stood, and then it is simply
                    // gone - not findable in the SkyrimNet UI either, because a
                    // spawned child is registered under Fertility Mode's base
                    // actor name until a character record is authored for it,
                    // and authoring one requires the actor in the crosshair.
                    //
                    // No confirmation step. Moving an existing reference is
                    // reversible by walking away, unlike placing a new NPC.
                    if (c.hasBody) {
                        ImGui::SameLine();
                        // EACH TOOLTIP IMMEDIATELY AFTER ITS OWN BUTTON.
                        //
                        // IsItemHovered reads the LAST SUBMITTED item, so a
                        // tooltip written further down does not belong to the
                        // button it was written for. Adding "Send home" between
                        // Summon and Summon's tooltip silently gave "Send home"
                        // BOTH tooltips and Summon none - the same trap caught
                        // once already on the "Give a body" button, and it is
                        // invisible in the source unless the order is read as
                        // strictly sequential, which is what ImGui is.
                        if (ImGui::SmallButton("Summon")) {
                            PapyrusBridge::SummonChild(c.name);
                            NoteWrite();
                        }
                        if (ImGui::IsItemHovered()) {
                            ImGui::BeginTooltip();
                            ImGui::PushTextWrapPos(ImGui::GetFontSize() * 28.0f);
                            ImGui::TextUnformatted(
                                "Bring this child to you. Moves the actor that already "
                                "exists - it never creates a second one, which is what "
                                "the console's PlaceAtMe would do.\n\n"
                                "Use this to get a child in front of you so SkyrimNet's "
                                "bio hotkey can author their character record. Until that "
                                "happens they are registered under Fertility Mode's "
                                "generic child name rather than their own.");
                            ImGui::PopTextWrapPos();
                            ImGui::EndTooltip();
                        }
                        ImGui::SameLine();
                        if (ImGui::SmallButton("Send home")) {
                            PapyrusBridge::SendChildHome(c.name);
                            NoteWrite();
                        }
                        // EXPERIMENT, and labelled as one. Only offered where it
                        // can actually be answered: Variable07 can name eight
                        // player houses and nothing else, so a child living in
                        // the Blue Palace has no integer and the button would
                        // only ever report that.
                        if (!c.home.empty()) {
                            ImGui::SameLine();
                            if (ImGui::SmallButton("Var07?")) {
                                PapyrusBridge::TryHomePackage(c.name);
                                NoteWrite();
                            }
                            if (ImGui::IsItemHovered()) {
                                ImGui::BeginTooltip();
                                ImGui::PushTextWrapPos(ImGui::GetFontSize() * 30.0f);
                                ImGui::TextUnformatted(
                                    "Test: tell this child's own AI package where they "
                                    "live, then ask the package to move them.\n\n"
                                    "These actors are built from Fertility Mode's child "
                                    "bases, which carry the vanilla child AI. That AI "
                                    "reads a house number from Variable07, and with none "
                                    "set it falls back to one marker shared by every "
                                    "child - which is what drags them back after a long "
                                    "sleep.\n\n"
                                    "Watch the log. If they end up inside the house named "
                                    "in the Home column, the package reads it and that is "
                                    "the fix. If they end up anywhere else, it does not, "
                                    "and we need our own package.\n\n"
                                    "Only works for the eight Hearthfire player homes.");
                                ImGui::PopTextWrapPos();
                                ImGui::EndTooltip();
                            }
                        }
                        if (ImGui::IsItemHovered()) {
                            ImGui::BeginTooltip();
                            ImGui::PushTextWrapPos(ImGui::GetFontSize() * 28.0f);
                            ImGui::TextUnformatted(
                                "Move this child to the home they are already recorded "
                                "as living in - inheriting their mother's if they have "
                                "none yet.\n\n"
                                "A child is placed wherever you were standing when it "
                                "got a body, and nothing has ever moved it since. This "
                                "puts it where it belongs without escorting it there.");
                            ImGui::PopTextWrapPos();
                            ImGui::EndTooltip();
                        }
                    }
                    if (!c.hasBody && (c.stage < 0 || c.stage >= 2)) {
                        ImGui::SameLine();
                        if (g_spawnConfirm == c.index) {
                            // TWO STEPS, because this puts an NPC into the world
                            // and there is no undo button for that in this panel.
                            if (ImGui::SmallButton("Really?")) {
                                PapyrusBridge::SpawnChildBody(c.name);
                                g_spawnConfirm = -1;
                                NoteWrite();
                            }
                            ImGui::SameLine();
                            if (ImGui::SmallButton("No")) {
                                g_spawnConfirm = -1;
                            }
                        } else {
                            if (ImGui::SmallButton("Give a body")) {
                                g_spawnConfirm = c.index;
                            }
                            // SAY WHY THE BUTTON IS HERE.
                            //
                            // Without this the button reads as a defect - a child
                            // is old enough to walk around and the panel is
                            // offering to fix something, with no indication of
                            // what went wrong or whether anything did. Usually
                            // nothing did: Fertility Mode simply never spawns a
                            // child it has named, and that is the expected state
                            // for most of a roster.
                            //
                            // The two cases need different answers, which is why
                            // Store carries `owned` at all.
                            //
                            // INSIDE this branch, not after the chain. IsItemHovered
                            // reads the LAST SUBMITTED item, so left below the
                            // if/else it would describe the "No" button whenever a
                            // confirmation was open.
                            if (ImGui::IsItemHovered()) {
                                ImGui::BeginTooltip();
                                ImGui::PushTextWrapPos(ImGui::GetFontSize() * 28.0f);
                                if (c.owned) {
                                    ImGui::TextUnformatted(
                                        "This mod is running this childhood and gives this "
                                        "child a body by itself once it reaches toddler. "
                                        "Nothing is wrong; the button is here if you would "
                                        "rather not wait.");
                                } else {
                                    ImGui::TextUnformatted(
                                        "Nothing has gone wrong. Fertility Mode names a child "
                                        "and then waits for you to adopt it or send it to "
                                        "training. Adoption is capped at two and training goes "
                                        "straight to adulthood, so a child you do neither with "
                                        "stays a record with no actor - which is what this one "
                                        "is.\n\n"
                                        "This mod only places a body automatically for births "
                                        "it took over itself, so that switching life stages on "
                                        "does not put a crowd of children into the world at "
                                        "once. For everyone else, this button is the way.");
                                }
                                ImGui::PopTextWrapPos();
                                ImGui::EndTooltip();
                            }
                        }
                    }
                }
                ImGui::PopID();
            }
            ImGui::EndTable();
        }
    }

    void __stdcall Render() {
        if (g_refreshAt > 0.0f && ImGui::GetTime() >= g_refreshAt) {
            g_refreshAt = 0.0f;
            Store::Reload();
        } else {
            Store::RefreshIfChanged();
        }

        if (!Store::Loaded()) {
            ImGui::TextWrapped("No kinship store yet: %s", Store::LastError().c_str());
            ImGui::TextWrapped(
                "This is normal before the first birth is recorded. The store is created by the "
                "Papyrus half of the mod, not by this panel.");
            return;
        }

        if (!PapyrusBridge::IsAvailable()) {
            // Read-only rather than offering buttons that queue calls into a VM
            // that will never run them.
            ImGui::TextDisabled("Papyrus bridge unavailable - showing records read-only.");
            ImGui::Separator();
        }

        ImGui::Text("%d children | schema %d", static_cast<int>(Store::Children().size()),
                    Store::SchemaVersion());
        ImGui::Separator();

        DrawTimelineWarning();
        DrawUnresolvedQueue();

        ImGui::SetNextItemWidth(240.0f);
        ImGui::InputTextWithHint("##search", "search name, mother or father", g_search, sizeof(g_search));
        ImGui::SameLine();
        ImGui::Checkbox("only unresolved", &g_onlyUnresolved);
        ImGui::SameLine();
        if (ImGui::Button("Refresh")) {
            Store::Reload();
        }
        // DIAGNOSTIC. Asks the engine which AI package is actually running on
        // every child that has a body, and writes it to SkyrimNetKinship.log.
        // Five theories about what keeps dragging them to Whiterun were tested
        // from the outside and all five were wrong; this stops guessing.
        //
        // Comes out before release along with the displacement watcher.
        ImGui::SameLine();
        if (ImGui::Button("Diagnose")) {
            g_diagResult = Diagnostics::DumpPackages();
        }
        if (!g_diagResult.empty()) {
            ImGui::SameLine();
            ImGui::TextDisabled("%s", g_diagResult.c_str());
        }
        // SEND EVERYONE HOME AT ONCE.
        //
        // Children placed before homes were being assigned are standing
        // wherever the player happened to be at the time - on the save this was
        // written against, a crowd of them in the middle of Whiterun. Doing it
        // one at a time is twenty-five button presses; escorting each as a
        // follower is twenty-five journeys.
        //
        // Confirmed, because it moves every child in the world at once and
        // there is no undo - though each of them can be Summoned straight back.
        ImGui::SameLine();
        if (g_sendAllConfirm) {
            if (ImGui::Button("Really? Move everyone")) {
                PapyrusBridge::SendAllChildrenHome();
                g_sendAllConfirm = false;
                NoteWrite();
            }
            ImGui::SameLine();
            if (ImGui::Button("No")) {
                g_sendAllConfirm = false;
            }
        } else if (ImGui::Button("Send all home")) {
            g_sendAllConfirm = true;
        }
        if (ImGui::IsItemHovered()) {
            ImGui::BeginTooltip();
            ImGui::PushTextWrapPos(ImGui::GetFontSize() * 30.0f);
            ImGui::TextUnformatted(
                "Move every child that has a body to the home they are recorded "
                "as living in, inheriting their mother's where they have none.\n\n"
                "Children with no home on either side are left alone and named "
                "in the log. Where the interior cannot be resolved a child is "
                "left at the front door instead.");
            ImGui::PopTextWrapPos();
            ImGui::EndTooltip();
        }

        DrawAddChild();
        DrawTable();

        // A recorded mother shows as a pressed green button among her
        // alternatives; click another to switch, or "clear" to unset. Nothing
        // here is a one-way door.
        //
        // Assigning an ARBITRARY parent still belongs to the Papyrus picker.
        // Choosing an NPC needs either the crosshair or Fertility Mode's
        // tracked list, and both live on the game side; duplicating them here
        // would mean a second implementation to keep honest. Shift+9 remains
        // the way to assign someone new - this panel is for seeing everything
        // at once and settling shortlists.
        ImGui::Separator();
        ImGui::TextDisabled("To assign a parent not listed above, use the in-game menu (Left Shift + 9).");
    }

    void Register() {
        if (!SKSEMenuFramework::IsInstalled()) {
            SKSE::log::warn("SKSE Menu Framework not installed - panel not registered");
            return;
        }
        SKSEMenuFramework::SetSection("SkyrimNet Kinship");
        SKSEMenuFramework::AddSectionItem("Children", Render);
        Store::Reload();
        SKSE::log::info("Kinship panel registered");
    }
}
