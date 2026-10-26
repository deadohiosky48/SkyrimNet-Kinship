#pragma once

#include <cstdint>

// SkyrimNet Kinship's read API, for other SKSE plugins.
//
// Ask for it once SKSE has loaded every plugin (kPostLoad or later):
//
//     using Request = const void* (*)(std::uint32_t);
//     auto* dll = GetModuleHandleW(L"SkyrimNetKinship.dll");
//     auto  fn = dll ? reinterpret_cast<Request>(GetProcAddress(dll, "SNKinship_RequestApi")) : nullptr;
//     auto* api = fn ? static_cast<const SNKinship_API_V1*>(fn(1)) : nullptr;
//
// A null result means Kinship is not installed, or is older than this version
// of the interface. Read-only: nothing here changes what Kinship records.
//
// THREADS. Safe from any thread. Kinship keeps its own copy of what it reads,
// apart from its panel's, and rereads it only when the record changes.

struct SNKinship_API_V1 {
    // 1.
    std::uint32_t version;

    // The player's children whose other parent is a_parentFormId (a reference's
    // form id, as Kinship records mothers and fathers), as a JSON array, oldest
    // first:
    //
    //     [{ "name": "Lucia", "child": "daughter", "stage": 3, "adopted": false,
    //        "inWorld": true, "born": 214.5 }, ...]
    //
    // child: "son", "daughter" or "" when unrecorded. stage: 0 newborn to 5
    // adult; -1 when life stages are off or not yet worked out. inWorld: a
    // body is recorded for them (a child can be a record only). born: game
    // days; 0 when unrecorded.
    //
    // Writes at most a_size bytes, a terminating NUL included, into a_out, and
    // returns the size the whole answer needs, its NUL included. Call with a
    // null a_out (or a_size 0) to learn the size first; "[]" when there are
    // none or no record can be read.
    std::uint32_t (*ChildrenWith)(std::uint32_t a_parentFormId, char* a_out, std::uint32_t a_size);
};

// Version 2 (Kinship 1.10): V1, and every child of the player's, as JSON in the
// same shape as ChildrenWith's, plus their parents:
//
//     [{ "name": "Lucia", "child": "daughter", "stage": 3, "adopted": false,
//        "inWorld": true, "born": 214.5, "bornKnown": true, "mother": "Ysolde",
//        "father": "Haruk" }, ...]
//
// bornKnown: born is the day they were born. False for a child taken into the
// record by hand or in a sweep, or adopted: born is then the day it was
// recorded. mother, father: as recorded, by name; "" when unknown. Ask for it with
// SNKinship_RequestApi(2); a Kinship that predates it answers null, and the
// caller can still ask for 1.
struct SNKinship_API_V2 {
    // 2.
    std::uint32_t version;
    std::uint32_t (*ChildrenWith)(std::uint32_t a_parentFormId, char* a_out, std::uint32_t a_size);
    std::uint32_t (*AllChildren)(char* a_out, std::uint32_t a_size);
};
