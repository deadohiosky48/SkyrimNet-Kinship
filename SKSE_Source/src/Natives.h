#pragma once

namespace Kinship::Natives {

    // Registers this mod's Papyrus natives.
    //
    // ONE FUNCTION, AND ONLY BECAUSE PAPYRUS GENUINELY CANNOT DO IT.
    // ObjectReference exposes GetLinkedRef and no setter, which is the single
    // reason SeverActions built its home system out of twenty quest aliases
    // rather than one linked-reference package. With a setter the alias table
    // is unnecessary and the slot ceiling goes away.
    //
    // THE DLL REMAINS OPTIONAL. plugin.cpp promises that nothing in the Papyrus
    // half will ever depend on this library, and that promise is kept here by
    // making the caller VERIFY rather than assume: SNKin_Bridge sets the link,
    // reads it back with vanilla GetLinkedRef, and falls back to a
    // current-location pin when the read comes back empty. A missing DLL is
    // therefore a degraded feature, never a broken one, and needs no
    // availability flag to detect.
    void Register(const SKSE::PapyrusInterface* a_papyrus);
}
