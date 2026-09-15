#pragma once

#include <string>

namespace Kinship::Diagnostics {

    // Writes, for every child that has a body, the AI package the engine is
    // ACTUALLY running on them right now - form id, EditorID and type - plus
    // where they are.
    //
    // WHY THIS EXISTS. Children spawned from Fertility Mode's child bases keep
    // returning to one fixed marker in Whiterun. Five theories were tested from
    // the outside and all five were wrong: our own sandbox package override
    // survived and was ignored, SeverActions' home verifier did not hold them,
    // Variable07 cannot express most of their homes, gather-to-player was ruled
    // out by a 42,000-unit separation, and a game-time timer was ruled out
    // because waiting does not trigger it while sleeping does.
    //
    // Papyrus cannot ask which package is running. The engine can, so we ask
    // it, and stop guessing.
    //
    // ENTIRELY DLL-SIDE, deliberately. plugin.cpp promises that nothing in the
    // Papyrus half will ever depend on this DLL; a Papyrus native would break
    // that. The store already carries every child's reference id, which is all
    // this needs.
    //
    // Returns a short summary for the panel; the detail goes to
    // SkyrimNetKinship.log.
    std::string DumpPackages();
}
