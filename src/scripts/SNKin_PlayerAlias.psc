Scriptname SNKin_PlayerAlias extends ReferenceAlias
{ Re-establishes the bridge on every game load.

  Decorator registrations and ModEvent registrations do NOT survive a
  save/load. Without this the mod silently stops working after the first
  reload - a nasty failure mode, because nothing errors: births simply stop
  being noticed and the decorator stops resolving.

  A Quest script never receives OnPlayerLoadGame - it is an Actor/alias event
  only - which is why this alias exists at all rather than the handler living
  on SNKin_Bridge.

  Resolves the bridge via GetOwningQuest() rather than a filled property, so
  there is nothing to wire by hand in the Creation Kit and nothing to leave
  unset. }

Event OnInit()
    Rebind(True)
EndEvent

Event OnPlayerLoadGame()
    { FORCED. This fires exactly once per game load and is the only
      unambiguous "new session" signal available, so it must never be
      debounced away - Bootstrap's debounce compares real time against a value
      that persists in the save, and real time cannot tell sessions apart. }
    Rebind(True)
EndEvent

Function Rebind(Bool abForce = False)
    SNKin_Bridge bridge = GetOwningQuest() as SNKin_Bridge
    If bridge == None
        Debug.Trace("[SNKin] Player alias could not resolve SNKin_Bridge on its owning quest.")
        Return
    EndIf
    bridge.Bootstrap(abForce)
EndFunction
