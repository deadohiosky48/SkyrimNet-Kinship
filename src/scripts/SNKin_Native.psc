Scriptname SNKin_Native Hidden
{Natives provided by SkyrimNetKinship.dll.

 THE DLL IS OPTIONAL AND THIS FILE DOES NOT CHANGE THAT. Every caller must
 verify the effect rather than assume the call landed - SetLinkedRef is checked
 with vanilla GetLinkedRef immediately afterwards - so a missing or failed
 plugin degrades the feature instead of breaking the mod.}

Function SetLinkedRef(ObjectReference akRef, ObjectReference akTarget, Keyword akKeyword) Global Native
{Links akRef to akTarget under akKeyword, the setter Papyrus never shipped.

 Pass None as akTarget to remove the link. Reading it back is GetLinkedRef,
 which is vanilla, so a link written here is indistinguishable from one placed
 in the Creation Kit.}

Race Function GetParentRace(Race akRace) Global Native
{The race a vampire race is built on, via the RACE record's armor parent
 (RNAM), or None when there is no such relationship.

 That field exists so a vampire can wear the armour of the race they were
 turned from, which means essentially every vampire race - vanilla or modded -
 points at its base. Far more reliable than matching "Vampire" in a name.}
