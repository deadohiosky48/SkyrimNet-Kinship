#include "Store.h"

#include "PCH.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>

namespace Kinship::Store {

    namespace {
        std::vector<Child> g_children;
        std::vector<Person> g_people;
        int g_schema = 0;
        bool g_loaded = false;
        std::string g_error;
        std::filesystem::file_time_type g_stamp{};

        // JSONUTIL LOWERCASES EVERY KEY IT WRITES. "child.7.motherId" is stored
        // as "child.7.motherid", and nlohmann's find() is case-sensitive, so
        // looking up the camelCase form silently returns the fallback.
        //
        // That is not hypothetical: it is why the panel's first outing showed
        // buttons labelled "(unnamed)" and treated every child as having no
        // mother - candidateNames and motherId both missed, while the
        // all-lowercase keys like "name" and "mother" happened to work. Fold
        // every lookup rather than trying to remember which keys are safe.
        std::string Lower(std::string aKey) {
            for (auto& ch : aKey) {
                ch = static_cast<char>(::tolower(static_cast<unsigned char>(ch)));
            }
            return aKey;
        }

        // JsonUtil writes typed buckets rather than one nested object: strings
        // live under "string", ints under "int", floats under "float", and list
        // types under "stringList" / "intList". So "child.7.name" is a flat KEY
        // inside the "string" bucket, not a path through nested objects.
        template <typename T>
        T Get(const nlohmann::json& aRoot, const char* aBucket, const std::string& aRawKey, T aFallback) {
            const auto aKey = Lower(aRawKey);
            auto bucket = aRoot.find(aBucket);
            if (bucket == aRoot.end() || !bucket->is_object()) {
                return aFallback;
            }
            auto it = bucket->find(aKey);
            if (it == bucket->end()) {
                return aFallback;
            }
            try {
                return it->get<T>();
            } catch (...) {
                return aFallback;
            }
        }

        std::vector<std::int32_t> GetIntList(const nlohmann::json& aRoot, const std::string& aRawKey) {
            const auto aKey = Lower(aRawKey);
            std::vector<std::int32_t> out;
            auto bucket = aRoot.find("intList");
            if (bucket == aRoot.end() || !bucket->is_object()) {
                return out;
            }
            auto it = bucket->find(aKey);
            if (it == bucket->end() || !it->is_array()) {
                return out;
            }
            for (const auto& v : *it) {
                if (v.is_number_integer()) {
                    out.push_back(v.get<std::int32_t>());
                }
            }
            return out;
        }

        std::vector<std::string> GetStringList(const nlohmann::json& aRoot, const std::string& aRawKey) {
            const auto aKey = Lower(aRawKey);
            std::vector<std::string> out;
            auto bucket = aRoot.find("stringList");
            if (bucket == aRoot.end() || !bucket->is_object()) {
                return out;
            }
            auto it = bucket->find(aKey);
            if (it == bucket->end() || !it->is_array()) {
                return out;
            }
            for (const auto& v : *it) {
                if (v.is_string()) {
                    out.push_back(v.get<std::string>());
                }
            }
            return out;
        }
    }

    std::string Path() {
        // Relative to the process, which for Skyrim is the game root. Data/ is
        // therefore the right anchor, and this resolves correctly whether the
        // mod is deployed loose or through a mod manager's virtual file system.
        //
        // WHICH file is per-playthrough, and this side cannot work it out: the
        // save id lives in StorageUtil, inside the co-save, where a separate
        // reader has no access. Papyrus rewrites a one-key pointer on every
        // bootstrap and we follow it.
        constexpr auto kDir = "Data/SKSE/Plugins/StorageUtilData/";
        std::ifstream ptr(std::string(kDir) + "SNKin_Current.json");
        if (ptr) {
            try {
                nlohmann::json j;
                ptr >> j;
                auto bucket = j.find("string");
                if (bucket != j.end() && bucket->is_object()) {
                    auto it = bucket->find("store");
                    if (it != bucket->end() && it->is_string()) {
                        const auto name = it->get<std::string>();
                        if (!name.empty()) {
                            return std::string(kDir) + name + ".json";
                        }
                    }
                }
            } catch (...) {
                // Fall through: a malformed pointer must not take the panel
                // down, it just means we read the default.
            }
        }
        return std::string(kDir) + "SNKin_Parentage.json";
    }

    void Reload() {
        g_children.clear();
        g_people.clear();
        g_schema = 0;
        g_error.clear();

        const auto path = Path();
        std::ifstream in(path);
        if (!in) {
            g_loaded = false;
            g_error = "store not found: " + path;
            return;
        }

        nlohmann::json root;
        try {
            in >> root;
        } catch (const std::exception& e) {
            g_loaded = false;
            g_error = std::string("parse failed: ") + e.what();
            return;
        }

        g_schema = Get<int>(root, "int", "schema", 0);

        // The roster is the authority on which indices exist, exactly as in
        // Papyrus - a child is real because it is on the roster, not because
        // some child.N.* key happens to be present.
        const auto roster = GetStringList(root, "roster");
        g_children.reserve(roster.size());

        for (std::size_t i = 0; i < roster.size(); ++i) {
            const auto key = "child." + std::to_string(i) + ".";
            Child c;
            c.index = static_cast<int>(i);
            c.name = Get<std::string>(root, "string", key + "name", roster[i]);
            c.gender = Get<std::string>(root, "string", key + "gender", "");
            c.motherName = Get<std::string>(root, "string", key + "mother", "");
            c.fatherName = Get<std::string>(root, "string", key + "father", "");
            c.motherId = Get<std::int32_t>(root, "int", key + "motherId", 0);
            c.fatherId = Get<std::int32_t>(root, "int", key + "fatherId", 0);
            c.born = Get<float>(root, "float", key + "born", 0.0f);
            c.hidden = Get<int>(root, "int", key + "hidden", 0) != 0;
            c.candidateIds = GetIntList(root, key + "candidates");
            c.candidateNames = GetStringList(root, key + "candidateNames");
            if (c.hidden) {
                continue;   // slot stays in the file so indices never shift
            }
            g_children.push_back(std::move(c));
        }

        // KEYED records, not parallel lists. people.ids is only an index;
        // the name and sex come from person.<id>.*, so they cannot belong to
        // someone else. The old aligned-list form drifted on a live save and
        // put a woman in the Fathers dropdown.
        for (const auto id : GetIntList(root, "people.ids")) {
            Person p;
            p.id = id;
            const auto key = "person." + std::to_string(id) + ".";
            p.name = Get<std::string>(root, "string", key + "name", "");
            if (p.name.empty()) {
                continue;   // index entry with no record: skip rather than show a blank
            }
            p.sex = Get<int>(root, "int", key + "sex", -1);
            g_people.push_back(std::move(p));
        }

        // Sorted once here rather than in the panel, which redraws every frame.
        std::sort(g_people.begin(), g_people.end(), [](const Person& a, const Person& b) {
            return _stricmp(a.name.c_str(), b.name.c_str()) < 0;
        });

        g_loaded = true;
    }

    bool RefreshIfChanged() {
        // Re-read the pointer only occasionally: it changes at most once per
        // game load, and this runs every frame.
        static int tick = 0;
        static std::string cached;
        if (cached.empty() || (++tick % 120) == 0) {
            cached = Path();
        }
        std::error_code ec;
        const auto stamp = std::filesystem::last_write_time(cached, ec);
        if (ec) {
            return false;
        }
        if (stamp == g_stamp && g_loaded) {
            return false;
        }
        g_stamp = stamp;
        Reload();
        return true;
    }

    const std::vector<Child>& Children() { return g_children; }
    const std::vector<Person>& People() { return g_people; }
    int SchemaVersion() { return g_schema; }
    bool Loaded() { return g_loaded; }
    const std::string& LastError() { return g_error; }

    std::vector<const Child*> Unresolved() {
        std::vector<const Child*> out;
        for (const auto& c : g_children) {
            if (c.NeedsMother()) {
                out.push_back(&c);
            }
        }
        return out;
    }
}
