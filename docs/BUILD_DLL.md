# Building the SKSE Menu Framework panel

**This DLL is entirely optional.** The mod is complete without it: every piece
of logic lives in Papyrus, and the in-game picker (Left Shift + 9) needs nothing
from here. If the DLL is missing, fails to load, or SKSE Menu Framework is not
installed, the player loses a convenience view and nothing else.

Nothing in the Papyrus half may ever be allowed to depend on it.

---

## Why a second interface at all

The Papyrus picker is a chain of modal list prompts. That shape suits "assign
this one person to that one child", which is what the crosshair flow does well,
and suits badly the two jobs this panel exists for:

- seeing **every child and both parents at once**, rather than one prompt at a time
- settling **unresolved shortlists**, where two mothers matured in the same
  moment and the birth was recorded with candidates instead of a guess

---

## Architecture, and the one rule that matters

**Papyrus is the only writer.**

`SNKin_Parentage.json` is owned by PapyrusUtil's JsonUtil, which holds the whole
document in memory and flushes it on `Save()`. If this DLL wrote the file
directly, the next Papyrus save would overwrite the change without noticing —
and because **both interfaces stay live**, that is a real data-loss race, not a
theoretical one.

So:

| Direction | Route |
|---|---|
| Read | DLL parses the JSON directly (ImGui redraws every frame; calling Papyrus per frame is a non-starter) |
| Write | DLL calls `SNKin_Bridge` Globals through `DispatchStaticCall` |

Both interfaces therefore execute **identical** write code and cannot disagree.

`DispatchStaticCall` can only invoke **Global** Papyrus functions. That is why
`SetParentStatic`, `SetParentByIdStatic` and `ClearParentStatic` exist as
Globals — they were already needed for `SNKin_Picker`, which is attached to no
form for the same reason. Scaffolding this DLL is what revealed the clear path
had only an instance entry point; `ClearParentStatic` was added for it.

---

## Prerequisites

None of this is installed on the development machine as of 2026-08-16.

1. **Visual Studio Build Tools 2022** with *Desktop development with C++*
   (MSVC v143 and the Windows 11 SDK). ~5–8 GB.
2. **CMake** 3.21+ — bundled with the above, or standalone.
3. **vcpkg**:
   ```
   git clone https://github.com/microsoft/vcpkg
   .\vcpkg\bootstrap-vcpkg.bat
   setx VCPKG_ROOT C:\path\to\vcpkg
   ```
4. **CommonLibSSE-NG**, into `SKSE_Source/extern/CommonLibSSE-NG`:
   ```
   git clone https://github.com/alandtse/CommonLibVR.git --branch ng --recursive SKSE_Source/extern/CommonLibSSE-NG
   ```

`SKSEMenuFramework.h` is already vendored in `SKSE_Source/include/`. It is the
framework's public integration header and is meant to be copied in — the
framework ships only a DLL, so there is nothing to link against.

---

## Build

Use the script. It handles three traps that cost an afternoon on first contact:

```bash
powershell -ExecutionPolicy Bypass -File "tools\build-dll.ps1" -Setup
```

then, from there on:

```bash
powershell -ExecutionPolicy Bypass -File "tools\build-dll.ps1" -Deploy
```

Output: `SkyrimNetKinship.dll` → the deploy folder's `SKSE/Plugins/`.

### The three traps

1. **`cmake` is not on PATH.** Visual Studio bundles it under
   `Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/`, and *only a
   Developer PowerShell puts it on PATH*. A normal shell gives
   `The term 'cmake' is not recognized`. The script locates it through
   `vswhere` so no Developer shell is needed.

2. **`%VCPKG_ROOT%` is CMD syntax.** In PowerShell it does not expand, so
   `-DCMAKE_TOOLCHAIN_FILE=%VCPKG_ROOT%/...` silently becomes a bare relative
   path and cmake fails describing something unrelated. PowerShell needs
   `$env:VCPKG_ROOT`. *(An earlier version of this document had the CMD form —
   that was the bug, not the reader.)*

3. **CommonLibSSE-NG must be cloned `--recursive`.** Without submodules it
   configures fine and then fails deep inside a dependency with no obvious
   cause.

### Doing it by hand instead

Open **Developer PowerShell for VS**, then:

```
cd SKSE_Source
cmake -B build -S . "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" -DVCPKG_TARGET_TRIPLET=x64-windows-static
cmake --build build --config Release
```

---

## Verifying

1. `Data/SKSE/Plugins/SkyrimNetKinship.log` should read
   `Kinship panel registered`.
   *`SKSE Menu Framework not installed - panel not registered`* means exactly
   what it says and is not an error.
2. Open the SKSE Menu Framework overlay → **SkyrimNet Kinship** → **Children**.
3. The table should list every child with both parents, and `unknown` in grey
   where a parent was never established — never a blank cell, because refusing
   to guess is a fact worth showing rather than something that reads as a
   rendering bug.
4. Assigning from a shortlist should produce a `SetParent:` line in
   `snkin.log`. **The panel will not update instantly** — Papyrus dispatch is
   asynchronous, which is why the panel reloads on a short timer after any
   command rather than expecting the write to have landed.

---

## What this panel deliberately does NOT do

Assigning an **arbitrary** parent stays in the Papyrus picker. Choosing an NPC
needs either the crosshair or Fertility Mode's tracked list, both of which live
on the game side; reimplementing that here would mean a second implementation to
keep honest, and the two could then disagree about who is eligible.

Left Shift + 9 remains the way to assign someone new.
