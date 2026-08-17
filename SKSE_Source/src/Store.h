#pragma once

#include <cstdint>
#include <string>
#include <vector>

// READ-ONLY view of SNKin_Parentage.json.
//
// Deliberately never writes. See PapyrusBridge for why: JsonUtil holds the
// document in memory and flushes on Save(), so a second writer loses.
//
// The schema is written by SNKin_Bridge and is flat by design - roster indices
// are the record keys, because deriving them from names corrupted every key on
// a live save (Nicollette became "colLETTE"). Do not reintroduce name-derived
// keys here either.
namespace Kinship::Store {

    struct Child {
        int index = -1;              // roster position; the record key
        std::string name;
        std::string gender;          // "son" / "daughter" / ""
        std::string motherName;      // "" when unknown
        std::string fatherName;
        std::int32_t motherId = 0;   // 0 when unrecorded
        std::int32_t fatherId = 0;
        float born = 0.0f;           // game days
        bool hidden = false;          // tombstoned: kept for index stability, not shown

        // Populated only when a birth could not be attributed. Both vectors are
        // index-aligned and may contain duplicate names - see the Papyrus side,
        // which stores them with duplicates ALLOWED so the alignment holds even
        // if two candidates share a display name.
        std::vector<std::int32_t> candidateIds;
        std::vector<std::string> candidateNames;

        bool NeedsMother() const { return motherId == 0 && !candidateIds.empty(); }
        bool HasMother() const { return motherId != 0 || !motherName.empty(); }
    };

    // Absolute path to the store, derived from the Skyrim install rather than
    // assumed: Data/SKSE/Plugins/StorageUtilData/SNKin_Parentage.json
    std::string Path();

    // Reloads only when the file's write time has moved. The panel redraws every
    // frame and reparsing a document on each one would be absurd, but polling a
    // timestamp is free.
    bool RefreshIfChanged();

    // Forces a reparse. Call after a write has been dispatched to Papyrus -
    // though note dispatch is ASYNCHRONOUS, so an immediate refresh will often
    // still show the old value. The panel handles that by refreshing on a short
    // timer after any command rather than expecting instant truth.
    void Reload();

    // Everyone who could be picked as a parent: a permanent roster accumulated
    // by the Papyrus half from FMR's tracked actors plus anyone ever assigned
    // by hand.
    //
    // OURS, NOT FMR'S, and that is the entire point. FMR prunes a mother from
    // its tracking within game hours of her child maturing, which is what made
    // Camilla, Ganna, Danica and Nilsine unselectable. Names and FormIDs cost
    // nothing to keep, so this list only ever grows.
    struct Person {
        std::int32_t id = 0;
        std::string name;
        int sex = -1;   // 0 male, 1 female, -1 unknown (offered for either parent)
    };

    const std::vector<Child>& Children();
    const std::vector<Person>& People();

    // Children recorded with an unresolved shortlist - the queue the panel
    // leads with, because it is the only part that is a question waiting on an
    // answer rather than a record to browse.
    std::vector<const Child*> Unresolved();

    int SchemaVersion();
    bool Loaded();
    const std::string& LastError();
}
