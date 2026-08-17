#pragma once

#include <cstdint>
#include <string>

// Writes into the kinship store.
//
// EVERY WRITE GOES THROUGH PAPYRUS. Nothing here touches the JSON file.
//
// SNKin_Parentage.json is owned by PapyrusUtil's JsonUtil, which keeps the
// whole document in memory and flushes it on Save(). If this DLL wrote the file
// directly, the next Papyrus save would overwrite our change without noticing -
// and while BOTH interfaces are live (the Shift+9 picker is not going away)
// that is a live data-loss race rather than a theoretical one.
//
// So the split is: read the file for display, route every mutation back through
// SNKin_Bridge. The picker and this panel then execute IDENTICAL code and
// cannot disagree about what the store contains.
namespace Kinship::PapyrusBridge {

    // Assigns a parent by reference FormID. aIsFather: 0 mother, 1 father.
    //
    // Calls SNKin_Bridge.SetParentByIdStatic, which is deliberately a GLOBAL
    // Papyrus function - DispatchStaticCall cannot invoke instance methods, and
    // resolving the quest from here would mean hardcoding our own plugin name.
    // The Globals already existed for SNKin_Picker, which is attached to
    // nothing for the same reason.
    //
    // Fire-and-forget: Papyrus dispatch is asynchronous and returns nothing
    // usable, so callers must NOT treat a true return as "the store changed".
    // It means "the call was queued". Refresh from disk afterwards.
    bool SetParentById(const std::string& aChildName, std::int32_t aParentFormID, std::int32_t aIsFather);

    // Clears a recorded parent, including its reverse index.
    bool ClearParent(const std::string& aChildName, std::int32_t aIsFather);

    // Deletes every record dated after the current game time. Destructive and
    // irreversible - the caller MUST have confirmed explicitly.
    bool ForgetFutureChildren();

    // Creates a record by hand. Child FormID may be 0; parents may be 0.
    bool AddChild(const std::string& aChildName, std::int32_t aChildFormID,
                  std::int32_t aMotherFormID, std::int32_t aFatherFormID);

    // True when the Papyrus VM is up and SNKin_Bridge is loaded. The panel
    // shows itself read-only rather than offering buttons that silently do
    // nothing.
    bool IsAvailable();
}
