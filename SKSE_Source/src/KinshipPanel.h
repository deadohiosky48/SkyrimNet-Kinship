#pragma once

// The SKSE Menu Framework panel: every child, both parents, at once.
//
// A SECOND interface, not a replacement. The Papyrus picker (SNKin_Picker,
// Left Shift + 9) keeps working unchanged and stays the way to assign an
// arbitrary NPC, because choosing one needs the crosshair or Fertility Mode's
// tracked list and both live on the game side. This panel is for seeing the
// whole family at once and settling unresolved shortlists - the two jobs a
// chain of modal list prompts does badly.
namespace Kinship::Panel {
    // __stdcall: SKSEMenuFramework stores this as a raw function pointer.
    void __stdcall Render();
    void Register();
}
