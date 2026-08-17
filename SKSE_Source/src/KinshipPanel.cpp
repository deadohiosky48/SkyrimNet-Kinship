#include "KinshipPanel.h"

#include "PCH.h"
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
            g_editIndex = -1;
            NoteWrite();
        }

        void DrawTable() {
            constexpr auto flags = ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg |
                                   ImGuiTableFlags_ScrollY | ImGuiTableFlags_Resizable;
            if (!ImGui::BeginTable("kinship", 5, flags, ImVec2(0.0f, 420.0f))) {
                return;
            }
            ImGui::TableSetupColumn("Child");
            ImGui::TableSetupColumn("Relation");
            ImGui::TableSetupColumn("Mother");
            ImGui::TableSetupColumn("Father");
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

                ImGui::TableNextColumn();
                ImGui::Text("%s", c.name.c_str());
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

                ImGui::TableNextColumn();
                if (editing) {
                    if (ImGui::SmallButton("Save")) {
                        SaveEdit(c);
                    }
                    ImGui::SameLine();
                    if (ImGui::SmallButton("Cancel")) {
                        g_editIndex = -1;   // discard; nothing was written
                    }
                } else if (ImGui::SmallButton("Edit")) {
                    BeginEdit(c);
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
