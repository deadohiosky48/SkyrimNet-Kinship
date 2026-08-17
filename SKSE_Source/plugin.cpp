#include "PCH.h"

#include "src/KinshipPanel.h"
#include "src/Store.h"

namespace {

    void InitLogging() {
        auto path = SKSE::log::log_directory();
        if (!path) {
            return;
        }
        *path /= "SkyrimNetKinship.log";
        auto sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(path->string(), true);
        auto log = std::make_shared<spdlog::logger>("global", std::move(sink));
        log->set_level(spdlog::level::info);
        log->flush_on(spdlog::level::info);
        spdlog::set_default_logger(std::move(log));
        spdlog::set_pattern("[%H:%M:%S.%e] [%l] %v");
    }

    void OnMessage(SKSE::MessagingInterface::Message* a_msg) {
        // kDataLoaded, not kPostLoad: SKSE Menu Framework has to be up before
        // IsInstalled() can answer honestly, and the store may not exist at all
        // until Papyrus has run a sweep.
        if (a_msg->type == SKSE::MessagingInterface::kDataLoaded) {
            Kinship::Panel::Register();
        }
    }
}

SKSEPluginLoad(const SKSE::LoadInterface* a_skse) {
    InitLogging();
    SKSE::Init(a_skse);

    SKSE::log::info("SkyrimNet Kinship plugin loading");

    // THIS DLL IS ENTIRELY OPTIONAL. The mod is fully functional without it -
    // the Papyrus half owns every piece of logic, and the in-game picker
    // (Left Shift + 9) needs nothing from here. If this fails to load, or SKSE
    // Menu Framework is absent, the player loses a convenience view and
    // nothing else. Nothing in the Papyrus half may ever come to depend on it.
    if (!SKSE::GetMessagingInterface()->RegisterListener(OnMessage)) {
        SKSE::log::error("Could not register the messaging listener - panel disabled");
        return false;
    }

    return true;
}
