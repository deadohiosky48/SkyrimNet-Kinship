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

        std::uint32_t ChildrenWith(std::uint32_t a_parentFormId, char* a_out, std::uint32_t a_size) {
            auto out = nlohmann::json::array();
            if (a_parentFormId != 0) {
                const std::scoped_lock lock{ g_lock };
                Refresh();
                for (const auto& c : g_children) {
                    // Papyrus has no unsigned type: a 0xFF form id is recorded
                    // negative.
                    const auto mother = static_cast<std::uint32_t>(c.motherId);
                    const auto father = static_cast<std::uint32_t>(c.fatherId);
                    if (mother != a_parentFormId && father != a_parentFormId) {
                        continue;
                    }
                    out.push_back({ { "name", c.name },
                                    { "child", c.gender },
                                    { "stage", c.stage },
                                    { "adopted", c.adopted },
                                    { "inWorld", c.hasBody },
                                    { "born", c.born } });
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
    }
}

extern "C" __declspec(dllexport) const void* SNKinship_RequestApi(std::uint32_t a_version) {
    return a_version == 1 ? &Kinship::Api::kV1 : nullptr;
}
