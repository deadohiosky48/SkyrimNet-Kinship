#include "SNKinship_API.h"

#include "PCH.h"

#include "Store.h"

#include <cstring>
#include <filesystem>
#include <mutex>
#include <nlohmann/json.hpp>

// The read API (include/SNKinship_API.h). Asked for by SkyrimNet Relationships
// for a person's Family section: their children with the player.
//
// ITS OWN COPY of the record, apart from the panel's: the panel rereads its
// lists on the render thread every frame they change, and this is asked on
// the game's. Reread only when the file's write time moves.
namespace Kinship::Api {

    namespace {

        std::mutex                      g_lock;
        std::string                     g_path;
        std::filesystem::file_time_type g_stamp{};
        std::vector<Store::Child>       g_children;

        // Under g_lock.
        void Refresh() {
            const auto      path = Store::Path();
            std::error_code ec;
            const auto      stamp = std::filesystem::last_write_time(path, ec);
            if (ec) {
                g_children.clear();
                g_path.clear();
                return;
            }
            if (path == g_path && stamp == g_stamp) {
                return;
            }
            std::vector<Store::Child>  children;
            std::vector<Store::Person> people;
            int                        schema = 0;
            std::string                error;
            if (!Store::Parse(path, children, people, schema, error)) {
                SKSE::log::warn("Read API: {}", error);
                children.clear();
            }
            g_children = std::move(children);
            g_path = path;
            g_stamp = stamp;
        }

        std::uint32_t Write(const nlohmann::json& a_out, char* a_buffer, std::uint32_t a_size) {
            const auto text = a_out.dump(-1, ' ', true);
            const auto need = static_cast<std::uint32_t>(text.size() + 1);
            if (a_buffer && a_size >= need) {
                std::memcpy(a_buffer, text.c_str(), need);
            } else if (a_buffer && a_size > 0) {
                a_buffer[0] = '\0';
            }
            return need;
        }

        // Papyrus has no unsigned type: a 0xFF form id is recorded negative.
        std::uint32_t Id(std::int32_t a_recorded) {
            return static_cast<std::uint32_t>(a_recorded);
        }

        std::uint32_t AllChildren(char* a_out, std::uint32_t a_size) {
            auto out = nlohmann::json::array();
            {
                const std::scoped_lock lock{ g_lock };
                Refresh();
                for (const auto& c : g_children) {
                    // A tombstone keeps a roster index stable; it is not a
                    // child any more (dev4: the calendar showed them).
                    if (c.hidden) {
                        continue;
                    }
                    out.push_back({ { "name", c.name },
                                    { "child", c.gender },
                                    { "stage", c.stage },
                                    { "adopted", c.adopted },
                                    { "inWorld", c.hasBody },
                                    { "born", c.born },
                                    // A real birth day, not the day a child
                                    // already in the world was recorded: a
                                    // birth claimed at labour (Fertility
                                    // Mode or Being Female, or ours to
                                    // raise). Records older than the source
                                    // field are not trusted: 23 of the
                                    // author's shared one day (163.1).
                                    { "bornKnown", !c.manual && c.born > 0.0f &&
                                                       (c.source == 1 || c.source == 2 || c.owned) },
                                    { "mother", c.motherName },
                                    { "father", c.fatherName },
                                    // dev4: who, by reference, so another
                                    // plugin can find them without names.
                                    { "refId", c.hasBody ? Id(c.refId) : 0u },
                                    { "motherId", Id(c.motherId) },
                                    { "fatherId", Id(c.fatherId) } });
                }
            }
            return Write(out, a_out, a_size);
        }

        std::uint32_t ChildrenWith(std::uint32_t a_parentFormId, char* a_out, std::uint32_t a_size) {
            auto out = nlohmann::json::array();
            if (a_parentFormId != 0) {
                const std::scoped_lock lock{ g_lock };
                Refresh();
                for (const auto& c : g_children) {
                    const auto mother = Id(c.motherId);
                    const auto father = Id(c.fatherId);
                    if (c.hidden || (mother != a_parentFormId && father != a_parentFormId)) {
                        continue;
                    }
                    out.push_back({ { "name", c.name },
                                    { "child", c.gender },
                                    { "stage", c.stage },
                                    { "adopted", c.adopted },
                                    { "inWorld", c.hasBody },
                                    { "born", c.born },
                                    { "refId", c.hasBody ? Id(c.refId) : 0u } });
                }
            }
            const auto text = out.dump(-1, ' ', true);
            const auto need = static_cast<std::uint32_t>(text.size() + 1);
            if (a_out && a_size >= need) {
                std::memcpy(a_out, text.c_str(), need);
            } else if (a_out && a_size > 0) {
                a_out[0] = '\0';
            }
            return need;
        }

        constexpr SNKinship_API_V1 kV1{ 1, ChildrenWith };
        constexpr SNKinship_API_V2 kV2{ 2, ChildrenWith, AllChildren };
    }
}

extern "C" __declspec(dllexport) const void* SNKinship_RequestApi(std::uint32_t a_version) {
    return a_version == 1 ? static_cast<const void*>(&Kinship::Api::kV1) :
           a_version == 2 ? static_cast<const void*>(&Kinship::Api::kV2) :
                            nullptr;
}
