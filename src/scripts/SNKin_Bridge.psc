Scriptname SNKin_Bridge extends Quest
{ Fertility Mode Reloaded <-> SkyrimNet parentage bridge.

  THE BUG THIS EXISTS TO FIX: a birth reaches SkyrimNet only as a decaying
  MEMORY, and only when the player was present. Memories are a rolling window,
  so mothers forget children they bore and children never learn who their
  parents are. The permanent layer is the character bio, and until this mod
  nothing wrote parentage to it.

  WHY NOT THE UILib ROUTE. The spec recommended listening for
  UILIB_1_textInputClose to catch the child-naming prompt. That was measured
  and REJECTED: _JSW_BB_Utility.GenerateName only reaches ShowTextInput when
  the MCM "Desktop Mode" global UseKeyboardInput == 1. The DEFAULT path is
  ShowVRNameMenuSimple (a UIExtensions UIListMenu), and the duplicate-name
  fallback is a UIExtensions list too. A UILib listener would therefore hear
  nothing at all on a stock configuration, and would silently work for exactly
  one of three naming paths. It is not used here and should not be added.

  WHAT IS USED INSTEAD, all verified against FMR 1.0.3 sources:
    - FertilityModeConception  (String, Form, String, String, Int)
    - FertilityModeLabor       (String, Form, Int)
    - direct reads of _JSW_BB_Storage, obtained the same way the shipped
      SeverActions FM bridge does it - see ResolveStorage().

  A NOTE ON FMR's OWN FATHER RECORD, because it looks usable and is not.
  _JSW_BB_HandlerQuestAliasScript CLEARS Storage.LastFather[actorIndex] (:1636)
  BEFORE reading it into fatherName (:1655), so every child born through the
  normal automatic path is recorded by FMR with father "Unknown". The MCM path
  in _JSW_BB_ConfigQuestScript reads it first (:3111) and is correct. We
  therefore capture the father AT CONCEPTION and never trust
  PlayerChildFatherName except as a fallback. }

; ---------------------------------------------------------------------------
; State. No properties: nothing here is set in the Creation Kit, and a script
; with no property list is the least for CK to chew on. Same reasoning as
; SNRom_Bridge.
; ---------------------------------------------------------------------------
_JSW_BB_Storage _store
Bool            _ready
Float           _lastBootstrap
Float           _sweepingSince   ; real-time stamp, 0.0 = idle. See Sweep.

Int Function LOG_ERROR() Global
    Return 1
EndFunction
Int Function LOG_WARN() Global
    Return 2
EndFunction
Int Function LOG_INFO() Global
    Return 3
EndFunction
Int Function LOG_DEBUG() Global
    Return 4
EndFunction

String Function CFG() Global
    { SkyrimNet namespaces plugin manifests as "Plugin_<plugin name>". Reading
      from "game" silently returns the caller's default for every key. }
    Return "Plugin_SkyrimNet Kinship"
EndFunction

String Function DiagPath() Global
    Return "Data/SKSE/Plugins/SkyrimNet Kinship/logs/snkin.log"
EndFunction

String Function NL() Global
    { Papyrus string literals support no escape sequences except \" and \\. }
    Return StringUtil.AsChar(10)
EndFunction

; EVERY config path below starts with "kin", and no function in this mod starts
; with "kin". That is not a style choice - Papyrus interns strings
; CASE-INSENSITIVELY, so a function named PollHours and the literal
; "pollHours" would collide in the string table, the identifier would win, and
; the config lookup would silently return its default forever. The prefix makes
; the collision structurally impossible rather than something to remember.
Float Function PollHours() Global
    Return SkyrimNetApi.GetConfigFloat(CFG(), "kinPollHours", 0.5)
EndFunction

Bool Function IsEnabled() Global
    Return SkyrimNetApi.GetConfigBool(CFG(), "kinEnabled", True)
EndFunction

Bool Function SeedExisting() Global
    Return SkyrimNetApi.GetConfigBool(CFG(), "kinSeedExisting", True)
EndFunction

Int Function LogLevel() Global
    Return SkyrimNetApi.GetConfigInt(CFG(), "kinLogLevel", 3)
EndFunction

Bool Function Notify() Global
    Return SkyrimNetApi.GetConfigBool(CFG(), "kinNotify", False)
EndFunction

Int Function HotkeyCode() Global
    { DirectX scan code for the parent-assignment menu. 70 is Scroll Lock.

      READ FROM SKYRIMNET'S OWN CONFIG, NOT MCM HELPER - which means this mod
      takes no UI dependency at all.

      MCM Helper was the obvious home for a keybind and was rejected after
      reading NPC Renamer, which hit the wall on this exact load order: SkyUI's
      mod registry is a Papyrus array capped at 128 entries, and past that a
      menu registers but can never render - so MCM Helper's keybind can never
      be bound, because binding happens ON the page that will not open. NPC
      Renamer had to add a direct RegisterForKey anyway.

      Given the key has to be registered directly regardless, putting the
      setting in the SkyrimNet dashboard - which this mod already depends on
      and which the player already has open - removes a dependency instead of
      adding one. 0 disables the hotkey. }
    Return SkyrimNetApi.GetConfigInt(CFG(), "kinHotkey", 70)
EndFunction

Int Function HotkeyModifier() Global
    { Optional held modifier, Dynamic-Activation-Key style. 0 = none.
      42 Left Shift, 29 Left Ctrl, 56 Left Alt. }
    Return SkyrimNetApi.GetConfigInt(CFG(), "kinHotkeyModifier", 0)
EndFunction

; ===========================================================================
; Lifecycle
; ===========================================================================

Event OnInit()
    Bootstrap(True)
EndEvent

Function Bootstrap(Bool abForce = False)
    { Called from OnInit and from the player alias on every game load.

      MUST be idempotent: decorator registrations and ModEvent registrations do
      NOT survive a save/load, so this is the only thing keeping the mod alive
      after the first reload.

      The debounce compares real time - which counts from GAME LAUNCH and
      resets every restart - against a value that PERSISTS in the save. Load a
      save faster than last session and the delta goes negative, which is why
      the `now >= _lastBootstrap` term is load-bearing rather than defensive
      noise. A negative delta means "new session", which is exactly when this
      must run. OnPlayerLoadGame passes abForce anyway. }
    Float now = Utility.GetCurrentRealTime()
    If abForce
        _lastBootstrap = 0.0
    EndIf
    If _lastBootstrap > 0.0 && now >= _lastBootstrap && (now - _lastBootstrap) < 5.0
        Return
    EndIf
    _lastBootstrap = now

    ; BEFORE ANYTHING TOUCHES THE STORE. StoreFile() reads the save id, so a
    ; sweep that ran first would read and write the previous owner's file.
    EnsureSaveId()
    WriteStorePointer()

    ; Register FIRST and unconditionally. If FMR is missing the decorator must
    ; still exist, or every prompt referencing it errors instead of rendering
    ; "not known". Degrade quietly, never disappear.
    RegisterDecorators()
    RegisterEvents()
    RegisterHotkey()

    _store = ResolveStorage()
    If _store == None
        _ready = False
        Diag(LOG_WARN(), "Fertility Mode Reloaded not found - kinship inert, decorator still answers known:false.")
        Return
    EndIf
    _ready = True

    ; Arm the watch loop. A single-update registration replaces any prior one
    ; rather than stacking, so this is safe on every bootstrap.
    RegisterForSingleUpdateGameTime(PollHours())
    Diag(LOG_INFO(), "Bridge ready. FMR storage resolved. Watch armed (" + PollHours() + "h).")

    ; EVERY LOAD, not just the first run. This was inside the one-shot seed
    ; pass and that was wrong: a mother already carrying the player's baby when
    ; the session starts is not a first-install condition, it is the ordinary
    ; state of any save with a pregnancy in progress. With it gated behind
    ; `seeded` a baby in flight was adopted only if you happened to install the
    ; mod that week, and otherwise delivered into a child record with no mother
    ; for no discoverable reason. It is a bounded scan over FMR's tracking
    ; array, once per game load.
    AdoptBabiesInFlight()

    ; Catch up immediately rather than waiting out a poll. On a first run this
    ; is what seeds children who already exist.
    Sweep()

    ; DETECT a rewind, never act on it. Loading an older save to check something
    ; and going back is ordinary play, so the records stay untouched until the
    ; player says otherwise in the panel or the hotkey menu.
    Int future = CountFutureChildren()
    If future > 0
        Diag(LOG_WARN(), future + " child record(s) are dated AFTER this save point - " + \
            "an earlier save was probably loaded. Nothing has been changed. Review them " + \
            "in the Kinship panel or with the assign-parent hotkey.")
        If Notify()
            Debug.Notification("[Kinship] " + future + " children recorded after this save point")
        EndIf
    EndIf
EndFunction

_JSW_BB_Storage Function ResolveStorage() Global
    { 0x0D62 is _JSW_BB_HandlerQuest, which carries BOTH the Storage and the
      Utility scripts. Taken from the shipped SeverActions FM bridge, where
      this exact call is known to work.

      GetModByName is checked first so that a missing FMR is a quiet no rather
      than a failed cast logged every load. This is what keeps FMR a SOFT
      dependency: no master, no ESM in our plugin, nothing to strip. }
    If Game.GetModByName("Fertility Mode.esm") == 255
        Return None
    EndIf
    Quest handler = Game.GetFormFromFile(0x0D62, "Fertility Mode.esm") as Quest
    If handler == None
        Return None
    EndIf
    Return handler as _JSW_BB_Storage
EndFunction

Function RegisterHotkey()
    { Registers the parent-assignment key directly, every load.

      Key registrations do NOT survive a save/load, which is why this sits in
      Bootstrap alongside the decorator and ModEvent registrations rather than
      in OnInit. }
    Int code = HotkeyCode()
    UnregisterForAllKeys()
    If code > 0
        RegisterForKey(code)
        Diag(LOG_INFO(), "Parent-assignment hotkey armed on scan code " + code + ".")
    Else
        Diag(LOG_INFO(), "Parent-assignment hotkey disabled (kinHotkey = 0).")
    EndIf
EndFunction

Event OnKeyDown(Int aiKeyCode)
    If aiKeyCode != HotkeyCode()
        Return
    EndIf
    ; Never while a menu is open - the picker opens its own, and firing from
    ; inside one stacks menus.
    If Utility.IsInMenuMode()
        Return
    EndIf
    Int mod = HotkeyModifier()
    If mod != 0 && !Input.IsKeyPressed(mod)
        Return
    EndIf
    SNKin_Picker.OpenMenu()
EndEvent

Function RegisterEvents()
    { FMR fires these through _JSW_BB_Utility.SendDetailedTrackingEvent and
      SendTrackingEvent. The argument lists below are transcribed from those
      two functions and MUST match exactly - a mismatched handler signature
      means the event is delivered to nothing, silently.

        SendDetailedTrackingEvent pushes String, Form, String, String, Int
        SendTrackingEvent         pushes String, Form, Int }
    RegisterForModEvent("FertilityModeConception", "OnConception")
    RegisterForModEvent("FertilityModeLabor", "OnLabor")
    ; Mother died. Her children keep their record - a dead parent is still a
    ; parent, and a child asking after her is the whole point - but she stops
    ; being a delivery candidate.
    RegisterForModEvent("FMR_MotherDeath", "OnMotherDeath")
    ; Beeing Female NG. Registered unconditionally - an event nobody sends
    ; costs nothing, and gating on HasBfng here would miss a mid-playthrough
    ; install, since registrations are rebuilt on every load anyway.
    RegisterForModEvent("BeeingFemaleLabor", "OnBfLabor")
EndFunction

Function RegisterDecorators()
    { RegisterDecorator returns a status int. Log it: ignoring the return is
      how silent registration failures go unnoticed for weeks.

      rc=0 IS SUCCESS. Verified against the Romantasy mod, whose four
      decorators demonstrably resolve in live prompts and which logs
      rc=0 for every one of them on every load. A non-zero value here is the
      thing to worry about, not a zero. }
    Int a = SkyrimNetApi.RegisterDecorator("get_kinship", "SNKin_Decorators", "GetKinship")
    Int b = SkyrimNetApi.RegisterDecorator("kinship_is_child", "SNKin_Decorators", "IsChildOfPlayer")
    Int c = SkyrimNetApi.RegisterDecorator("kinship_is_parent", "SNKin_Decorators", "IsParentOfPlayersChild")
    Diag(LOG_INFO(), "RegisterDecorator rc (0 = ok): get_kinship=" + a + \
        " is_child=" + b + " is_parent=" + c)
EndFunction

Bool Function IsDynamicRef(Int aiFormID) Global
    { True for a reference created at runtime by PlaceActorAtMe - FormID
      0xFF000000-0xFFFFFFFF, which as a signed Papyrus Int is -16777216..-1.

      Deliberately a range comparison rather than bit shifting: Papyrus does
      not document whether Math.RightShift on a negative Int is arithmetic or
      logical, and the range test needs no such assumption.

      ESL references live at 0xFE......, which is -33554432..-16777217 and so
      falls BELOW this range rather than inside it. Checking `< 0` alone would
      wrongly match every ESL-plugin NPC in the load order. }
    Return aiFormID >= -16777216 && aiFormID < 0
EndFunction

; ===========================================================================
; FMR events - the mother side, captured exactly and at the right moment
; ===========================================================================

Event OnConception(String asEventName, Form akSender, String asMotherName, String asFatherName, Int aiIndex)
    { The ONLY moment the father is reliably known. FMR clears LastFather
      before recording it on the automatic birth path, so if we do not take it
      here we cannot recover it later. }
    If !IsEnabled()
        Return
    EndIf
    Actor mother = akSender as Actor
    If mother == None
        Return
    EndIf
    ; Father is compared by DISPLAY NAME because that is all FMR carries in
    ; this event. A player who renames himself mid-playthrough breaks the
    ; comparison for pregnancies conceived under the old name; there is no
    ; better key available and the failure is a missed link, not a wrong one.
    Bool byPlayer = (asFatherName == Game.GetPlayer().GetDisplayName())
    StorageUtil.SetStringValue(mother, "SNKin_LiveFather", asFatherName)
    StoreSetText(mother, "father", asFatherName)
    If byPlayer
        StorageUtil.SetIntValue(mother, "SNKin_ByPlayer", 1)
        CaptureFatherRef(mother, aiIndex, True)
        WatchAdd(mother)
        Diag(LOG_INFO(), "Conception: " + asMotherName + " by " + asFatherName + " (player) - watching.")
    Else
        StorageUtil.SetIntValue(mother, "SNKin_ByPlayer", 0)
        Diag(LOG_DEBUG(), "Conception: " + asMotherName + " by " + asFatherName + " - not the player, ignored.")
    EndIf
EndEvent

Event OnLabor(String asEventName, Form akSender, Int aiIndex)
    { Birth itself. The child does not exist yet - FMR gives the mother a baby
      item and only creates the child record BabyDuration days later - so this
      records WHO delivered and WHEN, and Sweep() pairs it up afterwards. }
    If !IsEnabled()
        Return
    EndIf
    Actor mother = akSender as Actor
    If mother == None
        Return
    EndIf
    ; TWO ways to qualify, and the second one is not redundant.
    ;
    ; The flag alone would drop every pregnancy that was already underway when
    ; this mod was installed - no conception event ever fired for those, so the
    ; flag was never set, and the birth would be silently ignored. That is the
    ; normal case for anyone adding this mid-playthrough.
    ;
    ; Storage.LastFather[index] is the authority at THIS moment specifically:
    ; _JSW_BB_BirthEffect copies CurrentFather into it as labor begins (:25),
    ; and CheckBabyGrowth does not clear it until the child record is created
    ; days later. So it is valid here and unusable afterwards - which is the
    ; whole reason this is read now rather than at RecordChild time.
    Bool byPlayer = (StorageUtil.GetIntValue(mother, "SNKin_ByPlayer", 0) == 1)
    String fatherNow = FatherNameAt(aiIndex)
    If fatherNow == Game.GetPlayer().GetDisplayName()
        byPlayer = True
    EndIf
    If !byPlayer
        ; LOGGED, because silence here cost two births. Without this line a
        ; rejected event and an event that never arrived look identical from
        ; outside, and the whole of the first investigation went the wrong way
        ; because of it.
        Diag(LOG_DEBUG(), "Labor from " + mother.GetDisplayName() + " ignored - father '" + \
            fatherNow + "' is not the player.")
        Return
    EndIf
    ; Capture the father if conception never told us - same reasoning as above.
    If StorageUtil.GetStringValue(mother, "SNKin_LiveFather", "") == "" && fatherNow != ""
        StorageUtil.SetStringValue(mother, "SNKin_LiveFather", fatherNow)
        StoreSetText(mother, "father", fatherNow)
    EndIf
    CaptureFatherRef(mother, aiIndex, False)
    StorageUtil.SetIntValue(mother, "SNKin_ByPlayer", 1)
    StorageUtil.SetFloatValue(mother, "SNKin_BornAt", Utility.GetCurrentGameTime())
    WatchAdd(mother)
    Diag(LOG_INFO(), "Labor: " + mother.GetDisplayName() + " delivered the player's child.")

    ; RECORD IT NOW when we own this childhood. Waiting for Fertility Mode to
    ; register the child would mean waiting for the day-ten maturation that
    ; taking the baby item exists to prevent - the circularity that made
    ; kinStageConfiscate inert. The watch list above still runs, because it
    ; costs nothing and is what the un-owned path depends on.
    If OwnsFmrBirth()
        Int dadId = 0
        Actor dad = Game.GetPlayer()
        If fatherNow == dad.GetDisplayName()
            dadId = dad.GetFormID()
        Else
            ; A FEMALE PLAYER'S CHILDREN HAVE AN NPC FATHER, and he needs the
            ; same reverse index a mother gets or he cannot speak about his own
            ; children. PersonIdByName returns 0 for ambiguity as well as
            ; absence, so two NPCs sharing a display name leave the link
            ; nameless rather than guessed - the rule the whole store follows.
            dadId = PersonIdByName(fatherNow)
        EndIf
        ClaimFmrBirth(mother, fatherNow, dadId)
    EndIf
EndEvent

String Function FatherNameAt(Int aiIndex)
    { The father's name for a tracked mother, CURRENT FIRST then LAST.

      THE ORDER IS THE WHOLE POINT, and reading it the other way round lost two
      births on the live save.

      FMR LISTENS TO ITS OWN EVENT. _JSW_BB_HandlerQuestAliasScript dispatches
      FertilityModeLabor at :1470, and its own OnFertilityModeLabor handler at
      :797 is what moves CurrentFather into LastFather at :807. So at the
      instant the event is broadcast, LastFather is still EMPTY and the father
      is in CurrentFather. Two independent SKSE listeners have no ordering
      guarantee between them, so reading LastFather here is a race we lose
      about as often as we win.

      Reading both, current first, is correct at every point in the sequence:
      before FMR's handler runs the answer is in CurrentFather, after it runs
      the answer is in LastFather, and only one of them is ever populated. }
    If _store == None || aiIndex < 0
        Return ""
    EndIf
    String[] current = _store.CurrentFather
    If current != None && aiIndex < current.Length && current[aiIndex] != ""
        Return current[aiIndex]
    EndIf
    String[] last = _store.LastFather
    If last != None && aiIndex < last.Length
        Return last[aiIndex]
    EndIf
    Return ""
EndFunction

Function CaptureFatherRef(Actor akMother, Int aiIndex, Bool abCurrent)
    { Stores the father as a FORM, not just a name.

      THE NAME ALONE MAKES THE MODEL ASYMMETRIC. A mother was recorded with a
      FormID and so could be asked "which children did you bear"; a father was
      recorded as a bare string and could not be asked anything. On a female-
      player playthrough that is the ENTIRE parent side missing - the NPC who
      fathered the child would answer known:0 forever.

      FMR has carried the Form all along and it was simply never read:
      CurrentFatherRef during pregnancy, LastFatherRef from labor until the
      child record is written. abCurrent selects which, because the conception
      event fires while it is still "current" and labor moves it to "last".

      Stored on the MOTHER because she is the one thing we can key on at this
      point - the child does not exist yet. RecordChild moves it onto the child
      when it does. Forms survive a save reload in StorageUtil; strings do not,
      which is why this is kept separately from SNKin_LiveFather rather than
      being derived from it. }
    If akMother == None || _store == None || aiIndex < 0
        Return
    EndIf
    ; CURRENT FIRST, THEN LAST - and abCurrent is now only a hint about which is
    ; more likely, never a restriction. Same race as FatherNameAt: FMR moves
    ; CurrentFatherRef into LastFatherRef inside its OWN handler for the very
    ; event that brought us here, so which one holds the father depends on
    ; whose listener ran first. Checking both removes the race entirely.
    Actor father = None
    Form[] refs = _store.CurrentFatherRef
    If refs != None && aiIndex < refs.Length
        father = refs[aiIndex] as Actor
    EndIf
    If father == None
        refs = _store.LastFatherRef
        If refs != None && aiIndex < refs.Length
            father = refs[aiIndex] as Actor
        EndIf
    EndIf
    If father == None
        Return
    EndIf
    ; NOBODY FATHERS A CHILD ON THEMSELVES. FMR can leave the mother in her own
    ; father slot after a futa self-insemination, and 1.0.4 clears only the
    ; Current arrays for those records - LastFatherRef, which the fallback above
    ; reads, keeps the stale self-reference.
    ;
    ; Capturing nothing is right. A blank father renders as someone the child
    ; has not been told about; the mother named twice would render as
    ; established fact that she bore a child to herself.
    If father == akMother
        Diag(LOG_WARN(), "Ignoring a father reference that is " + \
            akMother.GetDisplayName() + " herself.")
        Return
    EndIf
    StorageUtil.SetFormValue(akMother, "SNKin_LiveFatherRef", father)
    Diag(LOG_DEBUG(), "Captured father reference " + father.GetDisplayName() + \
        " for " + akMother.GetDisplayName() + ".")
EndFunction

Event OnMotherDeath(Form akMother, Int aiWasPregnant, Int aiHadBaby)
    Actor mother = akMother as Actor
    If mother == None
        Return
    EndIf
    ; Stop watching, but DO NOT touch her stored children. Death does not undo
    ; parentage, and a child asking after a mother who died is exactly the kind
    ; of thing this mod exists to make possible.
    WatchRemove(mother)
    StorageUtil.SetIntValue(mother, "SNKin_Awaiting", 0)
    Diag(LOG_INFO(), "Mother died: " + mother.GetDisplayName() + " - unwatched, records kept.")
EndEvent

; ===========================================================================
; The watch list
;
; Deliberately a SMALL explicit list rather than a scan of FMR's TrackedActors,
; which holds up to 256 entries. Only women carrying or delivering the player's
; child are ever on it, so the poll below stays a handful of array reads.
; ===========================================================================

Function WatchAdd(Actor akActor)
    If akActor == None
        Return
    EndIf
    StorageUtil.FormListAdd(None, "SNKin_Watch", akActor, False)
EndFunction

Function WatchRemove(Actor akActor)
    If akActor == None
        Return
    EndIf
    StorageUtil.FormListRemove(None, "SNKin_Watch", akActor, True)
EndFunction

; ===========================================================================
; The poll
; ===========================================================================

Event OnUpdateGameTime()
    { Game-time poll, matched to FMR's own cadence. FMR drives its whole
      simulation from RegisterForSingleUpdateGameTime(PollingInterval), so
      polling faster than it updates cannot find anything sooner and only
      spends Papyrus budget.

      ONUPDATEGAMETIME, NOT ONUPDATE. These are different events and the
      registration picks which one fires:

          RegisterForSingleUpdate(seconds)       -> OnUpdate()
          RegisterForSingleUpdateGameTime(hours) -> OnUpdateGameTime()

      This script registered the GAME TIME one and implemented the REAL TIME
      one, so the poll never fired even once. Papyrus reports nothing for this:
      no error, no warning, just an event that is never raised.

      It went unnoticed for the mod's whole life because Bootstrap also sweeps,
      and Bootstrap runs on every game load - so during development, where a
      save is loaded every few minutes, the sweep appeared to work. It only
      showed up in a long uninterrupted session: Fertility Mode kept polling on
      its own timer while this mod went silent for forty-three real minutes,
      and every sweep in the entire log turned out to be preceded by a
      "Bridge ready" line. }
    If _ready && IsEnabled()
        Sweep()
    EndIf
    RegisterForSingleUpdateGameTime(PollHours())
EndEvent

Function Sweep()
    { Two jobs, in order: notice deliveries, then notice new children.

      They are separate because FMR separates them. CheckBabyGrowth clears
      BabyAdded BEFORE calling GenerateName, and GenerateName BLOCKS on a menu
      the player may leave open indefinitely - so the delivery transition and
      the child record can land in different polls, or the same one, and this
      must be correct either way. }
    If _store == None
        Return
    EndIf

    ; RE-ENTRANCY GUARD, and it is not theoretical. On the first live run this
    ; ran EIGHT times concurrently: the quest OnInit, the alias OnInit and
    ; OnPlayerLoadGame all call Bootstrap with abForce, which by design defeats
    ; the time debounce, and orphaned quest instances left by an earlier
    ; install added more. The log showed 8 seed passes and 62 "Recorded child"
    ; lines for 23 children.
    ;
    ; The end state happened to be correct, because StringListAdd deduplicates
    ; and the record writes are idempotent. Two things were NOT safe:
    ;
    ;   - FOUR concurrent schema migrations each called ClearAll. Had a mother
    ;     been entered by hand, one migration could have wiped what another had
    ;     just rebuilt.
    ;   - ClaimAwaitingMother mutates SNKin_Awaiting. Two sweeps racing it
    ;     could hand the same mother to two children, or clear her flag between
    ;     one sweep's count and its claim.
    ;
    ; A MEMBER FLAG IS NOT ENOUGH, and a live save proved it.
    ;
    ; The claim used to be that "every caller is on the same script instance".
    ; It is false, and MigrateStore's own comment already said so - eight
    ; concurrent sweeps were observed on the first live run. The evidence turned
    ; up again in the log of a real birth: every line doubled, "Remembered 70
    ; new person/people" twice, and a tie's shortlist copied onto the child
    ; TWICE, giving six candidate entries where three were found.
    ;
    ; _sweeping guards one instance against itself and nothing against the
    ; others. So this takes the same process-wide lock MigrateStore does, with
    ; the same staleness escape - Papyrus has no try/finally, and a holder that
    ; died mid-sweep would otherwise stop every later sweep forever.
    ; A BARE BOOLEAN HERE WAS A PERMANENT FAILURE WAITING TO HAPPEN. Papyrus
    ; has no try/finally, so any error between setting it and clearing it would
    ; block this instance's sweep FOREVER - and with the poll now actually
    ; firing, that would take the whole mod down silently rather than costing
    ; one pass. Stamped instead, with the same staleness escape the schema lock
    ; and the process-wide lock below already use.
    Float lockNow = Utility.GetCurrentRealTime()
    If _sweepingSince > 0.0 && _sweepingSince <= lockNow && \
            (lockNow - _sweepingSince) < 30.0
        Return
    EndIf
    Float lockHeld = StorageUtil.GetFloatValue(None, "SNKin_SweepLock", 0.0)
    ; held > now means the value came from a previous session: real time counts
    ; from launch and resets, the same trap the Bootstrap debounce documents.
    If lockHeld > 0.0 && lockHeld <= lockNow && (lockNow - lockHeld) < 30.0
        Return
    EndIf
    StorageUtil.SetFloatValue(None, "SNKin_SweepLock", lockNow)
    _sweepingSince = lockNow

    MigrateStore()
    ; AFTER the schema migration, which may already have swept, and before
    ; anything reads a parent id. A reshuffled load order breaks records
    ; silently; this is the only thing that notices.
    CheckLoadOrderDrift()
    SeedPass()
    RememberPeople()
    ; AFTER RememberPeople, never before: it resolves names against the roster,
    ; so the roster has to be current or a name that could have been linked this
    ; sweep is left for the next one.
    RepairParentIds()
    NoteDeliveries()
    NoteNewChildren()
    ; Beeing Female's children arrive as spawned actors rather than through a
    ; registration array, so they are picked up by walking its own live list.
    ; Returns immediately when Beeing Female is absent.
    NoteBfChildren()
    DetectBfGrowUp()
    ; Babies already on the way when the feature was switched on. Runs before
    ; the naming prompt so an adopted birth can be named in the same sweep.
    AdoptInFlightBirths()
    ; Asks for one deferred name, and only when the player is able to answer.
    PromptPendingNames()
    BindSpawnedChildren()
    ; LAST, and it has to be. It publishes what the passes above just decided,
    ; so anything running earlier would export the previous sweep's answer.
    RefreshKinshipExports()

    _sweepingSince = 0.0
    StorageUtil.SetFloatValue(None, "SNKin_SweepLock", 0.0)
EndFunction

Function RememberPeople()
    { Accumulates a PERMANENT roster of everyone who could plausibly be a
      parent, so the editor has something to offer that FMR cannot take away.

      THIS EXISTS BECAUSE FMR'S LISTS EVAPORATE. Every recovery path that read
      TrackedActors has now failed the same way three times: Camilla and Ganna,
      then Danica and Nilsine, all pruned out of FMR's tracking within game
      hours of their babies maturing. At that point they cannot be named, cannot
      be offered in a list, and cannot be assigned except by physically walking
      up to them.

      A name and a FormID cost nothing to keep. Anyone FMR has EVER tracked
      while this mod was running is remembered here, in our own JSON, and stays
      selectable forever - including after FMR has forgotten them entirely.

      Two aligned lists rather than one keyed object, matching how candidates
      are stored: duplicates are impossible because entries are deduped by ID
      before insertion, so the alignment cannot drift. }
    If _store == None
        Return
    EndIf
    MigratePeople()

    ; THE PLAYER IS ALWAYS A CANDIDATE PARENT and was missing entirely - he is
    ; the father of nearly every child in the store, yet appeared in no
    ; dropdown, because the roster was seeded only from FMR's arrays and from
    ; recorded fatherIds, which were still 0 on older records.
    RememberPerson(Game.GetPlayer())

    ; BOTH of FMR's arrays. TrackedActors holds the women it follows cycles
    ; for; TrackedFathers holds the men it has recorded as fathers. Reading only
    ; the first is why the Father dropdown offered nothing but women - there
    ; were no men in the roster at all.
    Int added = RememberFrom(_store.TrackedActors, 0)
    added = RememberFrom(_store.TrackedFathers, added)
    ; Also seed from parents ALREADY recorded, so the editor is useful on the
    ; very first run rather than only for people met afterwards. Without this
    ; the roster starts empty and every mother recorded before today - Kayla,
    ; Camilla, Elisif and the rest - would be unavailable in the dropdown
    ; despite being right there in the store.
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int c = 0
    While c < n
        Int mId = JsonUtil.GetIntValue(StoreFile(), "child." + c + ".motherId", 0)
        If mId != 0
            Actor m = Game.GetFormEx(mId) as Actor
            If m != None
                AppendPerson(m)
                added += 1
            EndIf
        EndIf
        Int fId = JsonUtil.GetIntValue(StoreFile(), "child." + c + ".fatherId", 0)
        If fId != 0
            Actor f = Game.GetFormEx(fId) as Actor
            If f != None
                AppendPerson(f)
                added += 1
            EndIf
        EndIf
        c += 1
    EndWhile

    If added > 0
        JsonUtil.Save(StoreFile())
        Diag(LOG_INFO(), "Remembered " + added + " new person/people for the parent editor (" + \
            JsonUtil.IntListCount(StoreFile(), "people.ids") + " known).")
    EndIf
EndFunction

Int Function RememberFrom(Form[] akSource, Int aiAlready)
    { Adds the unseen actors from one FMR array, recording each one's SEX so
      the editor can offer men for fathers and women for mothers. Returns the
      running total added. }
    If akSource == None
        Return aiAlready
    EndIf
    Int added = aiAlready
    Int i = 0
    While i < akSource.Length
        Actor a = akSource[i] as Actor
        If a != None
                Int before = JsonUtil.IntListCount(StoreFile(), "people.ids")
                AppendPerson(a)
                If JsonUtil.IntListCount(StoreFile(), "people.ids") > before
                    added += 1
                EndIf
            EndIf
        i += 1
    EndWhile
    Return added
EndFunction

Function AppendPerson(Actor akActor) Global
    { One KEYED RECORD per person, not three parallel lists.

      THE PARALLEL-LIST DESIGN FAILED IN PRODUCTION. people.ids, people.names
      and people.sex were kept index-aligned by only ever appending together -
      and they drifted anyway: 206 ids against 266 sex entries, twelve exact
      duplicate FormIDs, and a female showing up under Fathers because the sex
      being read belonged to somebody else entirely.

      An invariant maintained by discipline across several call sites is not an
      invariant. Now each person is person.<id>.name and person.<id>.sex, which
      cannot misalign because there is nothing to align: the id IS the key.
      people.ids survives only as an enumeration index, and dedupe asks whether
      the record already exists rather than searching a list.

      Sex is 0 male, 1 female, matching GetSex, with -1 for unresolved. }
    If akActor == None
        Return
    EndIf
    Int id = akActor.GetFormID()
    If id == 0
        Return
    EndIf
    ; The record's own existence is the dedupe test - no list search, so a
    ; failed IntListFind cannot admit a duplicate.
    If JsonUtil.GetStringValue(StoreFile(), "person." + id + ".name", "") != ""
        Return
    EndIf

    ; AND THE SAME FORM UNDER A DIFFERENT RUNTIME ID. A light plugin's FormID
    ; encodes its load order position, so adding or removing any mod renumbers
    ; every ESL-sourced form and this function would file the same follower
    ; again. One accumulated four entries that way, three of them unusable.
    ;
    ; Keyed on name plus LOCAL id: the local is arithmetic on the id and holds
    ; across any load order, while the plugin name needs a live lookup that a
    ; stale index answers wrongly. O(1), because the alternative is scanning
    ; two hundred people on every add.
    String pk = "pkey." + akActor.GetDisplayName() + "." + LocalFormId(id)
    If IsLightFormId(id)
        pk += ".L"
    EndIf
    Int known = JsonUtil.GetIntValue(StoreFile(), pk, 0)
    If known != 0 && known != id && Game.GetFormEx(known) != None
        Return
    EndIf
    JsonUtil.SetIntValue(StoreFile(), pk, id)

    ; THE SOURCE PLUGIN, CAPTURED NOW WHILE THE FORM IS STILL ALIVE.
    ;
    ; This is the whole difference between a repairable record and a lost one. A
    ; dead FormID cannot be decoded after the fact - its index names whatever mod
    ; occupies that slot today, and three dead entries for one follower decoded
    ; to cowperktree.esp, companionsskillltree.esp and mawassets.esp. Written
    ; here, the pair survives any reshuffle and repair becomes a direct lookup
    ; rather than a search for a surviving twin.
    ;
    ; Runtime spawns get "" and are skipped: they have no source file and cannot
    ; outlive the save anyway.
    String plug = SourcePlugin(id)
    If plug != ""
        JsonUtil.SetStringValue(StoreFile(), "person." + id + ".plugin", plug)
        JsonUtil.SetIntValue(StoreFile(), "person." + id + ".local", LocalFormId(id))
    EndIf
    Int sex = -1
    If akActor.GetActorBase() != None
        sex = akActor.GetActorBase().GetSex()
    EndIf
    JsonUtil.SetStringValue(StoreFile(), "person." + id + ".name", akActor.GetDisplayName())
    JsonUtil.SetIntValue(StoreFile(), "person." + id + ".sex", sex)
    JsonUtil.IntListAdd(StoreFile(), "people.ids", id, False)
EndFunction

Function MigratePeople() Global
    { Converts the old parallel-list roster to keyed records, ONCE.

      The old lists are known to be corrupt on at least one live save -
      duplicated ids and a sex list 60 entries longer than the id list - so this
      does not attempt to preserve them faithfully. It re-derives each person
      from their FormID, which is the one field that was never in doubt, and
      discards the rest. Anything unresolvable is simply dropped and will be
      re-learned the next time FMR reports them. }
    If JsonUtil.GetIntValue(StoreFile(), "peopleSchema", 0) == 1
        Return
    EndIf
    Int n = JsonUtil.IntListCount(StoreFile(), "people.ids")
    Int kept = 0
    Int i = 0
    While i < n
        Int id = JsonUtil.IntListGet(StoreFile(), "people.ids", i)
        Actor a = Game.GetFormEx(id) as Actor
        If a != None
            ; AppendPerson re-adds to people.ids, so clear it first or every
            ; surviving entry would be listed twice over.
            kept += 1
        EndIf
        i += 1
    EndWhile

    ; Rebuild from scratch: wipe the index, then re-add what resolves.
    Form[] resolved = new Form[128]
    Int r = 0
    i = 0
    While i < n && r < 128
        Actor a = Game.GetFormEx(JsonUtil.IntListGet(StoreFile(), "people.ids", i)) as Actor
        If a != None && resolved.Find(a) < 0
            resolved[r] = a
            r += 1
        EndIf
        i += 1
    EndWhile

    JsonUtil.IntListClear(StoreFile(), "people.ids")
    JsonUtil.StringListClear(StoreFile(), "people.names")
    JsonUtil.IntListClear(StoreFile(), "people.sex")
    i = 0
    While i < r
        AppendPerson(resolved[i] as Actor)
        i += 1
    EndWhile
    JsonUtil.SetIntValue(StoreFile(), "peopleSchema", 1)
    JsonUtil.Save(StoreFile())
    Diag(LOG_WARN(), "Rebuilt the people roster as keyed records: " + n + \
        " old entries in, " + r + " distinct people out.")
EndFunction

Function RememberPerson(Actor akActor) Global
    { Adds one actor to the permanent roster. Called whenever a parent is set,
      so anyone chosen by hand - via the crosshair, say - remains offerable
      later even if FMR never tracked them at all. }
    If akActor == None
        Return
    EndIf
    AppendPerson(akActor)
    JsonUtil.Save(StoreFile())
EndFunction

Function SeedPass()
    { Runs exactly once, on the first sweep after installation.

      Children who already existed cannot have their MOTHER recovered - FMR
      never stored it, and there is nothing in the save that implies it. Their
      FATHER is recoverable, because PlayerChildName only ever receives the
      player's children, so seeding records the father and leaves the mother
      blank for SetParentage to fill in by hand.

      With seeding off, the pre-existing names go on an `ignored` list instead.
      That is NOT the same as doing nothing: without it, the very first sweep
      would see every old child as brand new and record it anyway, which is
      precisely what the setting is meant to prevent. }
    If JsonUtil.GetIntValue(StoreFile(), "seeded", 0) == 1
        Return
    EndIf
    String[] names = _store.PlayerChildName
    If names == None
        ; FMR has not finished initialising its arrays. Its own property
        ; getters throw "Cannot cast from None to Form[]" in this window, which
        ; Papyrus logs and continues past. Retry on the next poll rather than
        ; burning the one-shot seed on an empty read - marking seeded here
        ; would permanently skip every child the player already has.
        Return
    EndIf

    If !SeedExisting()
        Int i = 0
        While i < names.Length
            If names[i] != ""
                JsonUtil.StringListAdd(StoreFile(), "ignored", names[i], False)
            EndIf
            i += 1
        EndWhile
        Diag(LOG_INFO(), "Seeding disabled - existing children ignored, only future births tracked.")
    Else
        Diag(LOG_INFO(), "First sweep: seeding existing children with the player as father.")
    EndIf

    JsonUtil.SetIntValue(StoreFile(), "seeded", 1)
    ; WHEN, not just whether. Every child seeded in this pass gets `born` set to
    ; this instant, because that is when the record was made - it says nothing
    ; about their age. Life stages need to tell those apart from genuine births:
    ; a child born at 177.9 really is a newborn, while twenty-three children all
    ; born at 163.13 are one seeding batch of unknown ages wearing a timestamp.
    ; Without this the two are indistinguishable and every seeded child has to
    ; be planted by hand.
    JsonUtil.SetFloatValue(StoreFile(), "seedAt", Utility.GetCurrentGameTime())
    JsonUtil.Save(StoreFile())
EndFunction

Function AdoptBabiesInFlight()
    { Picks up mothers who are ALREADY carrying the player's baby at install.

      Their labor fired before this mod existed, so OnLabor never saw it and
      they are on no watch list. Without this they would deliver into a child
      record with no mother, for no reason the player could ever discover.

      The window is identifiable precisely: BabyAdded > 0 means a baby item is
      being carried, and LastFather still holds the father's name because
      CheckBabyGrowth does not clear it until the child record is written. Both
      conditions are true only during exactly this window.

      A ONE-TIME bounded scan over TrackedActors (up to 256), which is why it
      lives in the seed pass and not in the poll. }
    Form[] tracked = _store.TrackedActors
    Float[] babyAdded = _store.BabyAdded
    If tracked == None || babyAdded == None
        Return
    EndIf
    String playerName = Game.GetPlayer().GetDisplayName()
    Int adopted = 0
    Int i = 0
    While i < tracked.Length
        Actor mother = tracked[i] as Actor
        ; FatherNameAt, not LastFather directly - same current-then-last
        ; reasoning, and this runs at an arbitrary moment in FMR's cycle rather
        ; than at a known point in it.
        ; NO FATHER-NAME FILTER. It used to require FatherNameAt == the player,
        ; and on the live save that is EMPTY for every carrying mother - so this
        ; adopted nobody and two births went unwatched. Carrying a baby at all
        ; is enough to be worth watching; FMR only ever creates a child record
        ; for the player's children anyway (the gate in CheckBabyGrowth), so a
        ; mother watched in vain simply never produces one.
        If mother != None && i < babyAdded.Length && \
           StorageUtil.GetIntValue(mother, "SNKin_ByPlayer", 0) != 1
            If babyAdded[i] > 0.0
                StorageUtil.SetIntValue(mother, "SNKin_ByPlayer", 1)
                StorageUtil.SetStringValue(mother, "SNKin_LiveFather", playerName)
                StoreSetText(mother, "father", playerName)
                ; Take the father REFERENCE too, not just the name. Omitting
                ; this is why Gaius has a father called Haruk and a fatherId of
                ; 0. Usually the arrays are empty by now - which is why the name
                ; fallback exists - but when FMR still holds a real NPC father
                ; this is the only chance to capture him, and on a female-player
                ; save he is the only parent worth recording an ID for.
                CaptureFatherRef(mother, i, True)
                ; Seed the transition watcher with the CURRENT value, so the
                ; fall to 0.0 is still seen as a transition rather than being
                ; mistaken for the -1.0 "never looked" state.
                StorageUtil.SetFloatValue(mother, "SNKin_LastBaby", babyAdded[i])
                WatchAdd(mother)
                adopted += 1
            EndIf
        EndIf
        i += 1
    EndWhile
    If adopted > 0
        Diag(LOG_INFO(), "Adopted " + adopted + " mother(s) already carrying the player's baby.")
    EndIf
EndFunction

Function NoteDeliveries()
    { Watches BabyAdded fall from >0 to 0, which is FMR's own signal that a
      baby has finished growing and a child record is about to be written. }
    Form[] tracked = _store.TrackedActors
    If tracked == None || tracked.Length == 0
        Return
    EndIf
    Float[] babyAdded = _store.BabyAdded
    If babyAdded == None
        Return
    EndIf

    Int i = StorageUtil.FormListCount(None, "SNKin_Watch")
    While i > 0
        i -= 1
        Actor mother = StorageUtil.FormListGet(None, "SNKin_Watch", i) as Actor
        If mother != None
            Int idx = tracked.Find(mother)
            If idx >= 0 && idx < babyAdded.Length
                Float prev = StorageUtil.GetFloatValue(mother, "SNKin_LastBaby", -1.0)
                Float cur = babyAdded[idx]
                StorageUtil.SetFloatValue(mother, "SNKin_LastBaby", cur)
                If prev > 0.0 && cur == 0.0
                    ; Her baby just matured into a child record.
                    StorageUtil.SetIntValue(mother, "SNKin_Awaiting", 1)
                    ; STAMPED WITH WHEN SHE GAVE BIRTH, NOT WHEN WE NOTICED.
                    ;
                    ; `prev` is her own BabyAdded - the moment Fertility Mode
                    ; handed her the baby item. GetCurrentGameTime() was the
                    ; moment this sweep ran, which is the same value for every
                    ; mother noticed in the same pass, and that is what produced
                    ; false ties on a live save: Fenja and Hermir delivered an
                    ; hour apart (181.5910 against 181.6342) and were recorded
                    ; as indistinguishable, because the evidence that separated
                    ; them was overwritten with "now".
                    ;
                    ; The sweep runs hourly, so anything finer than an hour was
                    ; being thrown away every single time. This keeps it.
                    StorageUtil.SetFloatValue(mother, "SNKin_AwaitingAt", prev)
                    ; TWO CLOCKS, BECAUSE THEY ANSWER TWO QUESTIONS.
                    ;
                    ; AwaitingAt is WHEN SHE GAVE BIRTH and orders the claim -
                    ; the earliest delivery is matched first. AwaitingSince is
                    ; WHEN WE NOTICED and drives expiry, which asks how long a
                    ; flag has gone unresolved.
                    ;
                    ; Conflating them retires a mother the moment she becomes
                    ; relevant. Ingun Black-Briar's baby took twenty-two days to
                    ; mature, so the instant her flag was raised it was already
                    ; older than the staleness window and was retired 0.9 days
                    ; later - discarding a delivery that had only just happened.
                    StorageUtil.SetFloatValue(mother, "SNKin_AwaitingSince", \
                        Utility.GetCurrentGameTime())
                    Diag(LOG_INFO(), "Delivery matured: " + mother.GetDisplayName() + " awaiting a child record.")
                EndIf
            EndIf
        EndIf
    EndWhile
EndFunction

Function NoteNewChildren()
    { Reconciles FMR's PlayerChildName array against our roster.

      Keyed on NAME, not on array index: FMR's PlayerChildRemove SHIFTS every
      later entry down, so an index is not a stable identity. FMR enforces name
      uniqueness at naming time (PlayerChildName.Find(proposedName) == -1), so
      a name is. }
    String[] names = _store.PlayerChildName
    If names == None || names.Length == 0
        Return
    EndIf
    Int[] genders = _store.PlayerChildGender
    String[] races = _store.PlayerChildRace
    String[] fathers = _store.PlayerChildFatherName

    Int i = 0
    While i < names.Length
        String nm = names[i]
        If nm != "" && !HasChild(nm)
            String gender = ""
            If genders != None && i < genders.Length && genders[i] == 1
                gender = "daughter"
            ElseIf genders != None && i < genders.Length
                gender = "son"
            EndIf
            ; NOT "race" - Race is a Papyrus type, and naming a local after one
            ; fails with "cannot name a variable or property the same as a
            ; known type or script".
            String raceName = ""
            If races != None && i < races.Length
                raceName = races[i]
            EndIf
            String fmrFather = ""
            If fathers != None && i < fathers.Length
                fmrFather = fathers[i]
            EndIf
            ; The duplicate guard lives in RecordChild, where the mother has
            ; actually been resolved. Testing it here would only know that SOME
            ; claimed birth was pending, not whether it was THIS one - and would
            ; drop a legitimate child whenever an unrelated claim was in flight.
            RecordChild(nm, gender, raceName, fmrFather)
        EndIf
        i += 1
    EndWhile
EndFunction

Function RecordChild(String asName, String asGender, String asRace, String asFmrFather)
    { Writes one child. FAILS CLOSED on maternity: an unresolvable mother
      records the father link only and leaves the mother blank forever rather
      than guessing. A wrong mother is permanent, is rendered as fact, and is
      worse than silence. }
    Actor mother = ClaimAwaitingMother()

    ; FALLBACK: nothing was awaiting, so ask FMR's data who just matured.
    ;
    ; This is not belt-and-braces, it is the path that actually works. The watch
    ; list depends on having captured a labour, which depends on the father's
    ; name being readable at that instant - and on the live save it is empty for
    ; every carrying mother, so the watch list stayed empty through two real
    ; births. Deriving the answer from state at record time needs nothing to
    ; have been observed ten days earlier.
    ;
    ; A tolerance of one day: the only imprecision is our poll interval and
    ; FMR's, both an hour or less, so a day is generous without being loose
    ; enough to pull in an unrelated birth.
    ; DERIVED HERE, NEVER HANDED OVER FROM ClaimAwaitingMother.
    ;
    ; The shortlist used to be passed through a _tieCandidates member variable
    ; set inside ClaimAwaitingMother. On the live save that silently arrived
    ; EMPTY: Danica and Nilsine tied, the tie was detected and logged, and both
    ; children were still written with no mother and no candidates. The same
    ; JsonUtil calls invoked from ResolveByBirthSignature - which builds its
    ; list in a LOCAL - worked on the very same records moments later, which is
    ; what identified the hand-off rather than the write as the fault.
    ;
    ; Rather than chase why a member array does not survive the call, the
    ; hand-off is gone: the shortlist is computed where it is consumed, by the
    ; one method already proven to work. ClaimAwaitingMother now only answers
    ; the yes/no question it is named for.
    Form[] shortlist
    If mother == None
        ; THE TIE'S OWN LIST FIRST, written by ClaimAwaitingMother at the instant
        ; it detected the tie. It needs nothing from FMR and no time window, so
        ; it is right even when FMR has already moved on - the case that left
        ; Almed with a logged tie and an empty shortlist.
        shortlist = PendingCandidates()
        If shortlist.Length == 0
            ; Nothing was flagged. Fall back to reading who matured, which also
            ; covers births the watch list never saw at all.
            shortlist = MothersMaturedRecently(1.0)
        EndIf
        If shortlist.Length == 1
            mother = shortlist[0] as Actor
            Diag(LOG_INFO(), "No single watched mother, but " + mother.GetDisplayName() + \
                " is the only one whose baby matured just now.")
        ElseIf shortlist.Length > 1
            Diag(LOG_WARN(), shortlist.Length + " mothers matured together - recording a " + \
                "candidate list instead of guessing.")
        EndIf
    EndIf

    String motherName = ""
    Int motherId = 0
    String father = ""
    Int fatherId = 0

    If mother != None
        motherName = mother.GetDisplayName()
        motherId = mother.GetFormID()
        father = StorageUtil.GetStringValue(mother, "SNKin_LiveFather", "")
        If father == ""
            father = StoreGetText(mother, "father")
        EndIf
        ; The father as a REFERENCE, captured at conception or labor. This is
        ; what lets him be asked about his children too - see CaptureFatherRef.
        Actor fatherRef = StorageUtil.GetFormValue(mother, "SNKin_LiveFatherRef") as Actor
        If fatherRef != None
            fatherId = fatherRef.GetFormID()
            If father == ""
                father = fatherRef.GetDisplayName()
            EndIf
        EndIf
    EndIf

    ; Father fallback ladder, most trustworthy first:
    ;   1. what we captured at conception or labour (above)
    ;   2. FMR's own record, IF it is not the "Unknown" the automatic path
    ;      always writes - see the header note
    ;   3. the player, because PlayerChildName only ever receives the player's
    ;      children (the gate at HandlerQuestAliasScript:1570)
    Actor player = Game.GetPlayer()
    If father == "" && asFmrFather != "" && asFmrFather != "Unknown"
        father = asFmrFather
    EndIf
    ; RUNG 3 IS GATED ON THE PLAYER NOT BEING THE MOTHER. Without that guard, a
    ; FEMALE player bearing an NPC's child is recorded as her own child's
    ; father: the gate at :1570 only says the child is the PLAYER'S, and when
    ; she carried it herself that says nothing whatever about who fathered it.
    ; Leaving the name blank is correct there - it is genuinely unknown, and the
    ; prompt already renders an unknown parent as someone nobody has told.
    If father == "" && mother != player
        father = player.GetDisplayName()
    EndIf

    ; Make the ID agree with the NAME. This is not a new inference: if the
    ; father is recorded as the player, the player's FormID is simply the same
    ; fact written the other way. Leaving it at 0 meant a father with a name and
    ; no reverse index - so he could be described in a child's bio but could
    ; never be ASKED about his own children, which is exactly the asymmetry
    ; schema 3 existed to remove. Gaius shipped that way.
    If fatherId == 0 && father != "" && father == player.GetDisplayName()
        fatherId = player.GetFormID()
    EndIf

    ; A CHILD CANNOT HAVE THE SAME PARENT TWICE. SetParentStatic refuses this on
    ; the manual path; nothing refused it here, and the automatic path can reach
    ; it - every rung of the ladder above can yield the mother. FMR's father
    ; slots can hold her after a futa self-insemination, and asFmrFather is
    ; whatever FMR stored.
    ;
    ; Belt and braces to CaptureFatherRef's own check, deliberately: that one
    ; only sees the reference, and the NAME arrives by three other routes.
    ;
    ; Blank, never the mother. An unknown father reads as someone the child has
    ; not been told about, which is true; naming her twice would render in the
    ; child's own bio as established fact that she bore a child to herself.
    If (fatherId != 0 && fatherId == motherId) || \
       (father != "" && motherName != "" && father == motherName)
        Diag(LOG_WARN(), "RecordChild: the father resolved to the mother (" + \
            motherName + ") for '" + asName + "' - recording him as unknown instead.")
        father = ""
        fatherId = 0
    EndIf

    ; ONE CHILD, ONE RECORD. Reachable only when confiscation missed: if the
    ; item had been taken, Fertility Mode could never have got as far as naming
    ; this child. So the mother was untracked at the moment we tried, or a
    ; Fertility Mode update moved the gate.
    ;
    ; Checked HERE rather than in NoteNewChildren because this is the first
    ; point at which the mother is actually known. Asking earlier could only
    ; establish that SOME claim was pending, and would drop a legitimate child
    ; whenever an unrelated birth happened to be in flight.
    ;
    ; TAKE THE NAME RATHER THAN DISCARDING IT. Fertility Mode reaching this
    ; point means it prompted the player, so this name is very likely the one
    ; they chose - better than the placeholder the claim is carrying.
    Int claimed = OwnedBirthFor(motherId)
    If claimed >= 0
        If JsonUtil.GetIntValue(StoreFile(), "child." + claimed + ".needsName", 0) == 1
            RenameChildRecord(claimed, asName)
            Diag(LOG_WARN(), "Fertility Mode named '" + asName + "' before the baby item " + \
                "could be taken. Keeping the claimed record and adopting that name " + \
                "rather than recording the child twice.")
        Else
            Diag(LOG_WARN(), "Fertility Mode registered '" + asName + "' for a birth this " + \
                "mod already claimed as '" + JsonUtil.GetStringValue(StoreFile(), \
                "child." + claimed + ".name", "?") + "'. Not recording it twice.")
        EndIf
        Return
    EndIf

    ; Append to the roster FIRST - the index it lands at is the record key.
    JsonUtil.StringListAdd(StoreFile(), "roster", asName, False)
    Int idx = JsonUtil.StringListFind(StoreFile(), "roster", asName)
    If idx < 0
        Diag(LOG_ERROR(), "RecordChild: '" + asName + "' would not stay on the roster - not recorded.")
        Return
    EndIf

    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".name", asName)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".father", father)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".mother", motherName)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".motherId", motherId)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".fatherId", fatherId)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".gender", asGender)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".race", asRace)
    JsonUtil.SetFloatValue(StoreFile(), "child." + idx + ".born", Utility.GetCurrentGameTime())
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".source", SRC_FMR())
    ; A GROUP OF ONE, not a blank. Fertility Mode delivers a single child per
    ; pregnancy, so every one of its children is an only child of that birth -
    ; which is a fact, not an absence. Giving it a real group id means "who
    ; shared your birth" is answered the same way for both sources instead of
    ; needing to know which mod recorded you.
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".birthGroup", NextBirthGroup())

    ; BOTH parents get a reverse index, by the same rule and with no special
    ; case for either. A female player's children have an NPC father, and he
    ; must be able to speak about them exactly as a mother would.
    If motherId != 0
        JsonUtil.IntListAdd(StoreFile(), ParentPath(motherId), idx, False)
    EndIf
    If fatherId != 0
        JsonUtil.IntListAdd(StoreFile(), ParentPath(fatherId), idx, False)
    EndIf
    JsonUtil.Save(StoreFile())

    ; Carry a tie's shortlist onto the child so it can be resolved later.
    ; Both lists ALLOW DUPLICATES so their indices stay aligned - deduplicating
    ; the names would shift them out of step with the FormIDs the moment two
    ; candidates shared a display name, and silently assign the wrong mother.
    Int nCand = 0
    If mother == None && shortlist != None && shortlist.Length > 1
        Int cand = 0
        While cand < shortlist.Length
            Actor c = shortlist[cand] as Actor
            If c != None
                JsonUtil.IntListAdd(StoreFile(), "child." + idx + ".candidates", c.GetFormID(), True)
                JsonUtil.StringListAdd(StoreFile(), "child." + idx + ".candidateNames", c.GetDisplayName(), True)
            EndIf
            cand += 1
        EndWhile
        nCand = shortlist.Length
    EndIf
    JsonUtil.Save(StoreFile())

    If mother != None
        Diag(LOG_INFO(), "Recorded child " + asName + ": mother " + motherName + ", father " + father + ".")
        If Notify()
            Debug.Notification("[Kinship] " + asName + " - " + motherName + " and " + father)
        EndIf
    ElseIf nCand > 0
        Diag(LOG_WARN(), "Recorded child " + asName + " with father " + father + \
            " and " + nCand + " possible mothers. Resolve it from the in-game menu.")
        If Notify()
            Debug.Notification("[Kinship] " + asName + " needs a mother chosen (" + nCand + " possible)")
        EndIf
    Else
        Diag(LOG_WARN(), "Recorded child " + asName + " with father " + father + \
            " and NO mother - none awaiting, or more than one. Set it by hand with SetParentage.")
        If Notify()
            Debug.Notification("[Kinship] " + asName + " recorded without a mother")
        EndIf
    EndIf
EndFunction

Form[] Function MothersMaturedRecently(Float afTolerance)
    { Every tracked mother whose baby matured about now, found from FMR's own
      data with no prior watching required.

      THE SIGNATURE: babyAdded == 0 (the item is gone) together with lastBirth
      roughly BabyDuration days back (she carried it the full term). FMR zeroes
      babyAdded at the moment it names the child, so a mother matching this has
      just produced one.

      THIS IS NOW THE PRIMARY IDENTIFICATION, and the watch list is a fallback
      rather than the other way round. The watch list is built by
      AdoptBabiesInFlight and OnLabor, both of which key off the father's name -
      and on the live save that name is EMPTY for every carrying mother, so
      neither ever fired. Camilla and Ganna carried the player's children for
      ten days, matured, and were never once watched; Titus and Leif recorded
      with no mother and not even a candidate list, because nothing was
      awaiting to tie.

      Deriving it from state, at the moment it matters, depends on nothing
      having been observed earlier - which is the property the watch list
      lacked. Returns an empty array rather than None when nothing matches. }
    Form[] hits = new Form[8]
    Int n = 0
    If _store == None
        Return Utility.ResizeFormArray(hits, 0)
    EndIf
    Float dur = BabyDurationDays()
    If dur <= 0.0
        Return Utility.ResizeFormArray(hits, 0)
    EndIf
    Form[] tracked = _store.TrackedActors
    Float[] births = _store.LastBirth
    Float[] babies = _store.BabyAdded
    If tracked == None || births == None || babies == None
        Return Utility.ResizeFormArray(hits, 0)
    EndIf
    Float now = Utility.GetCurrentGameTime()
    Int i = 0
    While i < tracked.Length && n < 8
        Actor a = tracked[i] as Actor
        If a != None && i < births.Length && i < babies.Length
            If babies[i] == 0.0 && births[i] > 0.0
                Float ago = now - births[i]
                If ago >= (dur - afTolerance) && ago <= (dur + afTolerance)
                    hits[n] = a
                    n += 1
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    Return Utility.ResizeFormArray(hits, n)
EndFunction

Bool Function HasChildBornSince(Int aiParentFormID, Float afSince) Global
    { True when this parent already has a recorded child born at or after the
      given moment.

      Reads the reverse index rather than scanning the roster, so it costs one
      walk over this parent's own children - typically one or two entries.
      Hidden records do not count: a tombstoned child is one the player said
      does not belong to this playthrough, and it cannot be the answer to a
      delivery that is still outstanding. }
    If aiParentFormID == 0
        Return False
    EndIf
    String path = ParentPath(aiParentFormID)
    Int n = JsonUtil.IntListCount(StoreFile(), path)
    Int i = 0
    While i < n
        Int idx = JsonUtil.IntListGet(StoreFile(), path, i)
        If JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".hidden", 0) != 1
            If JsonUtil.GetFloatValue(StoreFile(), "child." + idx + ".born", 0.0) >= afSince
                Return True
            EndIf
        EndIf
        i += 1
    EndWhile
    Return False
EndFunction

Actor Function ClaimAwaitingMother()
    { Returns the mother who bore the child now being recorded, or None.

      ONE candidate is the easy case. With SEVERAL, this claims the one who
      delivered EARLIEST - but only when that earliest time is unique.

      That is not a coin flip, and the distinction matters. FMR creates child
      records one at a time, in the order it clears each mother's BabyAdded,
      and we observe those clears with timestamps. So when two mothers matured
      in DIFFERENT sweeps the order between them is genuinely known, and
      first-delivered-first-recorded is the mechanism rather than a guess.

      A TIE - two mothers whose babies matured inside the same sweep - carries
      no such evidence, and there this still FAILS CLOSED and records nothing.
      A blank mother is logged, visible, and fixable with one SetParentage
      call. A wrong one is permanent, renders in the child's own bio as
      established fact, and would never be noticed.

      This matters in practice rather than in theory: six mothers were carrying
      the player's child simultaneously on the save this was written against,
      and under the old "exactly one or nothing" rule most of those births
      would have lost their mother for no recoverable reason. }
    Int n = StorageUtil.FormListCount(None, "SNKin_Watch")
    Actor best = None
    Float bestAt = 0.0
    Int found = 0
    Int tied = 0
    ; Every awaiting mother, kept so a tie can be HANDED ON rather than thrown
    ; away. Capped at 8: more than that in one sweep is not a tie, it is a
    ; population, and a picker with nine identical-looking rows helps nobody.
    Form[] awaiting = new Form[8]
    Int nAwaiting = 0

    ; A FLAG THAT WAS NEVER RESOLVED MUST NOT OUTRANK A BIRTH HAPPENING NOW.
    ;
    ; This is the bug that put the WRONG mothers on a real child. SNKin_Awaiting
    ; is cleared on the success path and left alone everywhere else, so a mother
    ; whose child was assigned by hand - or never recorded at all - stays flagged
    ; forever. And since `best` is the EARLIEST awaiting, a stale flag always
    ; wins.
    ;
    ; On the live save Danica Pure-Spring and Nilsine Shatter-Shield had been
    ; sitting flagged from an earlier birth. When Fenja and Hermir delivered,
    ; the tie was computed among the two stale ones, and the shortlist recorded
    ; on both children named neither mother who had actually just given birth.
    ; The picker could not have produced the right answer from it.
    ;
    ; Expiry is generous on purpose - a flag is only wrong once it is older than
    ; any birth it could still belong to. AwaitingAt is now the mother's own
    ; BabyAdded, so the age of the flag is the age of the BIRTH, and a birth
    ; older than a full baby duration plus slack has either been recorded
    ; already or is never going to be.
    Float staleAfter = BabyDurationDays()
    If staleAfter <= 0.0
        staleAfter = 14.0
    EndIf
    staleAfter += 5.0
    Float rightNow = Utility.GetCurrentGameTime()

    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNKin_Watch", i) as Actor
        If a != None && StorageUtil.GetIntValue(a, "SNKin_Awaiting", 0) == 1
            Float at = StorageUtil.GetFloatValue(a, "SNKin_AwaitingAt", 0.0)

            ; ALREADY ANSWERED. Self-healing, and it is what retires flags left
            ; behind before any of this existed - including one assigned by hand
            ; before SetParent learned to clear it.
            ;
            ; If she already has a child recorded whose birth is at or after
            ; this delivery, that delivery HAS produced a record and the flag is
            ; a leftover. A mother who delivers again gets a fresh, later
            ; AwaitingAt, so a new pregnancy cannot be cancelled by an old child.
            If at > 0.0 && HasChildBornSince(a.GetFormID(), at - 0.05)
                StorageUtil.SetIntValue(a, "SNKin_Awaiting", 0)
                Diag(LOG_INFO(), "Cleared " + a.GetDisplayName() + \
                    "'s pending delivery - a child of hers is already recorded for it.")
                a = None
            EndIf

            ; TOO OLD TO STILL BE WAITING, measured from when we NOTICED rather
            ; than from the birth. See the two-clock note where these are
            ; stamped: a baby that took longer than the window to mature would
            ; otherwise be retired the moment it finally arrived, which is what
            ; happened to Ingun Black-Briar.
            ;
            ; A flag raised by an older build has no AwaitingSince. Treating
            ; that as infinitely old would retire every pending mother on the
            ; first sweep after upgrading, so it falls back to the birth stamp -
            ; the previous behaviour, which is right for exactly those flags.
            If a != None
                Float since = StorageUtil.GetFloatValue(a, "SNKin_AwaitingSince", 0.0)
                If since <= 0.0
                    since = at
                EndIf
                If since > 0.0 && (rightNow - since) > staleAfter
                    ; Retire it rather than skipping it, or every later sweep
                    ; pays the same lookup to reach the same conclusion.
                    StorageUtil.SetIntValue(a, "SNKin_Awaiting", 0)
                    ; INFO, NOT DEBUG. This fires at most once per stale flag
                    ; ever, and it is the visible trace of the defect that put
                    ; two wrong mothers on a real child. At debug it would be
                    ; invisible at the default log level - which is to say,
                    ; invisible exactly when someone is working out why a tie
                    ; resolved oddly.
                    Diag(LOG_INFO(), "Retired a stale delivery flag on " + \
                        a.GetDisplayName() + " - it was " + (rightNow - since) + \
                        " days old and no child was ever recorded against it.")
                    a = None
                EndIf
            EndIf
        EndIf
        If a != None && StorageUtil.GetIntValue(a, "SNKin_Awaiting", 0) == 1
            Float at = StorageUtil.GetFloatValue(a, "SNKin_AwaitingAt", 0.0)
            found += 1
            If nAwaiting < 8
                awaiting[nAwaiting] = a
                nAwaiting += 1
            EndIf
            If best == None || at < bestAt
                best = a
                bestAt = at
                tied = 0
            ElseIf at == bestAt
                tied += 1
            EndIf
        EndIf
        i += 1
    EndWhile

    If found == 0
        ClearPendingCandidates()
        Return None
    EndIf
    If tied > 0
        ; FAILS CLOSED on the mother, but the SHORTLIST IS WRITTEN HERE, to the
        ; store, at the moment the tie is known.
        ;
        ; Two earlier designs both lost it. Handing the array back through a
        ; member variable arrived empty and cost Danica and Nilsine theirs.
        ; Re-deriving it in RecordChild from MothersMaturedRecently cured that
        ; and introduced a different hole: the tie is detected from OUR durable
        ; SNKin_Awaiting flags, while the derivation reads FMR's LastBirth and
        ; only matches inside BabyDuration +/- tolerance. When those disagree the
        ; tie is logged and the candidates are still empty - which is exactly how
        ; Almed was recorded with no mother and no shortlist.
        ;
        ; A JsonUtil write needs no hand-off and no window. The evidence exists
        ; right here; this is where it gets persisted.
        JsonUtil.IntListClear(StoreFile(), "pending.candidates")
        JsonUtil.StringListClear(StoreFile(), "pending.candidateNames")
        Int c = 0
        While c < nAwaiting
            Actor cand = awaiting[c] as Actor
            ; Only those tied at the earliest delivery. A mother who delivered
            ; later is distinguishable and is not a candidate for THIS child.
            If cand != None && StorageUtil.GetFloatValue(cand, "SNKin_AwaitingAt", 0.0) == bestAt
                ; Duplicates allowed so the two lists stay index-aligned, the
                ; same rule the per-child lists follow.
                JsonUtil.IntListAdd(StoreFile(), "pending.candidates", cand.GetFormID(), True)
                JsonUtil.StringListAdd(StoreFile(), "pending.candidateNames", cand.GetDisplayName(), True)
            EndIf
            c += 1
        EndWhile
        JsonUtil.Save(StoreFile())
        Diag(LOG_WARN(), (tied + 1) + " mothers delivered in the same sweep - nothing " + \
            "distinguishes them, so this child is recorded with a CANDIDATE LIST " + \
            "instead of a mother. Resolve it from the in-game menu.")
        Return None
    EndIf
    If found > 1
        Diag(LOG_INFO(), found + " mothers awaiting; claimed the earliest delivery.")
    EndIf
    ; A mother was claimed, so nothing is pending. Clearing here stops a tie from
    ; an earlier birth being applied to an unrelated child later.
    ClearPendingCandidates()
    StorageUtil.SetIntValue(best, "SNKin_Awaiting", 0)
    WatchRemove(best)
    Return best
EndFunction

; ===========================================================================
; DURABLE FORM IDENTITY
;
; A runtime FormID is NOT a durable identity. Its top byte is the plugin's
; position in the load order, and for a light plugin the top THREE hex digits
; are - so adding or removing any mod shifts every ESL-sourced FormID.
;
; This is not theoretical. Two hand-entered mothers became unresolvable after an
; unrelated plugin was added and removed, while every vanilla-space parent on the
; same roster survived untouched. And the people roster accumulated FOUR entries
; for one follower, one per load order the game had seen, because AppendPerson
; keys on the runtime id and each shift looked like a new person.
;
; The durable pair is the source plugin's FILENAME plus the LOCAL id within it -
; exactly what GetFormFromFile takes. That survives any load order.
;
; Papyrus Ints are SIGNED, so a FormID above 0x7FFFFFFF is negative and a plain
; RightShift sign-extends. Every shift below is masked afterwards for that reason.
; ===========================================================================

Bool Function IsLightFormId(Int aiFormID) Global
    ; 0xFE in the top byte marks a light (ESL) plugin.
    Return Math.LogicalAnd(Math.RightShift(aiFormID, 24), 0xFF) == 0xFE
EndFunction

String Function SourcePlugin(Int aiFormID) Global
    ; The filename the form came from, or "" when it has none.
    ;
    ; A 0xFF form is a RUNTIME SPAWN with no source file at all - every Fertility
    ; Mode child is one - so those get "" and keep using the raw id, which is
    ; correct: they are per-save by nature and cannot outlive it anyway.
    Int top = Math.LogicalAnd(Math.RightShift(aiFormID, 24), 0xFF)
    If top == 0xFF
        Return ""
    EndIf
    If top == 0xFE
        Return Game.GetLightModName(Math.LogicalAnd(Math.RightShift(aiFormID, 12), 0xFFF))
    EndIf
    Return Game.GetModName(top)
EndFunction

Int Function LocalFormId(Int aiFormID) Global
    ; The id WITHIN its plugin: 12 bits for a light plugin, 24 otherwise.
    If IsLightFormId(aiFormID)
        Return Math.LogicalAnd(aiFormID, 0xFFF)
    EndIf
    Return Math.LogicalAnd(aiFormID, 0xFFFFFF)
EndFunction

Int Function ResolveFormId(String asPlugin, Int aiLocal) Global
    ; Back to a runtime FormID under the CURRENT load order, or 0.
    If asPlugin == "" || aiLocal == 0
        Return 0
    EndIf
    Form f = Game.GetFormFromFile(aiLocal, asPlugin)
    If f == None
        Return 0
    EndIf
    Return f.GetFormID()
EndFunction

Int Function LivePersonTwin(Int aiDeadId) Global
    ; The live roster entry for the SAME form as a dead id, or 0.
    ;
    ; Matched on NAME plus LOCAL id, never on the decoded plugin. The local is
    ; pure arithmetic on the id and stays true however the load order moves; the
    ; plugin NAME is a lookup against the current order, so a dead index names
    ; whatever mod occupies that slot today. Measured: three dead Fenja entries
    ; decode to cowperktree.esp, companionsskillltree.esp and mawassets.esp.
    ; Trusting that would have written a cow perk as somebody's mother.
    ;
    ; The light/regular kind must match too, or a vanilla 0x000814 and an ESL
    ; local 0x814 would look like the same form.
    ; THE CAPTURED PAIR FIRST, when there is one. Recorded while the form was
    ; alive, so it needs no surviving twin and cannot be fooled by a reshuffled
    ; index - this is the path every record written from now on will take.
    String kept = JsonUtil.GetStringValue(StoreFile(), "person." + aiDeadId + ".plugin", "")
    If kept != ""
        Int direct = ResolveFormId(kept, JsonUtil.GetIntValue(StoreFile(), "person." + aiDeadId + ".local", 0))
        If direct != 0 && direct != aiDeadId
            Return direct
        EndIf
    EndIf

    ; Otherwise fall back to finding a live twin. Everything written before the
    ; pair was captured takes this route, matched on name plus LOCAL id - the
    ; local is arithmetic and holds, the plugin name is a lookup a stale index
    ; answers wrongly.
    String nm = JsonUtil.GetStringValue(StoreFile(), "person." + aiDeadId + ".name", "")
    If nm == ""
        Return 0
    EndIf
    ; NOT "light" - Light is a Skyrim form type, and Papyrus refuses a local
    ; named after one. Same trap as Race, Key and Parent elsewhere in this file.
    Bool isLight = IsLightFormId(aiDeadId)
    Int loc = LocalFormId(aiDeadId)
    Int n = JsonUtil.IntListCount(StoreFile(), "people.ids")
    Int i = 0
    While i < n
        Int other = JsonUtil.IntListGet(StoreFile(), "people.ids", i)
        If other != aiDeadId && IsLightFormId(other) == isLight && LocalFormId(other) == loc
            If JsonUtil.GetStringValue(StoreFile(), "person." + other + ".name", "") == nm
                If Game.GetFormEx(other) != None
                    Return other
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    Return 0
EndFunction

Function RepointPerson(Int aiDeadId, Int aiLiveId) Global
    ; Moves every reference from a dead FormID onto its live twin.
    If aiDeadId == 0 || aiLiveId == 0 || aiDeadId == aiLiveId
        Return
    EndIf
    ; CARRY THE RECORD ACROSS FIRST when the live id is new to the roster. A
    ; twin already has its own record, but an id that came from re-resolving the
    ; captured plugin pair has none - repointing to it without this would leave
    ; every reference aimed at a person with no name, which renders as blank.
    If JsonUtil.GetStringValue(StoreFile(), "person." + aiLiveId + ".name", "") == ""
        JsonUtil.SetStringValue(StoreFile(), "person." + aiLiveId + ".name", \
            JsonUtil.GetStringValue(StoreFile(), "person." + aiDeadId + ".name", ""))
        JsonUtil.SetIntValue(StoreFile(), "person." + aiLiveId + ".sex", \
            JsonUtil.GetIntValue(StoreFile(), "person." + aiDeadId + ".sex", -1))
        JsonUtil.SetStringValue(StoreFile(), "person." + aiLiveId + ".plugin", \
            JsonUtil.GetStringValue(StoreFile(), "person." + aiDeadId + ".plugin", ""))
        JsonUtil.SetIntValue(StoreFile(), "person." + aiLiveId + ".local", \
            JsonUtil.GetIntValue(StoreFile(), "person." + aiDeadId + ".local", 0))
        JsonUtil.IntListAdd(StoreFile(), "people.ids", aiLiveId, False)
    EndIf
    ; Parent links on children.
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".motherId", 0) == aiDeadId
            JsonUtil.SetIntValue(StoreFile(), "child." + i + ".motherId", aiLiveId)
        EndIf
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".fatherId", 0) == aiDeadId
            JsonUtil.SetIntValue(StoreFile(), "child." + i + ".fatherId", aiLiveId)
        EndIf
        i += 1
    EndWhile
    ; The reverse index, merged rather than replaced - the live id may already
    ; own children of its own.
    Int k = JsonUtil.IntListCount(StoreFile(), ParentPath(aiDeadId))
    Int j = 0
    While j < k
        JsonUtil.IntListAdd(StoreFile(), ParentPath(aiLiveId), \
            JsonUtil.IntListGet(StoreFile(), ParentPath(aiDeadId), j), False)
        j += 1
    EndWhile
    JsonUtil.IntListClear(StoreFile(), ParentPath(aiDeadId))
    ; And the person record itself.
    JsonUtil.SetStringValue(StoreFile(), "person." + aiDeadId + ".name", "")
    JsonUtil.IntListRemove(StoreFile(), "people.ids", aiDeadId, True)
EndFunction

Int Function RepairFormDrift() Global
    ; Collapses roster entries that a load order change split into duplicates.
    ;
    ; A light plugin's FormID carries its load order position in the top three
    ; hex digits, so adding or removing any mod rewrites every ESL-sourced id.
    ; AppendPerson keyed on the raw id, so each shift looked like a new person -
    ; one follower accumulated FOUR entries, of which three could never be
    ; selected because the picker cannot resolve them to an Actor.
    Int n = JsonUtil.IntListCount(StoreFile(), "people.ids")
    Int repaired = 0
    Int orphaned = 0
    ; Downwards: RepointPerson removes entries, and walking up would skip the
    ; element shifted into the slot just vacated.
    Int i = n - 1
    While i >= 0
        Int id = JsonUtil.IntListGet(StoreFile(), "people.ids", i)
        If id != 0 && Game.GetFormEx(id) == None
            Int live = LivePersonTwin(id)
            If live != 0
                String nm = JsonUtil.GetStringValue(StoreFile(), "person." + id + ".name", "?")
                RepointPerson(id, live)
                repaired += 1
                Diag(LOG_INFO(), "Drift: " + nm + " had a dead duplicate; folded it into the live record.")
            Else
                ; Dead with no live twin. LEFT ALONE - the person may simply not
                ; be loaded in this playthrough, and deleting them would lose a
                ; hand-entered parent link with nothing to put in its place.
                orphaned += 1
            EndIf
        EndIf
        i -= 1
    EndWhile
    If repaired > 0 || orphaned > 0
        JsonUtil.Save(StoreFile())
        Diag(LOG_WARN(), "Form drift repair: " + repaired + " duplicate(s) folded, " + \
            orphaned + " dead entr(ies) with no live twin left untouched.")
    EndIf
    Return repaired
EndFunction

Int Function RepairDrift()
    { Instance entry point for the web API. See RepairFormDrift. }
    Return RepairFormDrift()
EndFunction

Int Function CountBrokenRecords() Global
    ; How many recorded people no longer resolve. Drives the menu's count, so it
    ; is a plain O(people) scan with no repair attempted and nothing written.
    Int n = JsonUtil.IntListCount(StoreFile(), "people.ids")
    Int broken = 0
    Int i = 0
    While i < n
        Int id = JsonUtil.IntListGet(StoreFile(), "people.ids", i)
        ; A runtime spawn that has gone is not "broken" - it is a dead reference
        ; from a previous session and there is nothing to repair it to.
        If id != 0 && SourcePlugin(id) != "" && Game.GetFormEx(id) == None
            broken += 1
        EndIf
        i += 1
    EndWhile
    Return broken
EndFunction

Function CheckLoadOrderDrift() Global
    ; Repairs the roster WHEN THE LOAD ORDER HAS ACTUALLY CHANGED, and does
    ; nothing at all when it has not.
    ;
    ; This has to be continuous rather than a one-off migration: a light
    ; plugin's FormID carries its load order position, so every mod a player
    ; adds or removes renumbers every ESL-sourced form they have recorded. For
    ; anyone running custom followers - which is most people with children by
    ; NPCs - that is a routine event, not an edge case.
    ;
    ; But the repair is O(people^2) in the legacy path, and running that on
    ; every sweep for two hundred people would be indefensible. The plugin
    ; counts are two native calls and change whenever anything is added or
    ; removed, so they gate the expensive work behind the only event that can
    ; cause the damage.
    ;
    ; A pure REORDER with no count change slips through this. That is accepted:
    ; it is rarer, it still gets caught by the next add or remove, and the
    ; manual RepairDrift is there meanwhile. A cheap check that catches the
    ; common case beats an expensive one that catches everything.
    Int fp = Game.GetModCount() * 100000 + Game.GetLightModCount()
    If fp == JsonUtil.GetIntValue(StoreFile(), "loadOrderFp", 0)
        Return
    EndIf
    Int was = JsonUtil.GetIntValue(StoreFile(), "loadOrderFp", 0)
    JsonUtil.SetIntValue(StoreFile(), "loadOrderFp", fp)
    JsonUtil.Save(StoreFile())
    If was == 0
        ; First run on this store - nothing to compare against, and the schema
        ; migration has already swept. Just record the fingerprint.
        Return
    EndIf
    Diag(LOG_WARN(), "Load order changed since the last session - checking the " + \
        "people roster for records the reshuffle broke.")
    RepairFormDrift()
EndFunction

String Function DumpFormSources()
    { Round-trip check for the durable pair, over the real people roster.

      Proves the encoding BEFORE anything is stored on it: every person is
      decomposed to plugin plus local id and resolved back, and any row where the
      round trip does not return the original is a bug in the maths rather than
      in the data. Rows that already fail to resolve are the ESL casualties. }
    Int n = JsonUtil.IntListCount(StoreFile(), "people.ids")
    Diag(LOG_INFO(), "--- form sources --- " + n + " people")
    Int ok = 0
    Int drift = 0
    Int dead = 0
    Int i = 0
    While i < n
        Int id = JsonUtil.IntListGet(StoreFile(), "people.ids", i)
        String nm = JsonUtil.GetStringValue(StoreFile(), "person." + id + ".name", "?")
        String plug = SourcePlugin(id)
        Int loc = LocalFormId(id)
        Int back = ResolveFormId(plug, loc)
        String verdict = "ok"
        If Game.GetFormEx(id) == None
            verdict = "DEAD (id no longer resolves)"
            dead += 1
        ElseIf back == 0
            verdict = "NO ROUND TRIP"
            drift += 1
        ElseIf back != id
            verdict = "DRIFTED -> 0x" + back
            drift += 1
        Else
            ok += 1
        EndIf
        Diag(LOG_INFO(), "  " + nm + "  id=0x" + id + "  plugin='" + plug + "' local=0x" + loc + "  " + verdict)
        i += 1
    EndWhile
    Diag(LOG_INFO(), "--- end form sources --- ok=" + ok + " drifted=" + drift + " dead=" + dead)
    Return "ok"
EndFunction

Function ClearPendingCandidates() Global
    ; Pending exists only while a tie is live. Every exit from
    ; ClaimAwaitingMother that is NOT a tie clears it, so RecordChild can trust
    ; a non-empty list to be about the child it is recording right now, with no
    ; timestamp and no staleness window to reason about.
    JsonUtil.IntListClear(StoreFile(), "pending.candidates")
    JsonUtil.StringListClear(StoreFile(), "pending.candidateNames")
    JsonUtil.Save(StoreFile())
EndFunction

Form[] Function PendingCandidates() Global
    ; The tied mothers ClaimAwaitingMother persisted, as Actors.
    ;
    ; A FormID that no longer resolves is skipped rather than dropped as a hole,
    ; so the returned array is always dense and its length is a true count.
    Form[] hits = new Form[8]
    Int n = 0
    Int total = JsonUtil.IntListCount(StoreFile(), "pending.candidates")
    Int i = 0
    While i < total && n < 8
        Actor a = Game.GetFormEx(JsonUtil.IntListGet(StoreFile(), "pending.candidates", i)) as Actor
        If a != None
            hits[n] = a
            n += 1
        EndIf
        i += 1
    EndWhile
    Return Utility.ResizeFormArray(hits, n)
EndFunction

; ===========================================================================
; Binding a spawned child actor
;
; A child exists as a NAME long before it exists as an Actor - FMR only calls
; PlaceActorAtMe when the player adopts or trains it through the MCM. Until
; then there is nothing to decorate, which is why binding happens here rather
; than at record time.
; ===========================================================================

Function BindSpawnedChildren()
    { Walks FMR's SpawnedChildActorRefs and stamps each one with the roster key
      of the child it is.

      Matching is by DISPLAY NAME because that is what FMR sets on the spawned
      reference (Util.RenameChild -> SetDisplayName). The ActorBase is a shared
      generic - Nicollette's is literally "Player's Nord Mage Daughter" - so it
      cannot identify anyone. }
    If _store == None
        Return
    EndIf
    Actor[] spawned = _store.SpawnedChildActorRefs
    If spawned == None
        Return
    EndIf
    Int i = 0
    While i < spawned.Length
        Actor c = spawned[i]
        If c != None
            If StorageUtil.GetIntValue(c, "SNKin_Bound", 0) != 1
                Int idx = ChildIndex(c.GetDisplayName())
                If idx >= 0 && BindChildRef(c, idx)
                    Diag(LOG_INFO(), "Bound " + c.GetDisplayName() + " to record " + idx + ".")
                EndIf
            EndIf
            ; STAMPED EVEN WHEN THE BINDING WAS REFUSED, and that is the whole
            ; point. BindChildRef returns False when two children share one
            ; spawned actor, but that actor is still the player's child - and a
            ; consumer gating romance on it must not be told otherwise.
            StampChildActor(c)
        EndIf
        i += 1
    EndWhile
EndFunction

; ===========================================================================
; Manual entry, for children who already existed when this was installed
;
; Their maternity is genuinely gone - FMR never stored it - so it has to be
; typed in. Dispatched from the SkyrimNet web API:
;
;   POST /papyrus/execute-quest-script-function
;   { "questEditorId": "SNKin_Kinship", "scriptName": "SNKin_Bridge",
;     "functionName": "SetParentage", "args": ["Toryy", "<mother uuid>"] }
;
; NOT Global, and every parameter is explicit: execute-quest-script-function
; cannot call Global functions, and Papyrus default parameter values do NOT
; apply through it - the argument count must match the signature exactly or the
; call dies with an error visible only in SkyrimNet.log.
; ===========================================================================

Bool Function SetParent(String asChildName, Actor akParent, Int aiIsFather)
    { Instance entry point, kept because the web API can only dispatch to a
      script attached to a quest. The work is in SetParentStatic. }
    Return SetParentStatic(asChildName, akParent, aiIsFather)
EndFunction

Bool Function SetParentStatic(String asChildName, Actor akParent, Int aiIsFather) Global
    { Sets or corrects EITHER parent by hand. aiIsFather: 0 mother, 1 father.

      GLOBAL, so the in-game picker can call it without holding a reference to
      the quest. SNKin_Picker is a Hidden script attached to nothing - that is
      what lets the whole UI ship as loose files with no Creation Kit work -
      and a Global cannot call a member function. Everything this needs
      (ChildIndex, ParentPath, StoreFile, Diag) is already Global, so there is
      nothing to resolve a quest for.

      An Int rather than a Bool for the role because this is also dispatched
      over the web API, and an Int is the one thing that survives that boundary
      without ambiguity - the same reasoning as the JSON payloads.

      Returns False and changes nothing if the child is not on the roster, so a
      typo cannot invent one. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "SetParent: no child named '" + asChildName + "' on the roster.")
        Return False
    EndIf
    If akParent == None
        Diag(LOG_ERROR(), "SetParent: parent resolved to None for '" + asChildName + "'.")
        Return False
    EndIf

    String role = "mother"
    String idField = "child." + idx + ".motherId"
    String nameField = "child." + idx + ".mother"
    String otherField = "child." + idx + ".fatherId"
    If aiIsFather == 1
        role = "father"
        idField = "child." + idx + ".fatherId"
        nameField = "child." + idx + ".father"
        otherField = "child." + idx + ".motherId"
    EndIf

    ; ONE PERSON CANNOT BE BOTH PARENTS OF THE SAME CHILD. Easy to do by
    ; accident from a dropdown that lists anyone whose sex is unresolved in both
    ; columns, and the result would be a bio claiming someone bore a child to
    ; themselves.
    If JsonUtil.GetIntValue(StoreFile(), otherField, 0) == akParent.GetFormID()
        Diag(LOG_ERROR(), "SetParent: " + akParent.GetDisplayName() + \
            " is already the other parent of " + asChildName + " - refusing.")
        Return False
    EndIf

    ; Drop the old reverse link if this is a correction rather than a first
    ; entry, or the previous parent keeps claiming a child that is not theirs.
    Int oldId = JsonUtil.GetIntValue(StoreFile(), idField, 0)
    If oldId != 0
        JsonUtil.IntListRemove(StoreFile(), ParentPath(oldId), idx, True)
    EndIf

    Int newId = akParent.GetFormID()
    JsonUtil.SetStringValue(StoreFile(), nameField, akParent.GetDisplayName())
    JsonUtil.SetIntValue(StoreFile(), idField, newId)
    JsonUtil.IntListAdd(StoreFile(), ParentPath(newId), idx, False)

    ; WHEN the link was made, not just when the child was born. Without this the
    ; rewind check is only half a check: a child born before a save point but
    ; whose mother was assigned after it would look entirely consistent, and the
    ; player would keep a parent link belonging to a future they abandoned.
    JsonUtil.SetFloatValue(StoreFile(), "child." + idx + "." + role + "SetAt", \
        Utility.GetCurrentGameTime())

    ; THE SHORTLIST IS KEPT, NOT RETIRED.
    ;
    ; It used to be cleared here on the reasoning that an answered question
    ; should stop being asked. That was wrong, and the panel proved it: one
    ; misclick assigned Yrsa to the wrong candidate, and because the shortlist
    ; had just been destroyed there was no way to choose the other one - the
    ; information needed to correct the mistake was deleted BY the mistake.
    ;
    ; Nothing needs it gone. "Waiting" is motherId == 0 AND candidates > 0, so a
    ; resolved child drops out of the queue on the motherId alone. Keeping the
    ; list turns every past decision into an editable one.
    JsonUtil.Save(StoreFile())

    ; Anyone deliberately chosen stays offerable in the editor forever, even if
    ; FMR never tracked them or has since forgotten them.
    RememberPerson(akParent)

    ; BOTH ends of a correction. The parent losing the child needs republishing
    ; every bit as much as the one gaining it, and oldId is the only place its
    ; FormID is still known.
    RefreshParentCount(oldId)
    RefreshParentCount(newId)

    ; NAMING HER AS THE MOTHER IS THE ANSWER TO "WHO DELIVERED THIS CHILD".
    ;
    ; SNKin_Awaiting was only ever cleared on the automatic success path, so a
    ; mother whose child was assigned BY HAND stayed flagged forever - and since
    ; the earliest awaiting wins, she then captured somebody else's baby.
    ;
    ; Measured, not theorised. Fenja Secret-Fire and Hermir Strong-Heart were
    ; assigned to Decimus and Aulus by hand on day 192; five days later a child
    ; called Tova was born to a different mother entirely and was offered those
    ; same two as its candidates, because their flags had never been retired.
    ;
    ; Only the mother, because only a delivery is what the flag records. A
    ; father is not awaiting anything.
    If aiIsFather == 0 && StorageUtil.GetIntValue(akParent, "SNKin_Awaiting", 0) == 1
        StorageUtil.SetIntValue(akParent, "SNKin_Awaiting", 0)
        Diag(LOG_INFO(), "Cleared " + akParent.GetDisplayName() + \
            "'s pending delivery - it is now answered by " + asChildName + ".")
    EndIf

    Diag(LOG_INFO(), "SetParent: " + asChildName + " -> " + role + " " + \
        akParent.GetDisplayName() + ".")
    Return True
EndFunction

Bool Function SetParentage(String asChildName, Actor akMother)
    { Mother-only wrapper, kept so anything written against the earlier API
      keeps working. New callers should use SetParent. }
    Return SetParent(asChildName, akMother, 0)
EndFunction

Bool Function SetParentageById(String asChildName, Int aiMotherFormID)
    { SetParentage for a mother who is NOT currently loaded, which is nearly
      all of them.

      NO BRACES IN THIS DOCSTRING, deliberately - a literal opening brace
      CLOSES a Papyrus docstring, and everything after it is then parsed as
      code. Writing a JSON example here cost one build already.

      THE WEB API CANNOT MARSHAL AN UNLOADED ACTOR. Measured against the live
      game: passing a NEARBY NPC's FormID echoes the argument back as an Actor
      with value 0x000198a2, while an ABSENT one echoes an Actor with value
      null - and SkyrimNet then abandons the dispatch without ever entering
      Papyrus, so not even an error is logged. True with and without the 0x
      prefix; it is not a formatting problem.

      Since maternity has to be entered by hand for every child that predates
      this mod, and those mothers are scattered across Skyrim, requiring the
      player to stand next to each one would make the feature close to
      unusable. An Int survives the boundary intact, so the lookup happens here
      instead.

      GetFormEx, not GetForm: the SKSE version takes the full unsigned 32-bit
      range. Ordinary GetForm mangles anything above 0x7FFFFFFF, which is every
      ESL reference and every runtime spawn - and Kayla, the mother this was
      written for, is 0xFE21C812. }
    Return SetParentById(asChildName, aiMotherFormID, 0)
EndFunction

Bool Function SetParentByIdStatic(String asChildName, Int aiParentFormID, Int aiIsFather) Global
    { Global twin of SetParentById, for the in-game picker.

      The picker is a Hidden script attached to nothing, so it cannot call a
      member function - and it needs the FormID path specifically, because a
      shortlisted mother is almost never loaded when the player gets round to
      answering. GetFormEx handles the full unsigned range, which ESL and
      runtime references both need. }
    Actor who = Game.GetFormEx(aiParentFormID) as Actor
    If who == None
        Diag(LOG_ERROR(), "SetParentByIdStatic: " + aiParentFormID + " is not an Actor.")
        Return False
    EndIf
    Return SetParentStatic(asChildName, who, aiIsFather)
EndFunction

Bool Function SetParentById(String asChildName, Int aiParentFormID, Int aiIsFather)
    { SetParent for a parent who is NOT currently loaded - see the note on
      SetParentageById for why an Int is required. aiIsFather: 0 mother,
      1 father. This is the entry point the MCM and the helper script use. }
    ; NOT "parent" - that is a reserved Papyrus identifier for base-class
    ; access, and a local of that name fails with "function variable parent
    ; already defined in the same scope".
    Actor who = Game.GetFormEx(aiParentFormID) as Actor
    If who == None
        Diag(LOG_ERROR(), "SetParentById: " + aiParentFormID + \
            " is not an Actor. Pass the DECIMAL form of the reference FormID, " + \
            "and check it is a reference rather than a base record.")
        Return False
    EndIf
    Return SetParent(asChildName, who, aiIsFather)
EndFunction

Float Function BabyDurationDays() Global
    { Game days a baby item is carried before the child is named, read LIVE
      from Fertility Mode rather than assumed. Returns -1.0 if unavailable.

      WHY THE MOD DOES NOT OTHERWISE DEPEND ON THIS: the automatic pipeline
      watches BabyAdded flip from >0 to 0, which is FMR's own signal and fires
      whenever IT decides the baby matured. So a player running 3 days or 30,
      or changing the slider halfway through a save, needs no special handling.
      This value is for the RECOVERY tools and for diagnostics that would
      otherwise be reporting in units they cannot name.

      0x00EAA6 was read out of the ESM's GLOB records rather than guessed. The
      same parse returns 0x000D67 for CycleDuration, which is the FormID the
      shipped SeverActions bridge hardcodes for that global - so the offsets
      are confirmed against a known-good third party, not just self-consistent.

      Guarded rather than trusted: a future FMR release can renumber records, so
      a missing or nonsensical value degrades to -1.0 and callers say "unknown"
      instead of quietly computing with a zero. }
    If Game.GetModByName("Fertility Mode.esm") == 255
        Return -1.0
    EndIf
    GlobalVariable g = Game.GetFormFromFile(0x00EAA6, "Fertility Mode.esm") as GlobalVariable
    If g == None
        Return -1.0
    EndIf
    Float v = g.GetValue()
    If v <= 0.0
        Return -1.0
    EndIf
    Return v
EndFunction

Float Function FmrPollHours() Global
    { FMR's own update interval, for sanity-checking kinPollHours. Polling
      faster than FMR simulates cannot find anything sooner. }
    If Game.GetModByName("Fertility Mode.esm") == 255
        Return -1.0
    EndIf
    GlobalVariable g = Game.GetFormFromFile(0x001D95, "Fertility Mode.esm") as GlobalVariable
    If g == None
        Return -1.0
    EndIf
    Return g.GetValue()
EndFunction

Float Function TimelineEpsilon() Global
    { Slack before a record counts as being from the future. A save reloaded at
      almost the same moment must not look like a rewind, and game time is a
      float. Fifteen game minutes is far below any real difference and far
      above any rounding. }
    Return 0.01
EndFunction

Int Function CountFutureChildren() Global
    { Children recorded LATER than the current game time - i.e. from a future
      that no longer happened because an earlier save was loaded.

      This is the one check SkyrimNet cannot do for us and we cannot ask it
      about: it broadcasts no timeline event, so there is nothing to subscribe
      to. It does not matter, because born is our own timestamp and this is a
      question about our own records.

      NOT the same problem as cross-playthrough contamination, and neither
      check catches the other. Nicollette1 came from a different character at
      game time 62 while this one stood at 175 - EARLIER, so no timeline test
      would ever have flagged her. That is what per-save store files are for. }
    Float now = Utility.GetCurrentGameTime() + TimelineEpsilon()
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int count = 0
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".hidden", 0) != 1
            If JsonUtil.GetFloatValue(StoreFile(), "child." + i + ".born", 0.0) > now
                count += 1
            EndIf
        EndIf
        i += 1
    EndWhile
    Return count
EndFunction

String Function FutureChildNames() Global
    { The names behind that count, newline separated, so a prompt can show the
      player exactly what they are about to lose rather than a bare number. }
    Float now = Utility.GetCurrentGameTime() + TimelineEpsilon()
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    String out = ""
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".hidden", 0) != 1
            If JsonUtil.GetFloatValue(StoreFile(), "child." + i + ".born", 0.0) > now
                If out != ""
                    out += NL()
                EndIf
                out += JsonUtil.GetStringValue(StoreFile(), "child." + i + ".name", "?")
            EndIf
        EndIf
        i += 1
    EndWhile
    Return out
EndFunction

Int Function ForgetFutureChildren() Global
    { Tombstones every child recorded after the current game time. Returns how
      many.

      ONLY EVER CALLED FROM AN EXPLICIT CONFIRMATION. Never from Bootstrap,
      never from Sweep. A player who loads an old save to check something and
      then returns to their newer one must find their family intact - deleting
      it silently would be unrecoverable and would look like the mod had eaten
      their save. The detection runs automatically; the deletion never does. }
    Float now = Utility.GetCurrentGameTime() + TimelineEpsilon()
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int forgotten = 0
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".hidden", 0) != 1
            If JsonUtil.GetFloatValue(StoreFile(), "child." + i + ".born", 0.0) > now
                If ForgetChildStatic(JsonUtil.GetStringValue(StoreFile(), "child." + i + ".name", ""))
                    forgotten += 1
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    Diag(LOG_WARN(), "Timeline: forgot " + forgotten + " child record(s) from after this save point.")
    Return forgotten
EndFunction

Bool Function AddChildStatic(String asChildName, Int aiChildFormID, Int aiMotherFormID, Int aiFatherFormID) Global
    { Creates a child record by hand.

      THE FALLBACK FOR EVERY AUTOMATIC PATH FAILING - including a player who
      forgot a child by mistake and wants it back, or one whose birth was never
      captured at all. Without it, "permanently deletes" would have no undo of
      any kind, which is a bad property for a destructive action to have.

      aiChildFormID may be 0. The record still renders on the parents' side;
      it simply cannot be bound to a spawned actor, so the CHILD's own bio will
      not carry it until BindSpawnedChildren matches the name later.

      Refuses to create a duplicate: an existing name returns False rather than
      quietly making a second record that would then compete for the same
      spawned actor. }
    If asChildName == ""
        Return False
    EndIf
    If ChildIndex(asChildName) >= 0
        Diag(LOG_ERROR(), "AddChild: '" + asChildName + "' is already on the roster.")
        Return False
    EndIf

    JsonUtil.StringListAdd(StoreFile(), "roster", asChildName, False)
    Int idx = JsonUtil.StringListFind(StoreFile(), "roster", asChildName)
    If idx < 0
        Return False
    EndIf
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".name", asChildName)
    JsonUtil.SetFloatValue(StoreFile(), "child." + idx + ".born", Utility.GetCurrentGameTime())
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".hidden", 0)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".manual", 1)
    JsonUtil.Save(StoreFile())

    Actor kid = Game.GetFormEx(aiChildFormID) as Actor
    If kid != None
        BindChildRef(kid, idx)
        JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".gender", GenderWord(kid))
        JsonUtil.Save(StoreFile())
    EndIf

    If aiMotherFormID != 0
        SetParentByIdStatic(asChildName, aiMotherFormID, 0)
    EndIf
    If aiFatherFormID != 0
        SetParentByIdStatic(asChildName, aiFatherFormID, 1)
    EndIf
    ; Parent counts are already republished by SetParentByIdStatic; the total is
    ; not, and a manually added child moves it.
    RefreshChildTotal()
    Diag(LOG_INFO(), "AddChild: created '" + asChildName + "' at roster index " + idx + ".")
    Return True
EndFunction

String Function GenderWord(Actor akActor) Global
    If akActor == None || akActor.GetActorBase() == None
        Return ""
    EndIf
    If akActor.GetActorBase().GetSex() == 1
        Return "daughter"
    EndIf
    Return "son"
EndFunction

Bool Function BindChildRef(Actor akChild, Int aiIdx) Global
    { Binds one actor reference to one child record, and REFUSES to bind a
      reference that already belongs to a different child.

      Fertility Mode makes this a real risk rather than a theoretical one:
      SpawnedChildActorRefs is keyed by APPEARANCE ARCHETYPE, not by child, so
      two of the player's children sharing a class, race and gender share one
      slot - and FMR re-summons the first one's actor for the second without
      renaming it. Binding blindly would then hand one NPC two identities, and
      whichever record was read last would win.

      Returns False when the reference is already spoken for. }
    If akChild == None || aiIdx < 0
        Return False
    EndIf
    Int refId = akChild.GetFormID()
    Int existing = JsonUtil.GetIntValue(StoreFile(), "ref." + refId + ".child", -1)
    If existing >= 0 && existing != aiIdx
        Diag(LOG_WARN(), akChild.GetDisplayName() + " is already bound to record " + \
            existing + "; refusing to also bind it to " + aiIdx + \
            ". Two children are sharing one spawned actor - Fertility Mode reuses " + \
            "an actor when two children share an appearance archetype.")
        Return False
    EndIf
    StorageUtil.SetIntValue(akChild, "SNKin_Bound", 1)
    JsonUtil.SetIntValue(StoreFile(), "ref." + refId + ".child", aiIdx)
    JsonUtil.Save(StoreFile())
    ; SNKin_Bound is OURS and may be cleared wholesale by a migration. The
    ; exported flag is published separately so consumers never read it.
    StampChildActor(akChild)
    Return True
EndFunction

Bool Function ForgetChild(String asChildName)
    { Instance entry point for the web API. See ForgetChildStatic. }
    Return ForgetChildStatic(asChildName)
EndFunction

Bool Function ForgetChildStatic(String asChildName) Global
    { Hides a roster entry that should not be there.

      A TOMBSTONE, NEVER A REMOVAL. The roster index IS the record key, and
      both parent.<id>.kids and ref.<formid>.child store those indices - so
      deleting entry 29 would shift 30 and 31 down and silently repoint every
      reverse index at the wrong child. The slot stays; only its visibility
      changes.

      The parent links ARE withdrawn, because a hidden child should stop
      appearing in its parents' bios immediately - that is usually the whole
      reason for hiding it.

      Written for cross-playthrough contamination: JsonUtil keeps ONE file per
      install rather than per save, so a second character's children appear in
      the first character's roster. Nicollette1 arrived that way, recorded at
      game time 62 in a playthrough that had nothing to do with this one. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "ForgetChild: no child named '" + asChildName + "' on the roster.")
        Return False
    EndIf
    Int mId = JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".motherId", 0)
    If mId != 0
        JsonUtil.IntListRemove(StoreFile(), ParentPath(mId), idx, True)
    EndIf
    Int fId = JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".fatherId", 0)
    If fId != 0
        JsonUtil.IntListRemove(StoreFile(), ParentPath(fId), idx, True)
    EndIf
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".hidden", 1)
    JsonUtil.Save(StoreFile())

    ; Republish immediately rather than waiting for the next sweep. A hidden
    ; record is this mod stating the actor is not the player's child in this
    ; timeline, and the exported flag has to agree from that instant - a guard
    ; reading a stale 1 would keep blocking, which is at least safe, but a stale
    ; count feeds a disposition and would simply be wrong.
    Actor kid = Game.GetFormEx(JsonUtil.GetIntValue(StoreFile(), \
        "child." + idx + ".refId", 0)) as Actor
    If kid != None
        StorageUtil.SetIntValue(kid, "SNKin_IsPlayerChild", 0)
    EndIf
    RefreshParentCount(mId)
    RefreshParentCount(fId)
    RefreshChildTotal()

    Diag(LOG_INFO(), "ForgetChild: " + asChildName + " hidden and unlinked from both parents.")
    Return True
EndFunction

Bool Function RestoreChildStatic(String asChildName) Global
    { Undoes ForgetChild. Hiding is reversible on purpose - it is a judgement
      about which save a record belongs to, not a statement that the record is
      wrong, and those judgements can be mistaken. Parent links must be
      re-made by hand, since withdrawing them was the point. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Return False
    EndIf
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".hidden", 0)
    JsonUtil.Save(StoreFile())
    Actor kid = Game.GetFormEx(JsonUtil.GetIntValue(StoreFile(), \
        "child." + idx + ".refId", 0)) as Actor
    If kid != None
        StorageUtil.SetIntValue(kid, "SNKin_IsPlayerChild", 1)
    EndIf
    RefreshChildTotal()
    Diag(LOG_INFO(), "RestoreChild: " + asChildName + " is visible again.")
    Return True
EndFunction

; ===========================================================================
; THE PUBLIC PAPYRUS CONTRACT
;
; Three StorageUtil keys other mods may read. Everything else in this script -
; including SNKin_Bound - is internal and may change or be cleared wholesale by
; a migration without notice.
;
;   SNKin_IsPlayerChild     Int, per actor. 1 if this actor is one of the
;                           player's children on our roster.
;   SNKin_ChildrenByPlayer  Int, per actor. Non-hidden children this actor
;                           co-parents with the player.
;   SNKin_PlayerChildTotal  Int, global (None scope). Non-hidden children on
;                           the roster.
;
; INTS, NOT STRINGS: StorageUtil Strings do not survive a save reload. Ints,
; Floats and Forms do.
;
; GROUND TRUTH, NOT KNOWLEDGE. A count of 2 says nothing about whether anyone
; has heard of either child. A consumer that treats these as knowledge will
; produce omniscient NPCs; who knows what belongs to the mod modelling
; perception, not to the one keeping the records.
;
; Kinship's roster holds ONLY the player's children, so "how many children does
; she have" is a question this cannot answer - only "how many by the player".
; The key is named for what it actually means.
; ===========================================================================

Function StampChildActor(Actor akChild) Global
    ; Publishes SNKin_IsPlayerChild for one actor.
    ;
    ; Resolves the same way the decorator does - bound reference first, display
    ; name second - so the Papyrus flag and kinship_is_child cannot disagree.
    ; They used to: an unbound child read as "not a child" here while rendering
    ; a full parentage block there, and a guard reading the flag would have let
    ; the player romance his own daughter.
    ;
    ; Also writes child.<idx>.refId, the reverse of ref.<formid>.child, so
    ; ForgetChild can reach the actor to clear the flag without a search.
    If akChild == None
        Return
    EndIf
    Int idx = JsonUtil.GetIntValue(StoreFile(), "ref." + akChild.GetFormID() + ".child", -1)
    If idx < 0
        idx = ChildIndex(akChild.GetDisplayName())
    EndIf
    If MarkChildActor(akChild, idx)
        Return
    EndIf
    StorageUtil.SetIntValue(akChild, "SNKin_IsPlayerChild", 0)
EndFunction

Bool Function MarkChildActor(Actor akChild, Int aiIdx) Global
    ; Flags one actor as the player's child, given an ALREADY RESOLVED roster
    ; index. Returns False without writing anything if the index is not a live
    ; child, so a caller can tell "marked" from "not one".
    ;
    ; SPLIT OUT FROM StampChildActor BECAUSE THE SWEEP CANNOT FIND MOST
    ; CHILDREN. Stamping only what walks out of SpawnedChildActorRefs reached 2
    ; of 32 on the development save - that array is new Actor[128] over an
    ; archetype space of 220 and is keyed by appearance, not by child, so it is
    ; a cache of a few summoned adults rather than a list of anyone. Toryy has
    ; been summoned AND followed the player and is still not in it.
    ;
    ; The decorators do not have that problem: they resolve whatever actor they
    ; are handed. So they call this, and every child SkyrimNet renders a bio for
    ; gets flagged - which for a romance guard is exactly the right population,
    ; since nobody romances an NPC they have never spoken to.
    ;
    ; ONLY EVER WRITES A 1. Writing a 0 from a decorator would add a co-save
    ; entry for every NPC in Skyrim - 3,151 of them on this install - to record
    ; a value identical to the default. Clearing is left to the paths that know
    ; a child STOPPED being one: ForgetChild, and the sweep over bound refs.
    If akChild == None || aiIdx < 0
        Return False
    EndIf
    If JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".hidden", 0) == 1
        Return False
    EndIf
    StorageUtil.SetIntValue(akChild, "SNKin_IsPlayerChild", 1)
    ; Reverse pointer, so ForgetChild can reach this actor to clear the flag.
    ; Written once per child and then never again, so the save stays off the
    ; hot path of a decorator that runs on every bio build.
    Int refId = akChild.GetFormID()
    If JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".refId", 0) != refId
        JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".refId", refId)
        JsonUtil.Save(StoreFile())
    EndIf
    ; THE EARLIEST MOMENT A UUID CAN BE READ, and for many children the only
    ; one. Growing up destroys this reference - Beeing Female deletes it
    ; outright - so a UUID not captured while the child is alive is a UUID that
    ; can never be captured. Writes once and then costs a single string read.
    CaptureUuid(aiIdx, akChild)

    ; A HANDLE THAT OUTLIVES THE ACTOR, published for other mods.
    ;
    ; ASKED FOR BY Relationships, and it inverts a problem this mod got wrong
    ; first. The obvious offer was a pointer to the previous reference - and it
    ; is useless, because that reference has been DELETED by the time anyone
    ; could follow it. Beeing Female calls child.Delete() in the same function
    ; that spawns the adult, and StorageUtil reads are keyed by form: the
    ; pointer would be the address of a demolished house.
    ;
    ; So publish the record instead. A consumer keys its own state to this
    ; rather than to the actor, and then nothing needs migrating at the
    ; transition, because nothing was ever attached to the thing that gets
    ; destroyed. No timing window, no migration code, and it survives all five
    ; stage changes rather than needing a pointer chain walked back.
    ;
    ; +1 SO THAT ZERO MEANS ABSENT. The roster index is 0-based and index 0 is
    ; a perfectly ordinary child - on the development save it is Nicollette -
    ; so publishing it raw would make exactly one child indistinguishable from
    ; "no record". That is the worst kind of bug: correct for everyone except
    ; one person, forever.
    ;
    ; TREAT IT AS OPAQUE. It is a stable identifier, not an index into anything
    ; of ours, and it is only stable because this roster is append-only:
    ; ForgetChild tombstones and never removes, precisely because the index is
    ; already load-bearing as a record key internally.
    StorageUtil.SetIntValue(akChild, "SNKin_ChildRecordId", aiIdx + 1)
    Return True
EndFunction

Function RefreshParentCount(Int aiFormID) Global
    ; Publishes SNKin_ChildrenByPlayer for one parent.
    ;
    ; The reverse index already excludes hidden children - ForgetChild withdraws
    ; both parent links - so its length IS the count, with no filtering here.
    If aiFormID == 0
        Return
    EndIf
    Actor p = Game.GetFormEx(aiFormID) as Actor
    If p == None
        Return
    EndIf
    StorageUtil.SetIntValue(p, "SNKin_ChildrenByPlayer", \
        JsonUtil.IntListCount(StoreFile(), ParentPath(aiFormID)))
EndFunction

Int Function RefreshChildTotal() Global
    ; Publishes SNKin_PlayerChildTotal and returns it.
    ;
    ; Lets a consumer skip its whole jealousy path in one Papyrus read when the
    ; player has fathered nobody, before spending anything on an LLM call.
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int total = 0
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".hidden", 0) != 1
            total += 1
        EndIf
        i += 1
    EndWhile
    StorageUtil.SetIntValue(None, "SNKin_PlayerChildTotal", total)
    Return total
EndFunction

String Function DumpExports()
    { Writes every exported key to snkin.log, for verifying the contract from
      outside the game. Instance, not Global, so the web API can dispatch it.

      The line that matters is any child reading IsPlayerChild=1 Bound=0. That
      is a child the OLD Papyrus guard could not see - the flag now resolves by
      bound reference OR display name, the same two paths the decorator uses,
      instead of by the binding result alone. Before this, such a child looked
      like a stranger to any mod gating on SNKin_Bound. }
    Diag(LOG_INFO(), "--- exports --- SNKin_PlayerChildTotal = " + \
        StorageUtil.GetIntValue(None, "SNKin_PlayerChildTotal", 0))
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".hidden", 0) != 1
            String line = "  " + JsonUtil.GetStringValue(StoreFile(), "child." + i + ".name", "?")
            Actor kid = Game.GetFormEx(JsonUtil.GetIntValue(StoreFile(), \
                "child." + i + ".refId", 0)) as Actor
            If kid == None
                line += ": no actor of its own"
            Else
                line += ": IsPlayerChild=" + StorageUtil.GetIntValue(kid, "SNKin_IsPlayerChild", 0) + \
                    " Bound=" + StorageUtil.GetIntValue(kid, "SNKin_Bound", 0)
            EndIf
            line += "  mother " + ExportedParent(JsonUtil.GetIntValue(StoreFile(), \
                "child." + i + ".motherId", 0))
            line += "  father " + ExportedParent(JsonUtil.GetIntValue(StoreFile(), \
                "child." + i + ".fatherId", 0))
            If StagesEnabled()
                Int st = JsonUtil.GetIntValue(StoreFile(), "child." + i + ".stage", -1)
                line += "  stage " + StageName(st) + "/" + PlasticityFor(st)
            EndIf
            Diag(LOG_INFO(), line)
        EndIf
        i += 1
    EndWhile
    Diag(LOG_INFO(), "--- end exports ---")
    Return "ok"
EndFunction

String Function ExportedParent(Int aiFormID) Global
    { One parent rendered as name[count], or "-" when unrecorded. Reads the
      published key rather than recomputing it, so a drift between the store and
      what was exported shows up here instead of being papered over. }
    If aiFormID == 0
        Return "-"
    EndIf
    Actor p = Game.GetFormEx(aiFormID) as Actor
    If p == None
        Return "(unresolvable)"
    EndIf
    Return p.GetDisplayName() + "[" + \
        StorageUtil.GetIntValue(p, "SNKin_ChildrenByPlayer", 0) + "]"
EndFunction

Function RefreshKinshipExports() Global
    ; Full republish, driven from the sweep.
    ;
    ; Walks the roster rather than any list of parents, because there is no such
    ; list - a parent exists only as a reverse index keyed by FormID. A parent
    ; whose last child was withdrawn is therefore NOT visited here and would
    ; keep a stale count; ClearParent and ForgetChild refresh those precisely at
    ; the point of change, which is the only moment the affected FormID is known.
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".hidden", 0) != 1
            RefreshParentCount(JsonUtil.GetIntValue(StoreFile(), "child." + i + ".motherId", 0))
            RefreshParentCount(JsonUtil.GetIntValue(StoreFile(), "child." + i + ".fatherId", 0))

            ; RE-STAMP FROM THE STORED REFERENCE, because the flag and the
            ; records live in different places and can disagree.
            ;
            ; SNKin_IsPlayerChild is a StorageUtil value, which lives in the
            ; CO-SAVE and follows save state. The roster lives in a JsonUtil
            ; file, which is per-install and does not. Load an earlier save and
            ; the flag reverts while the record stays - measured, not theorised:
            ; Toryy read IsPlayerChild=1 one session and 0 the next, having been
            ; stamped by a conversation that the reloaded save predated.
            ;
            ; Bound children were never affected, because BindSpawnedChildren
            ; re-stamps them every sweep. This does the same for everyone else,
            ; using the refId MarkChildActor recorded the first time the child
            ; was ever resolved. So the flag is durable after first contact
            ; rather than needing a fresh conversation after every save load.
            Int refId = JsonUtil.GetIntValue(StoreFile(), "child." + i + ".refId", 0)
            Actor kid = None
            If refId != 0
                kid = Game.GetFormEx(refId) as Actor
                If kid != None
                    MarkChildActor(kid, i)
                EndIf
            EndIf
            ; Ages the record whether or not the child has an actor, and stamps
            ; the actor when there is one. Most of the player's children never
            ; spawn an NPC at all and they still grow up.
            RefreshChildStage(i, kid)
        EndIf
        i += 1
    EndWhile
    RefreshChildTotal()
EndFunction

; ===========================================================================
; LIFE STAGES
;
; A stage is DATA, not geometry. Skyrim has child races and adult races and
; nothing between, so there is no body for a toddler or an adolescent - but a
; stage does not need one. It needs a record and a persona, and SkyrimNet gives
; distinct personas to distinct references even when they share an ActorBase.
; Two of the player's sons, engine-identical in every rendered respect, already
; play as different people.
;
; Off by default. Everything here is inert unless kinStagesEnabled is set, so
; an existing install updating into this sees exactly what it had.
;
; Published for consumers:
;   SNKin_ChildStage       Int, per actor. 0 newborn .. 5 adult.
;   SNKin_ChildPlasticity  Int, per actor. 0-100, how far this child's values
;                          can still be moved by the people around them.
;
; PLASTICITY IS THE POINT OF HAVING STAGES AT ALL. Without it a stage is a
; label; with it, childhood is a WINDOW - values bend early and set later, so
; when you try to shape a child matters as much as whether you try. What a
; child actually values is not ours to hold: that belongs to whichever mod
; models disposition, exactly as knowledge belongs to whichever mod models
; perception. This publishes how movable they are and stays out of the rest.
; ===========================================================================

Int Function STAGE_ADULT() Global
    Return 5
EndFunction

Bool Function StagesEnabled() Global
    Return SkyrimNetApi.GetConfigBool(CFG(), "kinStagesEnabled", False)
EndFunction

String Function StageName(Int aiStage) Global
    If aiStage <= 0
        Return "newborn"
    ElseIf aiStage == 1
        Return "infant"
    ElseIf aiStage == 2
        Return "toddler"
    ElseIf aiStage == 3
        Return "child"
    ElseIf aiStage == 4
        Return "adolescent"
    EndIf
    Return "adult"
EndFunction

Float Function StageDurationDays(Int aiStage) Global
    ; GAME DAYS PER STAGE, and deliberately NOT derived from FMR's BabyDuration.
    ; Pacing that depends on another mod's global is pacing we do not control -
    ; the same coupling the parent records were pulled out of.
    If aiStage == 0
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinStageNewbornDays", 3.0)
    ElseIf aiStage == 1
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinStageInfantDays", 14.0)
    ElseIf aiStage == 2
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinStageToddlerDays", 30.0)
    ElseIf aiStage == 3
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinStageChildDays", 90.0)
    ElseIf aiStage == 4
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinStageAdolescentDays", 60.0)
    EndIf
    Return 0.0
EndFunction

Int Function PlasticityFor(Int aiStage) Global
    ; 0-100. Not a probability - a weight a consumer scales its own odds by, so
    ; it can decide what "hard to change" means for its own data.
    ;
    ; Never reaches 0. An adult who cannot be moved at all by anyone is a rock,
    ; not a person, and it would make every attempt on a grown child pointless
    ; rather than difficult.
    If aiStage <= 1
        Return 100
    ElseIf aiStage == 2
        Return 90
    ElseIf aiStage == 3
        Return 70
    ElseIf aiStage == 4
        Return 40
    EndIf
    Return 10
EndFunction

; ===========================================================================
; FERTILITY SOURCES
;
; A fertility mod is a BIRTH DETECTOR and, sometimes, a childhood. Everything
; downstream of the record - the roster, the decorators, the prompt, the
; picker, the panel, drift repair - is already source-agnostic and stays that
; way. Only ingestion differs.
;
; THE TWO SUPPORTED SOURCES WANT OPPOSITE TREATMENT, and that is the whole
; design rather than an inconsistency:
;
;   Fertility Mode Reloaded has a THIN childhood - a carried item, a ten-day
;   timer, a class-training path to adulthood. We supersede it, because the
;   life-stage model is strictly richer and the two cannot both be true.
;
;   Beeing Female NG has a RICH one - continuous scale growth, grow-to-adult
;   with inherited stats, an add-on framework for child bases across races. We
;   CONSUME it. Re-implementing growth on top of a system that already does it
;   well would be duplicated effort fighting a better implementation, and its
;   grow-to-adult already solves the problem we have no answer for.
;
; So `SourceOwnsGrowth` is the switch the whole life-stage layer hangs off.
; Where it answers True, our stages read theirs; where False, we provide them.
;
; NO TYPED SCRIPT DEPENDENCY ON BEEING FEMALE, deliberately. FMR needs
; _JSW_BB_Storage, which has to be vendored to compile against and cannot be
; redistributed. BF NG exposes everything through documented StorageUtil keys
; and mod events (docs/authors/state-data.md), so this reads it with nothing
; vendored at all. Any future source added the same way costs a config table
; rather than a compile-time dependency.
; ===========================================================================

Int Function SRC_NONE() Global
    Return 0
EndFunction

Int Function SRC_FMR() Global
    Return 1
EndFunction

Int Function SRC_BFNG() Global
    Return 2
EndFunction

String Function SourceName(Int aiSource) Global
    If aiSource == SRC_FMR()
        Return "Fertility Mode"
    ElseIf aiSource == SRC_BFNG()
        Return "Beeing Female"
    EndIf
    Return "unknown"
EndFunction

Bool Function HasFmr() Global
    ; Fertility Mode v3 masters Fertility Mode.esm and resolves every FormID
    ; this mod hardcodes identically, so it satisfies this the same way FMR
    ; does and needs no separate case.
    Return Game.GetModByName("Fertility Mode.esm") != 255
EndFunction

Bool Function HasBfng() Global
    ; Checked as both a regular and a light plugin. BeeingFemale.esm ships as a
    ; full master today, but a future ESL-flagged build would answer 255 to
    ; GetModByName and silently disable the whole path.
    If Game.GetModByName("BeeingFemale.esm") != 255
        Return True
    EndIf
    Return Game.GetLightModByName("BeeingFemale.esm") != 255
EndFunction

Bool Function SourceOwnsGrowth(Int aiSource) Global
    { True when the fertility mod runs its own childhood and ours must stand
      down. See the section header - this is the switch, not a detail. }
    Return aiSource == SRC_BFNG()
EndFunction

Int Function NextBirthGroup() Global
    { An id shared by every child of ONE pregnancy.

      NOT DERIVED FROM THE BIRTH TIME, and this save is why. Titus and Leif
      carry the same stamp to four decimals - 167.4088 - and are not siblings
      at all: Camilla Valerius and Ganna Uriel delivered in the same instant,
      each to a different child, which is the same simultaneous maturation the
      tie detector exists for. Grouping by timestamp would have declared them
      twins AND given each the other's mother.

      So the group comes from the labour event - one event, one pregnancy, one
      mother - and never from coincidence. A counter is enough. }
    Int n = JsonUtil.GetIntValue(StoreFile(), "nextBirthGroup", 1)
    JsonUtil.SetIntValue(StoreFile(), "nextBirthGroup", n + 1)
    JsonUtil.Save(StoreFile())
    Return n
EndFunction

Function CaptureUuid(Int aiIdx, Actor akWho) Global
    { Records this child's SkyrimNet UUID while the actor is alive.

      THE WHOLE POINT IS TO DO THIS EARLY. When a child grows up the earlier
      reference is DESTROYED - Beeing Female's GrowChildToAdult calls
      child.Delete() in the same function that spawns the adult, and no mod
      event marks the moment. A UUID captured only at transition time would
      therefore never be captured at all.

      The uuid_mappings row outlives the reference, so a succession declared
      afterwards is still well-defined - but only if we kept the UUID. }
    If akWho == None || aiIdx < 0
        Return
    EndIf
    If JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".uuid", "") != ""
        Return
    EndIf
    String u = SkyrimNetApi.GetEntityUUID(akWho)
    If u == ""
        Return
    EndIf
    JsonUtil.SetStringValue(StoreFile(), "child." + aiIdx + ".uuid", u)
    JsonUtil.Save(StoreFile())
EndFunction

Function RecordSuccession(Int aiIdx, Actor akGrown) Global
    { Notes that this child now lives in a different reference, and hands the
      pair to whatever can carry the persona across.

      THE LEDGER IS KEPT WHETHER OR NOT ANYTHING CAN USE IT YET. SkyrimNet has
      the machinery - identity_aliases, co-identity memory search, diary
      merging across co-identities - but its declared successions only accept
      refs with a stable plugin+local form id, and every actor either fertility
      mod spawns is a 0xFF runtime reference. A request is open upstream.

      Keeping the ledger now is what makes that request retroactive: if the
      API lands after children have already grown up, this walks its own
      history and declares every past succession then. Nothing is lost by
      waiting, which is the only reason waiting is safe. }
    If aiIdx < 0 || akGrown == None
        Return
    EndIf
    String was = JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".uuid", "")
    Int wasRef = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".refId", 0)
    If wasRef != 0
        JsonUtil.IntListAdd(StoreFile(), "child." + aiIdx + ".priorRefs", wasRef, True)
    EndIf
    If was != ""
        JsonUtil.StringListAdd(StoreFile(), "child." + aiIdx + ".priorUuids", was, True)
    EndIf
    ; The new reference becomes the current one, and its UUID is captured fresh.
    JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".refId", akGrown.GetFormID())
    JsonUtil.SetStringValue(StoreFile(), "child." + aiIdx + ".uuid", "")
    JsonUtil.Save(StoreFile())
    CaptureUuid(aiIdx, akGrown)
    BindChildRef(akGrown, aiIdx)
    MarkChildActor(akGrown, aiIdx)

    String now = JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".uuid", "")
    CarryIdentity(aiIdx, was, now)

    ; ANNOUNCED, so a consumer can greet a grown child correctly rather than
    ; noticing on its own next pass.
    ;
    ; HONEST ABOUT WHEN IT FIRES: at the moment KINSHIP notices, not at the
    ; moment the transition happened. Where this mod runs the childhood those
    ; are the same instant; where Beeing Female does, nothing announces the
    ; change and we find it on a later sweep. Late, never wrong - and a
    ; consumer keyed to the record id has lost nothing by the delay.
    Int h = ModEvent.Create("SNKin_ChildGrewUp")
    If h
        ModEvent.PushForm(h, akGrown)
        ModEvent.PushInt(h, aiIdx + 1)
        ModEvent.Send(h)
    EndIf
EndFunction

Event OnBfLabor(Form akMother, Int aiChildCount, Form akFather0, Form akFather1, Form akFather2)
    { Beeing Female delivering. Signature per docs/authors/modevents.md:
      Mother, ChildCount, Father0..2.

      THE EVENT IS A GROUPING SIGNAL, NOT THE RECORD. Beeing Female emits this
      BEFORE it spawns the child actors, and it stamps each spawned child with
      its own FW.Child.Mother / FW.Child.Father / FW.Child.Name - so the actor
      is the authority on its own parentage and we do not have to thread it
      through from here. What only this moment can tell us is which children
      belong to ONE pregnancy.

      Father0..2 IS A TRUNCATED PREVIEW. The authoritative list is
      FW.ChildFather on the mother, one entry per child matching FW.NumChilds -
      Beeing Female models different fathers within a single birth. We do not
      need it here for the reason above, but nothing downstream should ever
      treat three as the maximum. }
    If !IsEnabled()
        Return
    EndIf
    Actor mum = akMother as Actor
    If mum == None
        Return
    EndIf
    Int n = aiChildCount
    If n < 1
        n = 1
    EndIf
    Int grp = NextBirthGroup()
    JsonUtil.SetIntValue(StoreFile(), "bfPending." + mum.GetFormID() + ".group", grp)
    JsonUtil.SetIntValue(StoreFile(), "bfPending." + mum.GetFormID() + ".count", n)
    JsonUtil.SetFloatValue(StoreFile(), "bfPending." + mum.GetFormID() + ".at", \
        Utility.GetCurrentGameTime())
    JsonUtil.Save(StoreFile())
    Diag(LOG_INFO(), "Beeing Female: " + mum.GetDisplayName() + " delivering " + n + \
        " child(ren), birth group " + grp + ".")
EndEvent

Function NoteBfChildren() Global
    { Picks up Beeing Female's spawned children and records the player's.

      Walks FW.Babys, the global FormList of live child actors that Beeing
      Female documents for exactly this purpose. Cheap enough for the sweep:
      the list holds live children only, and every entry is skipped in one
      lookup once it has been recorded. }
    If !HasBfng()
        Return
    EndIf
    Int n = StorageUtil.FormListCount(None, "FW.Babys")
    If n <= 0
        Return
    EndIf
    Actor player = Game.GetPlayer()
    Int i = 0
    While i < n
        Actor kid = StorageUtil.FormListGet(None, "FW.Babys", i) as Actor
        If kid != None && JsonUtil.GetIntValue(StoreFile(), \
                "ref." + kid.GetFormID() + ".child", -1) < 0
            Actor mum = StorageUtil.GetFormValue(kid, "FW.Child.Mother", None) as Actor
            Actor dad = StorageUtil.GetFormValue(kid, "FW.Child.Father", None) as Actor
            ; MOD SCOPE. Beeing Female tracks every woman in Skyrim; this mod is
            ; about the player's family. A child of two NPCs is somebody else's
            ; business and recording it would bloat the roster with people the
            ; player will never be told about.
            If mum == player || dad == player
                RecordBfChild(kid, mum, dad)
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

Function RecordBfChild(Actor akKid, Actor akMother, Actor akFather) Global
    { One Beeing Female child, with both parents already known.

      A SEPARATE PATH FROM RecordChild ON PURPOSE. That one exists to RECOVER a
      mother Fertility Mode never stored - the awaiting watch list, the tie
      shortlists, the candidate ladder. None of that applies here, because
      Beeing Female hands us both parents outright. Routing this through the
      recovery machinery would mean running an elaborate guess over an answer
      we already have, and risking it overriding the truth. }
    If akKid == None
        Return
    EndIf
    String nm = akKid.GetDisplayName()
    If nm == ""
        Return
    EndIf

    Int grp = 0
    If akMother != None
        Float at = JsonUtil.GetFloatValue(StoreFile(), \
            "bfPending." + akMother.GetFormID() + ".at", 0.0)
        ; A WINDOW, because the labour event fires before the spawn and the
        ; sweep arrives later still. Two game days is far wider than that gap
        ; and far narrower than any plausible next pregnancy - Beeing Female
        ; will not deliver the same mother twice inside it.
        If at > 0.0 && (Utility.GetCurrentGameTime() - at) < 2.0
            grp = JsonUtil.GetIntValue(StoreFile(), \
                "bfPending." + akMother.GetFormID() + ".group", 0)
        EndIf
    EndIf

    JsonUtil.StringListAdd(StoreFile(), "roster", nm, False)
    Int idx = JsonUtil.StringListFind(StoreFile(), "roster", nm)
    If idx < 0
        Diag(LOG_ERROR(), "RecordBfChild: '" + nm + "' would not stay on the roster.")
        Return
    EndIf

    String mumName = ""
    Int mumId = 0
    If akMother != None
        mumName = akMother.GetDisplayName()
        mumId = akMother.GetFormID()
        RememberPerson(akMother)
    EndIf
    String dadName = ""
    Int dadId = 0
    If akFather != None
        dadName = akFather.GetDisplayName()
        dadId = akFather.GetFormID()
        RememberPerson(akFather)
    EndIf
    ; Same rule as the Fertility Mode path: a parent can never be both.
    If dadId != 0 && dadId == mumId
        dadName = ""
        dadId = 0
    EndIf

    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".name", nm)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".mother", mumName)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".father", dadName)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".motherId", mumId)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".fatherId", dadId)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".gender", GenderWord(akKid))
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".source", SRC_BFNG())
    ; THE BARE GIVEN NAME, kept alongside the display name. Beeing Female sets
    ; the display name to childName + a family name, and carries only the bare
    ; childName in FW.Child.Name onto the grown adult - so this is the half that
    ; survives growing up and the half DetectBfGrowUp matches on.
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".bfName", \
        StorageUtil.GetStringValue(akKid, "FW.Child.Name", ""))
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".birthGroup", grp)
    ; BEEING FEMALE'S OWN DATE OF BIRTH, not ours. It records FW.Child.DOB at
    ; the actual birth; our own stamp would be whenever the sweep first noticed,
    ; which is the very error that makes seeded children compute as newborns.
    Float dob = StorageUtil.GetFloatValue(akKid, "FW.Child.DOB", 0.0)
    If dob <= 0.0
        dob = Utility.GetCurrentGameTime()
    EndIf
    JsonUtil.SetFloatValue(StoreFile(), "child." + idx + ".born", dob)
    If mumId != 0
        JsonUtil.IntListAdd(StoreFile(), ParentPath(mumId), idx, False)
    EndIf
    If dadId != 0
        JsonUtil.IntListAdd(StoreFile(), ParentPath(dadId), idx, False)
    EndIf
    JsonUtil.Save(StoreFile())

    BindChildRef(akKid, idx)
    MarkChildActor(akKid, idx)
    CaptureUuid(idx, akKid)
    RefreshParentCount(mumId)
    RefreshParentCount(dadId)
    RefreshChildTotal()

    Diag(LOG_INFO(), "Beeing Female child recorded: " + nm + " - mother " + \
        mumName + ", father " + dadName + ", birth group " + grp + ".")
EndFunction

Function DetectBfGrowUp() Global
    { Notices a Beeing Female child who has become an adult.

      NOTHING ANNOUNCES THIS. FWSystem.GrowChildToAdult spawns the adult,
      copies the identity keys onto it, then calls child.Delete() in the same
      function - and emits no mod event. So the only way to see it is to find
      the adult afterwards, carrying the child's identity.

      Which is precisely why CaptureUuid runs at record time rather than here:
      by the time this notices, the child reference no longer exists and its
      SkyrimNet UUID could never be read again.

      MATCHED ON THE BARE NAME PLUS THE MOTHER. Beeing Female's display name is
      childName + a family name, so siblings and cousins can share it; the
      mother disambiguates. Deliberately NOT matched on display name alone -
      the same rule that stops the roster repair merging two people who happen
      to be called Kayla. }
    If !HasBfng()
        Return
    EndIf

    ; CHEAP FIRST PASS. Almost always finds nothing, and when it does the
    ; expensive scan below is the only way to resolve it. One GetFormEx per
    ; Beeing Female child beats walking FW.Babys on every sweep forever.
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Bool anyLost = False
    Int i = 0
    While i < n && !anyLost
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".source", 0) == SRC_BFNG()
            Int rid = JsonUtil.GetIntValue(StoreFile(), "child." + i + ".refId", 0)
            If rid != 0 && Game.GetFormEx(rid) == None
                anyLost = True
            EndIf
        EndIf
        i += 1
    EndWhile
    If !anyLost
        Return
    EndIf

    Int babies = StorageUtil.FormListCount(None, "FW.Babys")
    i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".source", 0) == SRC_BFNG()
            Int rid = JsonUtil.GetIntValue(StoreFile(), "child." + i + ".refId", 0)
            If rid != 0 && Game.GetFormEx(rid) == None
                String want = JsonUtil.GetStringValue(StoreFile(), "child." + i + ".bfName", "")
                Int wantMum = JsonUtil.GetIntValue(StoreFile(), "child." + i + ".motherId", 0)
                Int b = 0
                Bool done = False
                While b < babies && !done
                    Actor cand = StorageUtil.FormListGet(None, "FW.Babys", b) as Actor
                    If cand != None && StorageUtil.GetIntValue(cand, "FW.Child.GrownUp", 0) == 1
                        Actor cm = StorageUtil.GetFormValue(cand, "FW.Child.Mother", None) as Actor
                        Int cmId = 0
                        If cm != None
                            cmId = cm.GetFormID()
                        EndIf
                        String cn = StorageUtil.GetStringValue(cand, "FW.Child.Name", "")
                        If want != "" && cn == want && cmId == wantMum
                            Diag(LOG_INFO(), JsonUtil.GetStringValue(StoreFile(), \
                                "child." + i + ".name", "?") + " has grown up (Beeing Female).")
                            RecordSuccession(i, cand)
                            done = True
                        EndIf
                    EndIf
                    b += 1
                EndWhile
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

; ---------------------------------------------------------------------------
; OWNING A FERTILITY MODE BIRTH
;
; Fertility Mode registers a child when it MATURES, not when it is born -
; PlayerChildAdd is called from inside CheckBabyGrowth's day-ten spawn branch.
; Everything this mod knew about a child therefore arrived ten days late, from
; the very event that taking the baby item is meant to prevent. That circularity
; is why kinStageConfiscate did nothing at all until now.
;
; So when the item is taken, the birth has to be recorded from the LABOUR event
; instead, and this mod takes over what Fertility Mode would have decided:
; gender, name, and when a body appears.
;
; STRICTLY OPT-IN, AND OFF BY DEFAULT. With kinStageConfiscate off, none of this
; runs and the original day-ten path is untouched - which matters because that
; path is the one with play-verified behaviour behind it.
; ---------------------------------------------------------------------------

Bool Function OwnsFmrBirth() Global
    { True when this mod, not Fertility Mode, is running the childhood. }
    Return HasFmr() && StagesEnabled() && ConfiscateEnabled()
EndFunction

Int Function FmrRaceIndex(_JSW_BB_Storage akStore, Actor akMother) Global
    { The mother's row in Fertility Mode's parallel race arrays.

      BirthMotherRace, BirthChildRace, BirthBabyRace and Children are all
      indexed the same way, so one lookup serves for the child's race and its
      actor base. Vampire mothers live in a second array of the same order. }
    If akStore == None || akMother == None
        Return -1
    EndIf
    Race r = akMother.GetRace()
    If r == None
        Return -1
    EndIf
    Race[] normal = akStore.BirthMotherRace
    Int hit = -1
    If normal != None
        hit = normal.Find(r)
    EndIf
    If hit < 0
        Race[] vamp = akStore.BirthMotherRaceVampire
        If vamp != None
            hit = vamp.Find(r)
        EndIf
    EndIf
    Return hit
EndFunction

Function ClaimFmrBirth(Actor akMother, String asFather, Int aiFatherId) Global
    { Records a Fertility Mode birth at the moment it happens.

      THE NAME IS DEFERRED, NOT SKIPPED. A roster entry is keyed by its name,
      so one is needed now; but labour fires wherever the mother is, which may
      be mid-combat or on the far side of Skyrim, and a modal text box there is
      hostile. The record takes a placeholder and raises needsName, and
      PromptPendingNames asks when the player is actually able to answer. }
    If akMother == None
        Return
    EndIf
    Int grp = NextBirthGroup()
    String placeholder = "(unnamed " + grp + ")"
    JsonUtil.StringListAdd(StoreFile(), "roster", placeholder, False)
    Int idx = JsonUtil.StringListFind(StoreFile(), "roster", placeholder)
    If idx < 0
        Diag(LOG_ERROR(), "ClaimFmrBirth: could not open a roster entry.")
        Return
    EndIf

    ; GENDER IS OURS NOW. Fertility Mode rolled it at spawn time, inside the
    ; branch we are suppressing, so nobody else is going to decide it.
    Int sex = Utility.RandomInt(0, 1)
    String word = "son"
    If sex == 1
        word = "daughter"
    EndIf

    String mumName = akMother.GetDisplayName()
    Int mumId = akMother.GetFormID()
    RememberPerson(akMother)
    ; The mother can never also be the father - same rule as both other paths.
    If aiFatherId != 0 && aiFatherId == mumId
        aiFatherId = 0
        asFather = ""
    EndIf

    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".name", placeholder)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".mother", mumName)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".motherId", mumId)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".father", asFather)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".fatherId", aiFatherId)
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".gender", word)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".sex", sex)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".source", SRC_FMR())
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".birthGroup", grp)
    JsonUtil.SetFloatValue(StoreFile(), "child." + idx + ".born", Utility.GetCurrentGameTime())
    ; OWNED means we claimed this birth and are responsible for its body. Every
    ; record that predates this feature lacks the key, which is exactly right:
    ; nothing already on the roster should suddenly grow an actor.
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".owned", 1)
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".needsName", 1)
    If mumId != 0
        JsonUtil.IntListAdd(StoreFile(), ParentPath(mumId), idx, False)
    EndIf
    If aiFatherId != 0
        JsonUtil.IntListAdd(StoreFile(), ParentPath(aiFatherId), idx, False)
    EndIf
    JsonUtil.Save(StoreFile())
    RefreshParentCount(mumId)
    RefreshParentCount(aiFatherId)
    RefreshChildTotal()

    Diag(LOG_WARN(), "Claimed the birth of " + mumName + "'s " + word + \
        " (birth group " + grp + "). This mod is running this childhood; " + \
        "Fertility Mode will not mature the child on its own timer.")
    If Notify()
        Debug.Notification("[Kinship] " + mumName + " has given birth")
    EndIf
EndFunction

Int Function OwnedBirthFor(Int aiMotherId) Global
    { The claimed child THIS mother is currently carrying for us, or -1.

      KEYED ON THE MOTHER, not merely on time. An earlier version asked only
      whether any claimed birth was pending, which is a different question with
      the same answer most of the time - and the wrong answer exactly when it
      matters. A player with one claimed birth in flight and one older Fertility
      Mode baby maturing would have had the legitimate child silently dropped,
      because some claim was pending and nothing checked whose.

      The window is FMR's own BabyDuration plus slack, read live rather than
      assumed: three days and thirty are both configurable and only FMR knows
      which is set. }
    If aiMotherId == 0
        Return -1
    EndIf
    Float window = BabyDurationDays()
    If window <= 0.0
        window = 14.0
    EndIf
    window += 2.0
    Float now = Utility.GetCurrentGameTime()
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".owned", 0) == 1 \
                && JsonUtil.GetIntValue(StoreFile(), "child." + i + ".motherId", 0) == aiMotherId
            Float born = JsonUtil.GetFloatValue(StoreFile(), "child." + i + ".born", 0.0)
            If born > 0.0 && (now - born) >= 0.0 && (now - born) <= window
                Return i
            EndIf
        EndIf
        i += 1
    EndWhile
    Return -1
EndFunction

Function AdoptInFlightBirths()
    { Claims babies that were already on the way when the feature was switched
      on.

      THE CASE THIS EXISTS FOR: a mother who delivered before confiscation was
      enabled is carrying a baby item right now. Her labour event fired when
      nothing was listening for it, so there is no claimed record; and with no
      record, nothing ever visits her to take the item. Left alone she would
      quietly complete under Fertility Mode's rules ten days later - which is
      not what turning the setting on says it does.

      So the in-flight window is swept once and those births are claimed
      retroactively. THE FATHER IS STILL READABLE at this point and will not be
      later: CheckBabyGrowth does not clear LastFather until it creates the
      child record, which is the very thing being pre-empted.

      Also makes the duplicate guard nearly unreachable, since after this pass
      every baby in flight is one we own. }
    If !OwnsFmrBirth()
        Return
    EndIf
    _JSW_BB_Storage store = ResolveStorage()
    If store == None
        Return
    EndIf
    Float[] added = store.BabyAdded
    Form[] tracked = store.TrackedActors
    If added == None || tracked == None
        Return
    EndIf
    Float window = BabyDurationDays()
    If window <= 0.0
        window = 14.0
    EndIf
    Float now = Utility.GetCurrentGameTime()
    Int i = 0
    While i < tracked.Length
        Actor mum = tracked[i] as Actor
        If mum != None && i < added.Length && added[i] > 0.0
            Float age = now - added[i]
            ; Inside the window only. Past it Fertility Mode has either already
            ; matured the child or is about to on its own next poll, and racing
            ; that is how one child ends up recorded twice.
            If age >= 0.0 && age < window && OwnedBirthFor(mum.GetFormID()) < 0 \
                    && StorageUtil.GetIntValue(mum, "SNKin_ByPlayer", 0) == 1
                String dadName = FatherNameAt(i)
                Int dadId = 0
                Actor player = Game.GetPlayer()
                If dadName == player.GetDisplayName()
                    dadId = player.GetFormID()
                ElseIf dadName != ""
                    dadId = PersonIdByName(dadName)
                EndIf
                ; THE FLAG ABOVE ALREADY SETTLED THIS. Reaching here at all
                ; required SNKin_ByPlayer, which is only ever set for a birth
                ; the player fathered - so if Fertility Mode's father arrays
                ; have gone empty in the days since, the answer is still known.
                ;
                ; Not hypothetical: both mothers adopted on the live save came
                ; through with no father at all, because FatherNameAt reads
                ; CurrentFather then LastFather and by then Fertility Mode had
                ; cleared both. Two of the player's children were recorded
                ; fatherless with the answer sitting in a flag we had checked
                ; one line earlier.
                ;
                ; Guarded on the mother NOT being the player, because on a
                ; female playthrough the player is the one giving birth and the
                ; father is somebody else entirely.
                If dadId == 0 && mum != player
                    dadId = player.GetFormID()
                    dadName = player.GetDisplayName()
                    Diag(LOG_INFO(), "Fertility Mode no longer remembers the father for " + \
                        mum.GetDisplayName() + "; recording the player, who is who the " + \
                        "delivery was flagged to in the first place.")
                EndIf
                Diag(LOG_WARN(), "Adopting a birth already in progress: " + \
                    mum.GetDisplayName() + " has carried a baby for " + age + \
                    " days. This mod is taking over that childhood.")
                ClaimFmrBirth(mum, dadName, dadId)
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

Bool Function RenameChildStatic(String asOldName, String asNewName) Global
    { Renames a child from the panel.

      THE ONE FIELD THAT HAD NO EDITOR. Mother, father and stage were all
      correctable and the name was not - so a child the naming prompt missed
      was stuck as "(unnamed 11)" with nowhere to fix it. That is exactly the
      record most in need of an edit.

      REFUSES A DUPLICATE rather than taking it. The roster is keyed by name:
      a second Maya would be unfindable by ChildIndex, and every later lookup
      would silently resolve to the first one. }
    If asNewName == "" || asOldName == asNewName
        Return False
    EndIf
    Int idx = ChildIndex(asOldName)
    If idx < 0
        Diag(LOG_ERROR(), "Rename: no child named '" + asOldName + "'.")
        Return False
    EndIf
    If JsonUtil.StringListFind(StoreFile(), "roster", asNewName) >= 0
        Diag(LOG_WARN(), "Rename refused: there is already a " + asNewName + \
            " on the family roster.")
        Return False
    EndIf
    RenameChildRecord(idx, asNewName)
    Diag(LOG_INFO(), "Renamed " + asOldName + " to " + asNewName + ".")
    Return True
EndFunction

Bool Function SetChildStageStatic(String asChildName, Int aiStage) Global
    { Corrects a child's life stage by hand. The panel's write path.

      A GLOBAL TWIN for the same reason ClearParentStatic is one:
      DispatchStaticCall cannot reach an instance method, and resolving the
      quest from the DLL would mean hardcoding our own plugin filename.

      PLANTS RATHER THAN SETS, which is the whole correctness of it. Writing
      child.N.stage alone would last exactly until the next sweep, when the
      clock recomputed the old value from the birth stamp and overwrote it.
      PlantStage moves the FLOOR as well, so the arithmetic and the correction
      agree from now on and the child ages onward from where it was put rather
      than being frozen there. }
    If aiStage < 0 || aiStage > STAGE_ADULT()
        Return False
    EndIf
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "SetChildStage: no child named '" + asChildName + "'.")
        Return False
    EndIf
    PlantStage(idx, aiStage)
    ; A HUMAN DECISION OUTRANKS AN INFERENCE, permanently.
    ;
    ; Without this the correction did not stick for any child who was not
    ; beside the player: the body could not answer, so the next refresh fell
    ; through to SNKin_Bound, read "summoned adult", and planted them back at
    ; adult in the same instant the panel wrote the change. Ten edits, five of
    ; which silently undid themselves depending on which cell the child was in.
    ;
    ; The BODY may still override this - it is direct evidence, and a visibly
    ; grown actor is grown whatever the record says. Only proxies defer.
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".manualStage", 1)
    ; The stamp the clock ages from has to move too, or the child is instantly
    ; as old as its record claims and jumps straight back out of the stage it
    ; was just put in.
    JsonUtil.SetFloatValue(StoreFile(), "child." + idx + ".stageBase", \
        Utility.GetCurrentGameTime())
    JsonUtil.Save(StoreFile())
    Diag(LOG_INFO(), asChildName + " set to " + StageName(aiStage) + " by hand.")

    ; Republish immediately where there is an actor, so the correction is
    ; visible in the next bio rather than after the next sweep.
    Int rid = JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".refId", 0)
    If rid != 0
        Actor a = Game.GetFormEx(rid) as Actor
        If a != None
            RefreshChildStage(idx, a)
        EndIf
    EndIf
    Return True
EndFunction

Function RenameChildRecord(Int aiIdx, String asNewName) Global
    { Renames a record, roster key included.

      The roster is the index, so both halves must move together or the entry
      becomes unfindable by name - which is how a child stops being resolvable
      to its own bio. }
    If aiIdx < 0 || asNewName == ""
        Return
    EndIf
    JsonUtil.StringListSet(StoreFile(), "roster", aiIdx, asNewName)
    JsonUtil.SetStringValue(StoreFile(), "child." + aiIdx + ".name", asNewName)
    JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".needsName", 0)
    JsonUtil.Save(StoreFile())
    Int rid = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".refId", 0)
    If rid != 0
        Actor a = Game.GetFormEx(rid) as Actor
        If a != None
            ; true = force. The base is shared between children of one
            ; archetype, so SetName would rename every sibling using it.
            a.SetDisplayName(asNewName, True)
        EndIf
    EndIf
EndFunction

String Function NamesFile() Global
    { Our own name pools. NOT Fertility Mode's file.

      FMR keeps its list at StorageUtilData/FertilityModeNames.json and reads it
      through JContainers, as two flat arrays - "Male" and "Female" - with a
      comment in its own source noting it dropped race-specific keys for
      simplicity. Two reasons not to read it directly: it would add JContainers
      as a dependency this mod does not otherwise need, and its top-level arrays
      are not in PapyrusUtil's typed-bucket layout, so JsonUtil cannot see them.

      So the pools are ours, seeded FROM FMR's 301 names as the fallback and
      extended with the race-specific lists it does not have. Anyone can add
      more by editing the file; nothing here is compiled in. }
    Return "../SNKin_Names"
EndFunction

String Function RaceKey(Actor akWho) Global
    { A race name folded into a lookup key: "Dark Elf" -> "darkelf".

      Returns "" when there is nothing to fold, and the caller then falls back
      to the flat pool - which is the same behaviour as a race that simply has
      no list of its own. }
    If akWho == None
        Return ""
    EndIf
    Race r = akWho.GetRace()
    If r == None
        Return ""
    EndIf
    String n = r.GetName()
    If n == ""
        Return ""
    EndIf
    ; Lowercase and drop spaces. StringUtil has no replace, so this walks the
    ; string once - it runs at most once per naming prompt, not per frame.
    String out = ""
    Int i = 0
    While i < StringUtil.GetLength(n)
        String c = StringUtil.GetNthChar(n, i)
        If c != " " && c != "-"
            out += c
        EndIf
        i += 1
    EndWhile
    Return ToLower(out)
EndFunction

String Function ToLower(String asText) Global
    { Papyrus has no case conversion. Walks the string against a pair of
      alphabets, which is ugly and completely adequate for a race name. }
    String upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    String lower = "abcdefghijklmnopqrstuvwxyz"
    String out = ""
    Int i = 0
    While i < StringUtil.GetLength(asText)
        String c = StringUtil.GetNthChar(asText, i)
        Int at = StringUtil.Find(upper, c)
        If at >= 0
            out += StringUtil.GetNthChar(lower, at)
        Else
            out += c
        EndIf
        i += 1
    EndWhile
    Return out
EndFunction

String[] Function NamePool(String asRaceKey, Int aiSex) Global
    { Names to offer, race-specific where a list exists and flat otherwise.

      A missing race list is not an error - most races will not have one, and
      the fallback is a full 150-name pool rather than nothing. }
    String sex = "male"
    If aiSex == 1
        sex = "female"
    EndIf
    Int n = 0
    If asRaceKey != ""
        n = JsonUtil.StringListCount(NamesFile(), asRaceKey + "." + sex)
    EndIf
    ; NOT "key" - Key is a Skyrim form type, and naming a local after one fails
    ; with "cannot name a variable the same as a known type". Same trap as Race,
    ; Parent and Light, all of which this file already documents.
    String poolKey = asRaceKey + "." + sex
    If n <= 0
        poolKey = sex
        n = JsonUtil.StringListCount(NamesFile(), poolKey)
    EndIf
    If n <= 0
        Return None
    EndIf
    Return JsonUtil.StringListToArray(NamesFile(), poolKey)
EndFunction

Bool Function NameFromList() Global
    Return SkyrimNetApi.GetConfigBool(CFG(), "kinNameFromList", False)
EndFunction

Function PromptPendingNames() Global
    { Asks for a name for every claimed child that is waiting for one.

      ALL OF THEM, ONE AFTER ANOTHER, matching what Fertility Mode does - it
      pops however many boxes it needs and cycles through them. An earlier
      version asked about one child per sweep on the theory that consecutive
      modal boxes were worse than waiting. In practice the wait is worse: two
      mothers adopted in the same sweep left one child named and one sitting as
      "(unnamed 11)" with no visible reason, and before the poll was fixed the
      queue only advanced on a game load.

      Still not during a fight or a menu. That part was right. }
    If !OwnsFmrBirth()
        Return
    EndIf
    If Utility.IsInMenuMode() || Game.GetPlayer().IsInCombat()
        Return
    EndIf
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".needsName", 0) == 1
            String word = JsonUtil.GetStringValue(StoreFile(), "child." + i + ".gender", "child")
            String mum = JsonUtil.GetStringValue(StoreFile(), "child." + i + ".mother", "")
            String given = ""
            If NameFromList()
                ; RACE FROM THE MOTHER, since the child has no actor yet - it is
                ; being named before it has a body, which is the whole point of
                ; owning the birth.
                Actor mother = Game.GetFormEx( \
                    JsonUtil.GetIntValue(StoreFile(), "child." + i + ".motherId", 0)) as Actor
                given = SNKin_Picker.AskChildNameFromList(word, mum, \
                    NamePool(RaceKey(mother), ChildSex(i)))
            Else
                given = SNKin_Picker.AskChildName(word, mum)
            EndIf
            If given != ""
                RenameChildRecord(i, given)
                Diag(LOG_INFO(), "Named " + mum + "'s " + word + " " + given + ".")
            Else
                ; DECLINED IS AN ANSWER, and asking again every sweep would be
                ; harassment. A generated name keeps the record usable and the
                ; panel can still change it.
                RenameChildRecord(i, GeneratedChildName(i, word))
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

String Function GeneratedChildName(Int aiIdx, String asWord) Global
    { A last-resort name. Deliberately obvious rather than pseudo-Nordic - a
      placeholder that looks like a real name is one nobody notices to fix. }
    String mum = JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".mother", "")
    If mum != ""
        Return mum + "'s " + asWord
    EndIf
    Return "Unnamed " + asWord
EndFunction

Int Function ChildSex(Int aiIdx) Global
    { 0 male, 1 female, for indexing Fertility Mode's paired base arrays.

      FALLS BACK TO THE GENDER WORD, because `sex` only exists on records this
      mod created itself. Every child that came through Fertility Mode's own
      registration has "son" or "daughter" and no number, and defaulting those
      to 0 would have made every one of them a boy. }
    Int sex = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".sex", -1)
    If sex >= 0
        Return sex
    EndIf
    If JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".gender", "") == "daughter"
        Return 1
    EndIf
    Return 0
EndFunction

Function InheritHome(Actor akChild, Actor akMother) Global
    { Gives a newly embodied child its mother's home.

      SEVERACTIONS OWNS WHERE PEOPLE LIVE in this setup, and it keeps a home
      per actor in the SKSE co-save rather than in StorageUtil - its own
      comment calls that "unreliable string persistence", which matches what
      this mod learned the hard way about StorageUtil strings not surviving a
      reload.

      SOFT, LIKE EVERY OTHER OUTSIDE DEPENDENCY HERE. Absent SeverActions this
      returns immediately and the child simply has no home, which is the same
      position Fertility Mode's own spawned children are in. Nothing about
      parentage or stages depends on it. }
    If akChild == None || akMother == None
        Return
    EndIf
    If Game.GetModByName("severactions.esp") == 255 && \
       Game.GetLightModByName("severactions.esp") == 255
        Return
    EndIf
    String where = SeverActionsNative.Native_GetHome(akMother)
    If where == ""
        ; She has no home recorded either. Nothing to inherit, and inventing
        ; one would put the child somewhere its mother is not.
        Diag(LOG_DEBUG(), akMother.GetDisplayName() + " has no home recorded, so " + \
            akChild.GetDisplayName() + " inherits none.")
        Return
    EndIf
    SeverActionsNative.Native_SetHome(akChild, where)
    Diag(LOG_INFO(), akChild.GetDisplayName() + " now lives where " + \
        akMother.GetDisplayName() + " does: " + where + ".")
EndFunction

Bool Function SpawnChildBodyStatic(String asChildName) Global
    { Gives a recorded child an actor, on demand. The panel's entry point.

      THE CASE THIS EXISTS FOR: a child Fertility Mode named and then did
      nothing with. It was never sent to training and never adopted, so it has
      a record, a mother and a father, and no body anywhere in the world - and
      no way to acquire one, because adoption is capped and training is a
      one-way trip to adulthood. On the save this was written against there
      were thirty-six of them.

      DELIBERATELY ONE AT A TIME. The automatic path is gated on `owned`, which
      only births this mod claimed ever carry, precisely so that switching
      stages on could never spawn a roster's worth of NPCs at once. This opens
      that gate for a single child the player has actually chosen. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "SpawnChildBody: no child named '" + asChildName + "'.")
        Return False
    EndIf
    If JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".hidden", 0) == 1
        Return False
    EndIf
    Int rid = JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".refId", 0)
    If rid != 0 && Game.GetFormEx(rid) != None
        Diag(LOG_WARN(), asChildName + " already has a body.")
        Return False
    EndIf
    ; TOO YOUNG FOR ONE. Newborn and infant have no actor in this model - a
    ; newborn is a carried item, not a body - so a request for one is refused
    ; rather than quietly producing a toddler-sized newborn. A stage of -1 means
    ; stages are switched off entirely, and then there is no age to object to.
    Int st = JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".stage", -1)
    If st >= 0 && st < 2
        Diag(LOG_WARN(), asChildName + " is a " + StageName(st) + \
            " and has no body at that age. Wait until toddler, or set the stage by hand.")
        Return False
    EndIf
    ; Clear a stale marker so a previous failure does not block a retry after
    ; the reason for it has been fixed.
    JsonUtil.SetIntValue(StoreFile(), "child." + idx + ".spawnFailed", 0)
    JsonUtil.Save(StoreFile())
    Return SpawnOwnedChild(idx) != None
EndFunction

Actor Function SpawnOwnedChild(Int aiIdx) Global
    { Gives a claimed child a body, at the stage where one becomes true.

      NOT AT FERTILITY MODE'S BABY DURATION. Newborn and infant have no body in
      this model at all - a newborn is a carried item, not an actor - so the
      first stage that warrants one is toddler. Spawning at ten days would put
      a walking child on a record that still says infant, which is the exact
      contradiction taking the item was meant to remove.

      Uses Fertility Mode's own child bases, which is the one thing a birth
      event cannot provide and the only remaining hard dependency on it. }
    _JSW_BB_Storage store = ResolveStorage()
    If store == None
        Return None
    EndIf
    Int mumId = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".motherId", 0)
    Actor mum = Game.GetFormEx(mumId) as Actor
    Int raceIdx = FmrRaceIndex(store, mum)
    If raceIdx < 0
        Diag(LOG_WARN(), "SpawnOwnedChild: " + \
            JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".name", "?") + \
            " has no supported child race for its mother - no body will appear. " + \
            "The record and its parentage are unaffected.")
        ; Marked so this is not retried every sweep forever.
        JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".spawnFailed", 1)
        JsonUtil.Save(StoreFile())
        Return None
    EndIf
    ActorBase[] bases = store.Children
    Int sex = ChildSex(aiIdx)
    Int slot = 2 * raceIdx + sex
    If bases == None || slot < 0 || slot >= bases.Length || bases[slot] == None
        JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".spawnFailed", 1)
        JsonUtil.Save(StoreFile())
        Return None
    EndIf

    ; AT THE MOTHER WHEN SHE IS THERE, at the player otherwise. A child that
    ; materialises next to its mother reads as having been brought to you;
    ; one that appears at the player when she is elsewhere at least appears
    ; somewhere the player will notice rather than in an empty cell.
    ObjectReference at = mum as ObjectReference
    If at == None || !mum.Is3DLoaded()
        at = Game.GetPlayer() as ObjectReference
    EndIf
    Actor kid = at.PlaceActorAtMe(bases[slot]) as Actor
    If kid == None
        Diag(LOG_WARN(), "SpawnOwnedChild: PlaceActorAtMe failed.")
        Return None
    EndIf
    kid.QueueNiNodeUpdate()
    String nm = JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".name", "")
    If nm != ""
        kid.SetDisplayName(nm, True)
    EndIf
    kid.MakePlayerFriend()
    If mum != None
        kid.SetRelationshipRank(mum, 2)
        mum.SetRelationshipRank(kid, 2)
    EndIf
    Int dadId = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".fatherId", 0)
    Actor dad = Game.GetFormEx(dadId) as Actor
    If dad != None
        kid.SetRelationshipRank(dad, 2)
        dad.SetRelationshipRank(kid, 2)
    EndIf

    JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".refId", kid.GetFormID())
    JsonUtil.Save(StoreFile())
    ; BEFORE BindChildRef, which sets SNKin_Bound - and SNKin_Bound alone used
    ; to mean "summoned adult". This says who placed the actor, so the stage
    ; rules can tell a child we spawned from an adult Fertility Mode summoned.
    StorageUtil.SetIntValue(kid, "SNKin_OurSpawn", 1)
    ; AND IN THE STORE, because the co-save flag is only readable with the
    ; actor in hand and the stage rules must answer for children nowhere
    ; near the player. This one is durable and index-keyed.
    JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".ourSpawn", 1)
    BindChildRef(kid, aiIdx)
    MarkChildActor(kid, aiIdx)
    ; A child belongs where its mother lives. Soft - no SeverActions, no home,
    ; and nothing else is affected.
    InheritHome(kid, mum)
    Diag(LOG_INFO(), (nm + " has a body now (" + StageName(StageForChild(aiIdx)) + ")."))
    Return kid
EndFunction

Int Function ChildSource(Int aiIdx) Global
    { Which fertility mod this child came from. Absent means Fertility Mode -
      every record written before this existed came from that path. }
    Return JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".source", SRC_FMR())
EndFunction

Function CarryIdentity(Int aiIdx, String asWasUuid, String asNowUuid) Global
    { The one swappable function. Plan A becomes a one-line body here.

      Deliberately a NO-OP THAT SAYS SO rather than a silent one. Someone who
      shortens every stage duration to a day will reach this within an evening,
      and "the memories did not carry" is a limitation they can understand
      where silence would read as a bug. The parentage still renders either
      way - that comes from our own store and is reference-independent. }
    If asWasUuid == "" || asNowUuid == "" || asWasUuid == asNowUuid
        Return
    EndIf
    Diag(LOG_WARN(), JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".name", "?") + \
        " grew up into a new reference. Parentage carries over; SkyrimNet " + \
        "memories from childhood do not, because a succession cannot yet be " + \
        "declared for a runtime-spawned actor. The pair is recorded and can be " + \
        "declared retroactively.")
EndFunction

; ---------------------------------------------------------------------------
; SIZE
;
; Skyrim has a child body and an adult body and nothing between, so toddler,
; child and adolescent all wear the SAME mesh and are visually identical. That
; is the one thing the record layer cannot show, and scale is the only lever
; that needs no new assets.
;
; WHY SCALING A CHILD WORKS WHEN SCALING AN ADULT DOES NOT. A human child is
; not a small adult - head-to-body is roughly 1:4 at birth against 1:7.5 grown -
; so a shrunken ADULT reads as a dwarf. We are shrinking the CHILD mesh, whose
; proportions are already a child's, so this interpolates inside a correct
; proportion set instead of extrapolating out of the wrong one. It reads as a
; younger child, which is exactly what it is.
;
; SetScale, NOT NiOverride, and the reason is where the state lives.
; NiOverride's node transforms are serialised into the CO-SAVE - the same store
; that had to be rebuilt by hand after a deployment corrupted it, and which does
; not follow the roster. SetScale is a property of the reference in the main
; save. FMR reaches for NiOverride/NetImmerse itself, but only on "NPC Belly"
; and the breast nodes under its own key, and it never touches whole-actor
; scale, so there is nothing here to collide with.
;
; THE MIDDLE STAGE IS PINNED AT 1.0 ON PURPOSE. Every artifact of scaling -
; furniture alignment, foot sliding on an authored stride - is proportional to
; how far from 1.0 the actor is. Pinning `child` there means the stage that
; holds most of a childhood has NO artifacts at all, and the two neighbours sit
; close enough that the misalignment stays subtle.
; ---------------------------------------------------------------------------

Bool Function StageScalingEnabled() Global
    ; SEPARATE FROM kinStagesEnabled, deliberately. The record layer is exact
    ; and the visual trick is a compromise; someone who finds a child clipping
    ; into a chair intolerable should be able to drop the size and keep the
    ; stages, without giving up the parentage the stages feed.
    Return SkyrimNetApi.GetConfigBool(CFG(), "kinStageScaling", False)
EndFunction

Float Function ScaleForStage(Int aiStage) Global
    ; ONLY THE THREE STAGES THAT SHARE A BODY ARE SCALED.
    ;
    ; Newborn and infant return 1.0 because there is no actor to scale - FMR
    ; carries a baby ITEM, not a reference - and faking one at 0.3 would be a
    ; doll with broken collision, worse than the honest absence.
    ;
    ; Adult returns 1.0 because it is the restore path. A child who grows up
    ; must come back to full size, and FMR's SummonAdultChild can re-use the
    ; same reference - a 0.82 left behind would be a permanently stunted adult.
    If aiStage == 2
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinScaleToddler", 0.82)
    ElseIf aiStage == 3
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinScaleChild", 1.0)
    ElseIf aiStage == 4
        Return SkyrimNetApi.GetConfigFloat(CFG(), "kinScaleAdolescent", 1.12)
    EndIf
    Return 1.0
EndFunction

Float Function HeightVariance(Int aiIdx) Global
    { This child's personal height multiplier. 1.0 until something sets it.

      NOTHING WRITES THIS YET, and it is here anyway because of what it costs
      later if it is not. Real children of one age are not one height, and the
      obvious next step is a small per-child multiplier so a roster does not
      look like a rank of clones.

      Reserved now because the shape of the final scale is the whole question.
      Multiplicative rather than additive means a tall toddler is still tall as
      an adolescent AND as an adult - stage 5's base is 1.0, so an adult's size
      becomes exactly their variance and adult height variation falls out of
      this for free. Retrofitting that later would mean revisiting every scale
      already written; reading a default now costs one lookup. }
    Float v = JsonUtil.GetFloatValue(StoreFile(), "child." + aiIdx + ".scaleVar", 1.0)
    If v <= 0.0
        Return 1.0
    EndIf
    Return v
EndFunction

Function ApplyStageScale(Int aiIdx, Actor akKid, Int aiStage) Global
    { Sizes a child's actor to its stage, and puts it back when switched off. }
    If akKid == None
        Return
    EndIf
    ; HANDS OFF A CHILD SOMEBODY ELSE IS GROWING. Beeing Female grows children
    ; by scale on a clock of its own - the same technique, running already - so
    ; writing our own scale here would be two systems fighting over one value
    ; every sweep, and whichever wrote last would win. Its stages are better
    ; served by leaving them alone than by being reproduced.
    If SourceOwnsGrowth(ChildSource(aiIdx))
        Return
    EndIf
    String f = StoreFile()

    ; THE BASELINE IS WRITE-ONCE, and that is what stops it compounding. Read
    ; the actor's own scale before we have ever touched it and keep it; every
    ; later size is computed from that stored value rather than from whatever
    ; we left behind last sweep. 0.0 means "never scaled this child", which is
    ; also the flag the restore path below tests.
    Float base = JsonUtil.GetFloatValue(f, "child." + aiIdx + ".baseScale", 0.0)

    If !StagesEnabled() || !StageScalingEnabled()
        ; SWITCHED OFF MEANS PUT IT BACK. Leaving a shrunken actor behind after
        ; the feature is disabled would be a permanent change made by a setting
        ; that is no longer on - the user would have no way to connect the two.
        If base > 0.0
            If Math.Abs(akKid.GetScale() - base) > 0.01
                akKid.SetScale(base)
            EndIf
            ; THE BASELINE IS KEPT, NOT CLEARED. Clearing it meant the next
            ; enable had to re-measure - and re-measuring races the SetScale
            ; just issued above, so a baseline could be captured while a stage
            ; scale was still applied and then compound. Measured: Titus's
            ; baseline drifted 0.80 -> 0.64 across one off/on cycle.
            ;
            ; A baseline that is already known is always better than one
            ; measured again, because it was taken before anything touched the
            ; actor.
        EndIf
        Return
    EndIf

    If base <= 0.0
        base = akKid.GetScale()
        If base <= 0.0
            base = 1.0
        EndIf
        JsonUtil.SetFloatValue(f, "child." + aiIdx + ".baseScale", base)
        JsonUtil.Save(f)
    EndIf

    Float want = base * ScaleForStage(aiStage) * HeightVariance(aiIdx)

    ; A FLOOR AND A CEILING, because these are user-editable numbers and the
    ; failure is not symmetrical with the mistake. A typo of 0.082 for 0.82
    ; produces an actor that cannot path, cannot use furniture and may not be
    ; clickable - unrecoverable without editing the store by hand.
    If want < 0.5
        want = 0.5
    ElseIf want > 1.5
        want = 1.5
    EndIf

    ; IDEMPOTENT, which matters because this runs on every child every sweep.
    ; Comparing floats with an epsilon rather than for equality: GetScale
    ; returns what the engine stored, not the bits we sent it.
    If Math.Abs(akKid.GetScale() - want) > 0.01
        akKid.SetScale(want)
        ; SHOWS THE ARITHMETIC, NOT JUST THE ANSWER, and at INFO rather than
        ; DEBUG so it is visible by default.
        ;
        ; THE SETTING IS A RATIO, NOT A SIZE, and nothing said so until a child
        ; visibly shrank further than the number implied. Fertility Mode's child
        ; actors are natively 0.8 - that is the base object's own scale - so a
        ; toddler factor of 0.82 lands at 0.66, a third smaller than normal
        ; rather than the fifth the number reads like.
        ;
        ; The ratio is deliberate: it is what lets this work with any mod that
        ; sizes children differently, and "child" pinned at 1.00 means untouched
        ; whatever untouched happens to be. But an effective value nobody can
        ; see is a setting nobody can tune, so it is spelled out here.
        Diag(LOG_INFO(), JsonUtil.GetStringValue(f, "child." + aiIdx + ".name", "?") + \
            " scaled to " + want + " as " + StageName(aiStage) + \
            " (normal size " + base + " x " + ScaleForStage(aiStage) + ").")
    EndIf
EndFunction

; ---------------------------------------------------------------------------
; THE BABY ITEM
;
; Fertility Mode hands the mother a baby ARMOR at birth and spawns a child NPC
; when it has been worn for BabyDuration - ten game days by default. That is
; FMR's whole childhood: item, wait, child.
;
; Life stages are a DIFFERENT childhood, and the two cannot both be true. Left
; alone, FMR matures the child on day ten while this mod still has it recorded
; as an infant, and the player is then looking at a walking child whose own bio
; calls it a newborn.
;
; So opting into stages takes the item. Verified against FMR's source rather
; than assumed - _JSW_BB_HandlerQuestAliasScript.CheckBabyGrowth gates the
; entire spawn on
;
;     if (baby && ((now - Storage.BabyAdded[i]) as int) >= BabyDuration...)
;
; where `baby` is whichever BirthBabyRace armor was found IN THE INVENTORY. No
; item, no spawn. The EventLock it takes on entry is released unconditionally
; at the end of the function, so an early exit down that path cannot wedge FMR.
;
; THIS CANNOT BE UNDONE, and that is the whole reason it is a separate opt-in
; rather than something kinStagesEnabled implies. Turning stages back off later
; does not hand the baby back: the item is gone and FMR's clock is cleared.
; The setting is worded to say so.
; ---------------------------------------------------------------------------

Bool Function ConfiscateEnabled() Global
    Return SkyrimNetApi.GetConfigBool(CFG(), "kinStageConfiscate", False)
EndFunction

Int Function TakeBabyItem(Int aiIdx) Global
    { Removes FMR's baby armor from this child's mother and stops its clock.

      1 - taken. 2 - there was never anything to take, stop asking.
      0 - not knowable yet; ask again next sweep. }
    _JSW_BB_Storage store = ResolveStorage()
    If store == None
        Return 2
    EndIf

    Int motherId = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".motherId", 0)
    If motherId == 0
        ; NOT "nothing to take" - a tied birth records its mother later, and
        ; answering 2 here would close the question before it was asked.
        Return 0
    EndIf
    Actor mother = Game.GetFormEx(motherId) as Actor
    If mother == None
        Return 0
    EndIf

    ; ONE ARRAY, ONE CONVENTION. Every FMR call site indexes BabyAdded by
    ; TrackedActors.Find - the player included - so the +1 on BabyAdded's
    ; length is slack rather than a second convention to guess at. Getting this
    ; wrong would zero a DIFFERENT mother's clock, which is why it was read out
    ; of FMR's source instead of inferred from the array sizes.
    Int mi = store.TrackedActors.Find(mother)
    If mi < 0
        ; FMR is not tracking her at all, so there is no timer to stop.
        Return 2
    EndIf
    Float[] added = store.BabyAdded
    If mi >= added.Length || added[mi] <= 0.0
        ; NOT YET IS NOT THE SAME AS NEVER.
        ;
        ; The labour event fires as labour BEGINS - _JSW_BB_BirthEffect
        ; dispatches it - while GiveBirth hands over the item afterwards. A
        ; claimed birth therefore reaches this within the same sweep as the
        ; event, before BabyAdded has been stamped, and answering "nothing to
        ; take" there would close the question permanently one moment before
        ; the answer arrived.
        ;
        ; A day of grace covers that gap with room to spare. Past it, a zero
        ; genuinely means no item: Fertility Mode only stamps BabyAdded in its
        ; baby-item birth mode, and on the soul-gem and do-nothing settings
        ; there is no item in play for any birth at all.
        Float born = JsonUtil.GetFloatValue(StoreFile(), "child." + aiIdx + ".born", 0.0)
        If born > 0.0 && (Utility.GetCurrentGameTime() - born) < 1.0
            Return 0
        EndIf
        Return 2
    EndIf

    ; Papyrus arrays are references, so this writes through to FMR's storage
    ; exactly as its own `Storage.BabyAdded[index] = 0.0` does.
    Armor[] kinds = store.BirthBabyRace
    Int n = kinds.Length
    Int taken = 0
    While n > 0
        n -= 1
        If kinds[n] != None
            Int held = mother.GetItemCount(kinds[n])
            If held > 0
                ; Silent. A birth is not a pickpocketing, and the corner
                ; message would fire for a mother on the far side of Skyrim.
                mother.RemoveItem(kinds[n], held, True)
                taken += held
            EndIf
        EndIf
    EndWhile

    ; CLEAR THE CLOCK EVEN IF THE ITEM WAS ALREADY GONE. Without this, the
    ; BabyAdded > 0 gate keeps CheckBabyGrowth running every poll for this
    ; mother forever - a full inventory scan plus a Debug.Trace on every pass,
    ; and an FMR_BabyStatus event every game day advertising a baby that will
    ; never grow. Clearing it is what FMR itself does once a baby resolves, and
    ; CheckInactiveConditions only guards the mother while the baby is younger
    ; than BabyDuration, so this changes nothing that day ten would not.
    added[mi] = 0.0

    Diag(LOG_WARN(), "Took Fertility Mode's baby item from " + \
        mother.GetDisplayName() + " for " + \
        JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".name", "?") + \
        ". This mod owns that childhood now, and FMR will not spawn the child " + \
        "on its own timer. THIS CANNOT BE UNDONE.")
    Return 2
EndFunction

Function CheckBabyItem(Int aiIdx, Int aiStage) Global
    { Confiscates once per child, while the child is still small enough for
      FMR's clock to matter. }
    If !StagesEnabled() || !ConfiscateEnabled()
        Return
    EndIf
    ; Nothing to take from a source that has no baby item, and nothing to
    ; pre-empt in one that runs its own childhood correctly.
    If SourceOwnsGrowth(ChildSource(aiIdx))
        Return
    EndIf
    ; ONLY WHILE IT COULD STILL FIRE. Past infant the child is already older
    ; than any BabyDuration worth setting, so there is nothing left to pre-empt
    ; and no reason to keep looking.
    If aiStage > 1
        Return
    EndIf
    If JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".babyTaken", 0) != 0
        Return
    EndIf
    Int outcome = TakeBabyItem(aiIdx)
    If outcome != 0
        JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".babyTaken", outcome)
        JsonUtil.Save(StoreFile())
    EndIf
EndFunction

Int Function StageForChild(Int aiIdx) Global
    ; The stage this child SHOULD be at, from its birth stamp.
    ;
    ; A manual lock wins outright. Every other record in this store is
    ; correctable by hand and this is no different - a seeded child's "born" is
    ; when it was first RECORDED, not when it was born, so the computed stage
    ; for anyone predating the mod is a guess and needs an override available.
    Int lock = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".stageLock", -1)
    If lock >= 0
        Return lock
    EndIf
    ; AGING RUNS FROM stageBase AT stageFloor, NOT FROM born AT NEWBORN.
    ;
    ; born is when the record was CREATED, which for every child that predates
    ; this mod is the moment it was first seen. Measured on the development
    ; save: all thirty-three children computed as newborn or infant, including
    ; one who is a grown adult and has followed the player. The birth stamp was
    ; not missing, it was confidently wrong, so no default could catch it.
    ;
    ; So a child can be planted at a stage and age onward from there. Seeded
    ; children get planted once, at a stage the player chooses; children born
    ; while this mod is watching fall through to born at newborn, which is
    ; genuinely true for them.
    Float base = JsonUtil.GetFloatValue(StoreFile(), "child." + aiIdx + ".stageBase", 0.0)
    Int floorStage = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".stageFloor", 0)
    If base <= 0.0
        base = JsonUtil.GetFloatValue(StoreFile(), "child." + aiIdx + ".born", 0.0)
        floorStage = 0
    EndIf
    If base <= 0.0
        ; No usable stamp at all. Adult, not newborn - failing the other way
        ; hands a grown child an infant's persona on a missing float, and that
        ; renders in their own bio as fact.
        Return STAGE_ADULT()
    EndIf
    Float age = Utility.GetCurrentGameTime() - base
    If age < 0.0
        ; Dated after the current save point - a rewind. The timeline check owns
        ; that decision; here it just means no time has passed yet.
        Return floorStage
    EndIf
    Float elapsed = 0.0
    Int s = floorStage
    While s < STAGE_ADULT()
        elapsed += StageDurationDays(s)
        If age < elapsed
            Return s
        EndIf
        s += 1
    EndWhile
    Return STAGE_ADULT()
EndFunction

Function PlantStage(Int aiIdx, Int aiStage) Global
    ; Places a child at a stage NOW and lets it age on from there. This is what
    ; a seeded child needs and what the panel will call to correct one by hand:
    ; not a lock, because a locked child never grows up, which is the wrong
    ; answer in a mod about children growing up.
    If aiIdx < 0 || aiStage < 0 || aiStage > STAGE_ADULT()
        Return
    EndIf
    JsonUtil.SetFloatValue(StoreFile(), "child." + aiIdx + ".stageBase", \
        Utility.GetCurrentGameTime())
    JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".stageFloor", aiStage)
    JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".stage", aiStage)
    JsonUtil.Save(StoreFile())
EndFunction

Function RefreshChildStage(Int aiIdx, Actor akKid) Global
    ; Advances the stored stage if it has moved on, and publishes both keys.
    ; akKid may be None - a child with no actor still ages in the record.
    If !StagesEnabled()
        ; STILL VISIT THE SIZE. Turning stages off must undo the size they
        ; applied, and this early return is the path that runs when it happens -
        ; skip it and every scaled child stays shrunk forever, changed by a
        ; setting that is no longer on. ApplyStageScale reads one value and
        ; returns immediately for a child it never touched.
        ApplyStageScale(aiIdx, akKid, STAGE_ADULT())
        Return
    EndIf
    Int have = JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".stage", -1)

    ; FIRST CONTACT WITH A CHILD THAT PREDATES THE FEATURE: plant it, do not
    ; compute it. Its birth stamp is when the record was made, so computing
    ; would declare a grown child a newborn - the exact failure the development
    ; save produced across the whole roster.
    ;
    ; A child born while stages were already running has a real birth stamp and
    ; a stageBase is unnecessary; it falls through to born at newborn, which is
    ; true. So the test is whether the record predates the moment stages were
    ; switched on, not whether it predates the mod.
    If have < 0 && JsonUtil.GetFloatValue(StoreFile(), "child." + aiIdx + ".stageBase", 0.0) <= 0.0
        Float since = JsonUtil.GetFloatValue(StoreFile(), "stagesEnabledAt", 0.0)
        If since <= 0.0
            since = Utility.GetCurrentGameTime()
            JsonUtil.SetFloatValue(StoreFile(), "stagesEnabledAt", since)
            JsonUtil.Save(StoreFile())
        EndIf
        ; PLANT ONLY WHAT THE SEEDING PASS INVENTED. A child recorded from a
        ; real birth has a real birth stamp and should be computed from it -
        ; measured on the development save, twenty-three children share one
        ; timestamp to the hundredth of a day while every later record has its
        ; own, so the seeding batch is exactly separable. Planting the lot would
        ; declare a child born an hour ago a school-age child.
        ;
        ; seedAt is only written from this version on. An older store has none,
        ; and then the fallback is the previous rule: anything predating the
        ; moment stages were switched on gets planted.
        Float seededAt = JsonUtil.GetFloatValue(StoreFile(), "seedAt", 0.0)
        Float cutoff = since
        If seededAt > 0.0
            ; A WINDOW, NOT AN INSTANT, and both halves of that matter.
            ;
            ; SeedPass runs EARLIER IN THE SWEEP than NoteNewChildren, so seedAt
            ; is stamped before the children it seeds are recorded - a bare
            ; `born <= seedAt` would catch none of them. And the batch itself is
            ; not instantaneous: on the development save twenty-three records
            ; span 163.1332 to 163.1340, written across successive frames.
            ;
            ; 0.05 game days is about seventy game minutes. Comfortably wider
            ; than a sweep, and far narrower than the gap to the first real
            ; birth after it, which was 1.39 days. A genuine birth inside that
            ; window would be planted rather than computed - correctable, and
            ; rarer than the failure it prevents.
            cutoff = seededAt + 0.05
        EndIf
        If JsonUtil.GetFloatValue(StoreFile(), "child." + aiIdx + ".born", 0.0) <= cutoff
            ; ENROL FROM EVIDENCE WHERE THERE IS ANY. Actor.IsChild is native
            ; and settles the only question the engine can actually answer:
            ; Skyrim has one child body and one adult body, so a spawned child
            ; is visibly a child and a grown one is visibly not. That is enough
            ; to stop a summoned, grown, once-following child being enrolled as
            ; a toddler, which is the mistake that would actually be noticed.
            ;
            ; It cannot separate toddler from adolescent - nothing can, there is
            ; no body for either - so a child-bodied actor falls to the
            ; configured stage and the panel corrects the rest. Children with no
            ; actor at all get the same default: unknowable, and it matters
            ; least, because nothing renders a persona for them.
            Int planted = SkyrimNetApi.GetConfigInt(CFG(), "kinStageBackfill", 3)
            ; THE BODY FIRST WHEN IT CAN ANSWER, then the binding. Same order
            ; and the same reasoning as the grown check further down - direct
            ; evidence outranks a proxy, and a proxy that contradicts what the
            ; player can see is simply wrong.
            ;
            ; The binding still matters, because IsChild reads the race off the
            ; actor's 3D and an unloaded actor answers False - indistinguishable
            ; from grown. So when there is no body to read:
            ;
            ; SpawnedChildActorRefs is declared "1:1 with AdultChildren indices"
            ; and written in exactly one place, SummonAdultChild, which takes
            ; its base from Storage.AdultChildren. An actor in that array is a
            ; child who went away for training and came back grown - so
            ; SNKin_Bound meant precisely "summoned adult", until this mod began
            ; spawning children of its own. SNKin_OurSpawn separates the two.
            If akKid != None && akKid.Is3DLoaded()
                If !akKid.IsChild()
                    planted = STAGE_ADULT()
                EndIf
            ElseIf akKid != None && StorageUtil.GetIntValue(akKid, "SNKin_Bound", 0) == 1 \
                    && StorageUtil.GetIntValue(akKid, "SNKin_OurSpawn", 0) != 1 \
                    && JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".ourSpawn", 0) != 1
                planted = STAGE_ADULT()
            EndIf
            PlantStage(aiIdx, planted)
            Diag(LOG_WARN(), JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".name", "?") + \
                " predates life stages - planted as " + StageName(planted) + \
                ". Correct it in the panel if that is wrong; their recorded birth " + \
                "date is when this mod first saw them, not when they were born.")
        EndIf
    EndIf

    Int want = StageForChild(aiIdx)

    ; NEVER CLAIM A STAGE THE VISIBLE BODY CONTRADICTS.
    ;
    ; Fertility Mode spawns a child-bodied actor at its own BabyDuration, which
    ; is ten game days by default - shorter than newborn plus infant here. So a
    ; child who is visibly walking around would be recorded as an infant for a
    ; further week, and that renders in their own bio as fact while the player
    ; is looking straight at them.
    ;
    ; A newborn is a carried item, not a body. So the moment there IS a
    ; child-bodied actor the child is at least a toddler, and an adult-bodied
    ; one is an adult whatever the arithmetic says. The clock governs the stages
    ; the engine cannot show; the body wins wherever it can.
    ; EVIDENCE BEATS THE CLOCK, in the order it can be trusted.
    Bool grown = False
    ; THE OWNING MOD'S VERDICT OUTRANKS EVERY OTHER SIGNAL. Beeing Female
    ; stamps FW.Child.GrownUp when it swaps a child for an adult, and it is the
    ; authority on a childhood it is running - our arithmetic is a guess about
    ; a clock we do not control.
    If akKid != None && SourceOwnsGrowth(ChildSource(aiIdx)) && \
            StorageUtil.GetIntValue(akKid, "FW.Child.GrownUp", 0) == 1
        grown = True
    ; THE BODY FIRST, WHENEVER IT CAN ANSWER. It is direct evidence; every flag
    ; below it is a proxy, and a proxy that contradicts what the player is
    ; looking at is simply wrong.
    ;
    ; This used to be the other way round, and the reordering is the fix for a
    ; real failure: a manual stage correction would not stick. Setting a child
    ; back from Adult in the panel wrote the record correctly, then the very
    ; next sweep read SNKin_Bound, concluded "summoned adult", and planted them
    ; at adult again - so the panel appeared to revert its own edit.
    ElseIf akKid != None && akKid.Is3DLoaded()
        If !akKid.IsChild()
            grown = True
        ElseIf want < 2
            ; A newborn is a carried item, not a body. Once there is a
            ; child-bodied actor the child is at least a toddler.
            want = 2
        EndIf
    ; ONLY WHEN THERE IS NO BODY TO READ. IsChild answers False for an unloaded
    ; actor, which is indistinguishable from grown, so this is the fallback that
    ; stops a child being aged permanently for standing in another cell.
    ;
    ; SNKin_Bound MEANT "summoned adult" ONLY WHILE FERTILITY MODE WAS THE ONLY
    ; THING THAT COULD BIND ONE. That stopped being true the moment this mod
    ; started spawning children itself - SpawnOwnedChild calls BindChildRef - so
    ; SNKin_OurSpawn marks the ones WE placed. Bound and grown are no longer the
    ; same question.
    ElseIf akKid != None && StorageUtil.GetIntValue(akKid, "SNKin_Bound", 0) == 1 \
            && StorageUtil.GetIntValue(akKid, "SNKin_OurSpawn", 0) != 1 \
            && JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".ourSpawn", 0) != 1 \
            && JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".manualStage", 0) != 1
        grown = True
    EndIf
    If grown
        want = STAGE_ADULT()
        ; MAKE IT STICK. Without this the clock keeps computing a younger stage
        ; from the birth stamp, the evidence keeps overriding it, and the store
        ; is rewritten every single sweep. Planting moves the floor so the two
        ; agree from now on.
        If JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".stageFloor", 0) != STAGE_ADULT()
            PlantStage(aiIdx, STAGE_ADULT())
        EndIf
    EndIf
    ; A BODY AT THE FIRST STAGE THAT WARRANTS ONE.
    ;
    ; Only for a birth this mod CLAIMED - `owned` is absent on every record
    ; that predates the feature, so nothing already on the roster suddenly
    ; sprouts an actor. And only once: refId is set on success, spawnFailed on
    ; an unsupported race, and either stops this retrying every sweep.
    If want >= 2 && akKid == None \
            && JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".owned", 0) == 1 \
            && JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".refId", 0) == 0 \
            && JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".spawnFailed", 0) == 0 \
            && JsonUtil.GetIntValue(StoreFile(), "child." + aiIdx + ".needsName", 0) == 0
        akKid = SpawnOwnedChild(aiIdx)
    EndIf

    If want != have
        JsonUtil.SetIntValue(StoreFile(), "child." + aiIdx + ".stage", want)
        JsonUtil.SetFloatValue(StoreFile(), "child." + aiIdx + ".stageAt", \
            Utility.GetCurrentGameTime())
        JsonUtil.Save(StoreFile())
        ; Only announce a genuine advance. have == -1 is the first sweep after
        ; the feature is switched on, when every child gets a stage at once -
        ; that is a backfill, not thirty-three children growing up tonight.
        If have >= 0
            Diag(LOG_INFO(), JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".name", "?") + \
                " is now " + StageName(want) + " (was " + StageName(have) + ").")
        EndIf
    EndIf
    ; NOT INSIDE THE akKid GUARD BELOW. The actor that matters here is the
    ; MOTHER's, not the child's - a newborn has no actor by definition, so
    ; gating this on one would mean never confiscating anything.
    CheckBabyItem(aiIdx, want)

    If akKid != None
        StorageUtil.SetIntValue(akKid, "SNKin_ChildStage", want)
        StorageUtil.SetIntValue(akKid, "SNKin_ChildPlasticity", PlasticityFor(want))
        ; AFTER the evidence has settled, never before. `want` at this point has
        ; already been overridden by a bound adult or a loaded body, so a child
        ; FMR summoned grown is sized as an adult rather than as whatever the
        ; birth-stamp arithmetic would have claimed.
        ;
        ; The archetype collision that makes SpawnedChildActorRefs unreliable -
        ; two children of one class, race and gender sharing ONE actor - cannot
        ; bite here, because that array holds summoned ADULTS and every adult
        ; resolves to 1.0. Two children sharing a reference would agree.
        ApplyStageScale(aiIdx, akKid, want)
    EndIf
EndFunction

Int Function PersonIdByName(String asName) Global
    { The single remembered person with this display name, or 0.

      RETURNS 0 FOR AMBIGUITY AS WELL AS FOR ABSENCE, deliberately. Two people
      sharing a display name cannot be told apart by it, and guessing would
      write a permanent parent link off a coin flip - the same rule that makes
      a tied birth record a shortlist instead of a mother. }
    Int n = JsonUtil.IntListCount(StoreFile(), "people.ids")
    Int hit = 0
    Int found = 0
    Int i = 0
    While i < n
        Int id = JsonUtil.IntListGet(StoreFile(), "people.ids", i)
        ; Papyrus string comparison is case-insensitive, which is what we want
        ; for a display name.
        If JsonUtil.GetStringValue(StoreFile(), "person." + id + ".name", "") == asName
            found += 1
            hit = id
        EndIf
        i += 1
    EndWhile
    If found == 1
        Return hit
    EndIf
    Return 0
EndFunction

Function RepairParentIds()
    { Fills in a parent's FormID wherever only their NAME was ever recorded.

      RUNS AUTOMATICALLY, every sweep, rather than waiting to be invoked. A
      repair that needs someone to notice the problem and call a function is not
      a repair - and this one was invisible: 33 of 33 children named a father
      and exactly 1 was linked to him. The name renders fine in the child's own
      bio, so nothing looked wrong, while the reverse index that lets a PARENT
      speak about their children was almost entirely empty.

      Self-limiting: it only touches slots where the id is 0 and a name exists,
      so once a record is whole this does nothing to it ever again.

      Resolution is by name against our own roster, and FAILS CLOSED on
      ambiguity - see PersonIdByName. A father recorded as a name we cannot
      resolve to exactly one person is left alone for the editor to settle. }
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int repaired = 0
    Int i = 0
    While i < n
        repaired += RepairSlot(i, 0)
        repaired += RepairSlot(i, 1)
        i += 1
    EndWhile
    If repaired > 0
        JsonUtil.Save(StoreFile())
        Diag(LOG_INFO(), "Linked " + repaired + " parent(s) that were recorded by name only.")
    EndIf
EndFunction

Int Function RepairSlot(Int aiIdx, Int aiIsFather) Global
    { One parent slot of one child. Returns 1 if it was linked, 0 otherwise. }
    String idField = "child." + aiIdx + ".motherId"
    String nameField = "child." + aiIdx + ".mother"
    If aiIsFather == 1
        idField = "child." + aiIdx + ".fatherId"
        nameField = "child." + aiIdx + ".father"
    EndIf
    If JsonUtil.GetIntValue(StoreFile(), idField, 0) != 0
        Return 0
    EndIf
    String nm = JsonUtil.GetStringValue(StoreFile(), nameField, "")
    If nm == ""
        Return 0
    EndIf
    Int id = PersonIdByName(nm)
    If id == 0
        Return 0
    EndIf
    JsonUtil.SetIntValue(StoreFile(), idField, id)
    JsonUtil.IntListAdd(StoreFile(), ParentPath(id), aiIdx, False)
    Return 1
EndFunction

Int Function RepairFatherIds()
    { Backfills fatherId on records that already have a father NAME but no ID,
      and builds the reverse index that was missing with it.

      Every child recorded before this fix has fatherId 0, so the father can be
      named in the child's bio and can never be asked about his own children.
      Returns how many were repaired.

      ONLY acts where the stored name is the PLAYER'S. That is not a guess -
      it writes the FormID of the person already recorded by name, nothing
      more. An NPC father named in the store cannot be repaired this way,
      because a display name does not identify a reference; those need the
      in-game picker, which resolves an actual actor. }
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Actor player = Game.GetPlayer()
    String playerName = player.GetDisplayName()
    Int playerId = player.GetFormID()
    Int fixed = 0
    Int skipped = 0
    Int i = 0
    While i < n
        If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".fatherId", 0) == 0
            String f = JsonUtil.GetStringValue(StoreFile(), "child." + i + ".father", "")
            If f != "" && f == playerName
                ; Never claim the player fathered a child he is recorded as
                ; having BORNE - the female-player case.
                If JsonUtil.GetIntValue(StoreFile(), "child." + i + ".motherId", 0) != playerId
                    JsonUtil.SetIntValue(StoreFile(), "child." + i + ".fatherId", playerId)
                    JsonUtil.IntListAdd(StoreFile(), ParentPath(playerId), i, False)
                    fixed += 1
                EndIf
            ElseIf f != ""
                skipped += 1
            EndIf
        EndIf
        i += 1
    EndWhile
    JsonUtil.Save(StoreFile())
    Diag(LOG_INFO(), "RepairFatherIds: filled " + fixed + " father ID(s); " + skipped + \
        " named an NPC and need the in-game picker to resolve a reference.")
    Return fixed
EndFunction

Function DumpMothers()
    { Logs every tracked actor with the two timestamps that decide parentage,
      so a mis-assignment can be reasoned about from real numbers.

      Exists because RecoverMotherByRecentBirth got Marcia wrong. It matched
      LastBirth against NOW, but a child NAMED now was BORN BabyDuration days
      ago - FMR gives the mother a baby item at labor and only creates the named
      child record once it matures. Matching "who gave birth recently" to "who
      was just named" compares opposite ends of a ten-day pipeline.

      LastBirth is the labor stamp and survives maturation. BabyAdded is the
      time the baby item was granted and is zeroed when the child is named. So
      a mother still carrying shows BabyAdded > 0, and the mother of a
      just-named child shows BabyAdded == 0 with LastBirth roughly
      BabyDuration days back. That is the comparison to make. }
    If _store == None
        Diag(LOG_ERROR(), "DumpMothers: FMR storage unavailable.")
        Return
    EndIf
    Form[] tracked = _store.TrackedActors
    Float[] births = _store.LastBirth
    Float[] babies = _store.BabyAdded
    Float[] conception = _store.LastConception
    If tracked == None || births == None || babies == None
        Return
    EndIf
    Float now = Utility.GetCurrentGameTime()
    Float dur = BabyDurationDays()
    String durText = "UNKNOWN (could not read the global)"
    If dur > 0.0
        durText = dur + " days"
    EndIf
    Diag(LOG_INFO(), "--- tracked actors at game time " + now + \
        " | BabyDuration " + durText + " | FMR poll " + FmrPollHours() + "h" + \
        " | our poll " + PollHours() + "h ---")
    Int shown = 0
    Int i = 0
    While i < tracked.Length
        Actor a = tracked[i] as Actor
        If a != None && i < births.Length && i < babies.Length
            Float lb = births[i]
            Float ba = babies[i]
            Float lc = 0.0
            If conception != None && i < conception.Length
                lc = conception[i]
            EndIf
            ; Only the ones with any reproductive history - a full 256-row dump
            ; is unreadable and most rows are empty.
            If lb > 0.0 || ba > 0.0 || lc > 0.0
                ; When a carried baby is due to be named, so an upcoming
                ; collision between two mothers can be SEEN rather than
                ; discovered after the fact.
                String due = ""
                If ba > 0.0 && dur > 0.0
                    due = " | matures in " + ((ba + dur) - now) + "d"
                ElseIf ba > 0.0
                    due = " | carrying, maturity unknown"
                EndIf
                Diag(LOG_INFO(), "  " + a.GetDisplayName() + \
                    " | lastBirth=" + lb + " (" + (now - lb) + "d ago)" + \
                    " | babyAdded=" + ba + \
                    " | conceived=" + lc + \
                    " | father=" + FatherNameAt(i) + due)
                shown += 1
            EndIf
        EndIf
        i += 1
    EndWhile
    Diag(LOG_INFO(), "--- " + shown + " with history; babyAdded>0 means still carrying ---")
EndFunction

Bool Function ClearParent(String asChildName, Int aiIsFather)
    { Instance entry point for the web API. The work is in ClearParentStatic. }
    Return ClearParentStatic(asChildName, aiIsFather)
EndFunction

Bool Function ClearParentStatic(String asChildName, Int aiIsFather) Global
    { Undoes a parent link, including its reverse index.

      Needed because a WRONG parent is worse than a blank one and there was no
      way to take one back.

      GLOBAL for the same reason SetParentStatic is: neither SNKin_Picker nor
      the SKSE Menu Framework panel holds a quest reference, and
      DispatchStaticCall - the only way a C++ plugin can reach Papyrus without
      hardcoding our own plugin filename - can invoke Globals and nothing else. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "ClearParent: no child named '" + asChildName + "'.")
        Return False
    EndIf
    String idField = "child." + idx + ".motherId"
    String nameField = "child." + idx + ".mother"
    If aiIsFather == 1
        idField = "child." + idx + ".fatherId"
        nameField = "child." + idx + ".father"
    EndIf
    Int oldId = JsonUtil.GetIntValue(StoreFile(), idField, 0)
    If oldId != 0
        JsonUtil.IntListRemove(StoreFile(), ParentPath(oldId), idx, True)
    EndIf
    JsonUtil.SetStringValue(StoreFile(), nameField, "")
    JsonUtil.SetIntValue(StoreFile(), idField, 0)
    JsonUtil.Save(StoreFile())
    ; The sweep walks the roster and so never visits a parent who has just lost
    ; their last child. This is the only point that still knows who they were.
    RefreshParentCount(oldId)
    Diag(LOG_INFO(), "ClearParent: " + asChildName + " no longer has a recorded " + \
        "mother/father (role " + aiIsFather + ").")
    Return True
EndFunction

Bool Function ReopenCandidates(String asChildName, Float afTolerance)
    { Instance entry point. See ReopenCandidatesStatic. }
    Return ReopenCandidatesStatic(asChildName, afTolerance)
EndFunction

Bool Function ReopenCandidatesStatic(String asChildName, Float afTolerance) Global
    { Rebuilds a child's shortlist EVEN IF a mother is already recorded.

      For "I picked the wrong one". ResolveByBirthSignature deliberately
      refuses when a mother exists, because its job is to fill a gap rather
      than overrule a decision - but that leaves no way back from a misclick
      once the shortlist has been consumed, which is exactly what happened to
      Yrsa.

      Does NOT change the recorded mother. It only restores the choices, so the
      panel can offer them again. The correction itself is still a deliberate
      act by the player.

      Time-limited in the same way as everything else here: it reads FMR's live
      arrays, and once a mother is pruned from tracking or conceives again there
      is nothing left to rebuild from. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "ReopenCandidates: no child named '" + asChildName + "'.")
        Return False
    EndIf
    _JSW_BB_Storage store = ResolveStorage()
    If store == None
        Return False
    EndIf

    Form[] matured = MothersMaturedStatic(store, afTolerance)
    If matured.Length == 0
        Diag(LOG_WARN(), "ReopenCandidates: nobody still matches the maturation window " + \
            "for " + asChildName + " - the evidence has aged out.")
        Return False
    EndIf

    JsonUtil.IntListClear(StoreFile(), "child." + idx + ".candidates")
    JsonUtil.StringListClear(StoreFile(), "child." + idx + ".candidateNames")
    Int i = 0
    While i < matured.Length
        Actor c = matured[i] as Actor
        If c != None
            JsonUtil.IntListAdd(StoreFile(), "child." + idx + ".candidates", c.GetFormID(), True)
            JsonUtil.StringListAdd(StoreFile(), "child." + idx + ".candidateNames", c.GetDisplayName(), True)
        EndIf
        i += 1
    EndWhile
    JsonUtil.Save(StoreFile())
    Diag(LOG_INFO(), "ReopenCandidates: " + asChildName + " again offers " + \
        matured.Length + " candidate mother(s).")
    Return True
EndFunction

Form[] Function MothersMaturedStatic(_JSW_BB_Storage akStore, Float afTolerance) Global
    { Global twin of MothersMaturedRecently, so the Global correction paths can
      use the same test as the live one rather than a second copy of it. }
    Form[] hits = new Form[8]
    Int n = 0
    Float dur = BabyDurationDays()
    If akStore == None || dur <= 0.0
        Return Utility.ResizeFormArray(hits, 0)
    EndIf
    Form[] tracked = akStore.TrackedActors
    Float[] births = akStore.LastBirth
    Float[] babies = akStore.BabyAdded
    If tracked == None || births == None || babies == None
        Return Utility.ResizeFormArray(hits, 0)
    EndIf
    Float now = Utility.GetCurrentGameTime()
    Int i = 0
    While i < tracked.Length && n < 8
        Actor a = tracked[i] as Actor
        If a != None && i < births.Length && i < babies.Length
            If babies[i] == 0.0 && births[i] > 0.0
                Float ago = now - births[i]
                If ago >= (dur - afTolerance) && ago <= (dur + afTolerance)
                    hits[n] = a
                    n += 1
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    Return Utility.ResizeFormArray(hits, n)
EndFunction

Bool Function ResolveByBirthSignature(String asChildName, Float afTolerance)
    { Retro-fits the maturation signature onto a child ALREADY recorded without
      a mother.

      Same test RecordChild now applies, applied after the fact: one match is
      assigned, several are written as a candidate list to be settled in game,
      none means the evidence has aged out.

      Time-limited by nature. It reads FMR's live arrays, and a mother who
      conceives again has lastBirth reset to 0 - so the window closes quietly
      and without warning. Runa and Marcia were already past it. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "ResolveByBirthSignature: no child named '" + asChildName + "'.")
        Return False
    EndIf
    If JsonUtil.GetIntValue(StoreFile(), "child." + idx + ".motherId", 0) != 0
        Diag(LOG_WARN(), "ResolveByBirthSignature: " + asChildName + " already has a mother.")
        Return False
    EndIf

    Form[] matured = MothersMaturedRecently(afTolerance)
    If matured.Length == 0
        Diag(LOG_WARN(), "ResolveByBirthSignature: nobody matured within " + afTolerance + \
            " days of the expected term - the evidence has aged out.")
        Return False
    EndIf
    If matured.Length == 1
        Actor only = matured[0] as Actor
        Diag(LOG_INFO(), "ResolveByBirthSignature: " + only.GetDisplayName() + \
            " is the only match for " + asChildName + ".")
        Return SetParentStatic(asChildName, only, 0)
    EndIf

    ; Several: write the shortlist rather than guess, exactly as the live path
    ; would have done had it been watching.
    JsonUtil.IntListClear(StoreFile(), "child." + idx + ".candidates")
    JsonUtil.StringListClear(StoreFile(), "child." + idx + ".candidateNames")
    Int i = 0
    While i < matured.Length
        Actor c = matured[i] as Actor
        If c != None
            JsonUtil.IntListAdd(StoreFile(), "child." + idx + ".candidates", c.GetFormID(), True)
            JsonUtil.StringListAdd(StoreFile(), "child." + idx + ".candidateNames", c.GetDisplayName(), True)
        EndIf
        i += 1
    EndWhile
    JsonUtil.Save(StoreFile())
    Diag(LOG_INFO(), "ResolveByBirthSignature: " + asChildName + " now has " + \
        matured.Length + " candidate mothers - settle it from the in-game menu.")
    Return True
EndFunction

Bool Function RecoverMother(String asChildName, Float afTolerance)
    { Recovery that works WITHOUT the caller knowing anything about the
      installed configuration.

      Reads BabyDuration live and searches the window that far back, because a
      child named now went into a baby item exactly that long ago. This is the
      one recovery entry point a released mod should expose - the others make
      the caller supply a number they have no way to know, and getting it wrong
      produces a confident wrong answer rather than a failure.

      afTolerance is slack in game days either side; a day is usually right,
      since the only imprecision is the poll interval. }
    Float dur = BabyDurationDays()
    If dur <= 0.0
        Diag(LOG_ERROR(), "RecoverMother: could not read BabyDuration from Fertility Mode, " + \
            "so the birth-to-naming gap is unknown. Use RecoverMotherByBirthAge with an " + \
            "explicit number, or assign her in game.")
        Return False
    EndIf
    Diag(LOG_INFO(), "RecoverMother: BabyDuration is " + dur + " days; searching that far back.")
    Return RecoverMotherByBirthAge(asChildName, dur, afTolerance)
EndFunction

Bool Function RecoverMotherByBirthAge(String asChildName, Float afDaysAgo, Float afTolerance)
    { Recovery that accounts for the ten-day gap between birth and naming.

      USE THIS, NOT RecoverMotherByRecentBirth. That one searches around NOW,
      which is wrong by exactly BabyDuration and produced a confidently wrong
      answer for Marcia: it matched Sapphire, who had gone into labour hours
      earlier, to a child whose own labour was ten days back. Both facts were
      true and the pairing was nonsense.

      afDaysAgo should be BabyDuration - the gap between a mother receiving the
      baby item and the child being named - and afTolerance the slack around
      it. Read the real numbers off DumpMothers first rather than assuming.

      Same fail-closed rule as everywhere else: exactly one candidate in the
      window, or nothing is written. }
    Return RecoverMotherInWindow(asChildName, afDaysAgo - afTolerance, afDaysAgo + afTolerance)
EndFunction

Bool Function RecoverMotherByRecentBirth(String asChildName, Float afWithinDays)
    { DEPRECATED - compares the wrong end of the pipeline. Kept only so older
      callers do not silently vanish; it now warns and delegates.

      A child NAMED now was BORN BabyDuration days ago, so "who gave birth
      within the last day" is not the same question as "who bore this child",
      and on this save it gave a wrong answer that looked authoritative. }
    Diag(LOG_WARN(), "RecoverMotherByRecentBirth searches around NOW and ignores the " + \
        "birth-to-naming gap - it can pair a child with a mother who is still carrying. " + \
        "Prefer RecoverMotherByBirthAge. Proceeding anyway.")
    Return RecoverMotherInWindow(asChildName, 0.0, afWithinDays)
EndFunction

Bool Function RecoverMotherInWindow(String asChildName, Float afMinDaysAgo, Float afMaxDaysAgo)
    { Finds the one tracked actor whose labour falls inside a window measured
      backwards from now, and records her as the mother.

      FMR stamps Storage.LastBirth[index] at labour and, unlike LastFather,
      never clears it at maturation - which is what makes any of this
      recoverable at all.

      FAILS CLOSED THE SAME WAY THE LIVE PATH DOES. Only one candidate inside
      the window is accepted; two or more means the evidence does not
      distinguish them and nothing is written. That is the entire reason this
      takes a window rather than just picking the most recent birth - "most
      recent" always returns somebody, and somebody is not evidence.

      Both bounds are in GAME days measured BACKWARDS from now, so a window of
      9 to 11 means "gave birth between nine and eleven days ago". }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "RecoverMother: no child named '" + asChildName + "' on the roster.")
        Return False
    EndIf
    If _store == None
        Return False
    EndIf
    Form[] tracked = _store.TrackedActors
    Float[] births = _store.LastBirth
    If tracked == None || births == None
        Return False
    EndIf

    Float now = Utility.GetCurrentGameTime()
    Actor best = None
    Int found = 0
    Int i = 0
    While i < tracked.Length
        Actor a = tracked[i] as Actor
        If a != None && i < births.Length && births[i] > 0.0
            Float ago = now - births[i]
            If ago >= afMinDaysAgo && ago <= afMaxDaysAgo
                found += 1
                best = a
            EndIf
        EndIf
        i += 1
    EndWhile

    If found == 0
        Diag(LOG_WARN(), "RecoverMother: nobody tracked gave birth between " + \
            afMinDaysAgo + " and " + afMaxDaysAgo + " days ago - wrong window, " + \
            "or she is no longer tracked. Run DumpMothers to see the real numbers.")
        Return False
    EndIf
    If found > 1
        Diag(LOG_WARN(), "RecoverMother: " + found + " mothers gave birth between " + \
            afMinDaysAgo + " and " + afMaxDaysAgo + " days ago. Nothing distinguishes " + \
            "them, so nothing recorded - narrow the window, or assign her in game.")
        Return False
    EndIf
    Diag(LOG_INFO(), "RecoverMother: " + best.GetDisplayName() + " is the only labour " + \
        "between " + afMinDaysAgo + " and " + afMaxDaysAgo + " days ago.")
    Return SetParentStatic(asChildName, best, 0)
EndFunction

Bool Function SetFatherName(String asChildName, String asFatherName)
    { Corrects a father. Exists because the seed pass assumes the player for
      every pre-existing child, and FMR's LoveInterest path can put a child in
      that list whose father is someone else. }
    Int idx = ChildIndex(asChildName)
    If idx < 0
        Diag(LOG_ERROR(), "SetFatherName: no child named '" + asChildName + "' on the roster.")
        Return False
    EndIf
    JsonUtil.SetStringValue(StoreFile(), "child." + idx + ".father", asFatherName)
    JsonUtil.Save(StoreFile())
    Diag(LOG_INFO(), "SetFatherName: " + asChildName + " -> father " + asFatherName + ".")
    Return True
EndFunction

String Function DumpRoster()
    { Read-back for the web API, so the roster can be inspected without a save
      editor. One "index name mother/father" per line. }
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    String out = "children=" + n
    Int i = 0
    While i < n
        out += NL() + i + " " + JsonUtil.StringListGet(StoreFile(), "roster", i) + \
            " mother=" + JsonUtil.GetStringValue(StoreFile(), "child." + i + ".mother", "-") + \
            " father=" + JsonUtil.GetStringValue(StoreFile(), "child." + i + ".father", "-")
        i += 1
    EndWhile
    Return out
EndFunction

; ===========================================================================
; Store
;
; JsonUtil is FILE-backed (Data/SKSE/Plugins/StorageUtilData/), not co-save.
; StorageUtil Ints and Floats survive a save reload; STRINGS DO NOT, which cost
; the Romantasy mod its entire disposition history before it was found. Every
; string in this mod lives in JsonUtil; StorageUtil holds only Ints, Floats and
; Forms. The one StorageUtil string here - SNKin_LiveFather - is deliberately
; session-scoped scratch, mirrored to JsonUtil immediately, and never read as
; the source of truth.
; ===========================================================================

String Function StoreFile() Global
    { The store for THIS PLAYTHROUGH.

      JsonUtil writes one file per INSTALL, not per save, and that leaked: a
      second character - or in practice, this character's own old save loaded
      for five minutes to debug something else - wrote its children into the
      roster the main save reads. Nicollette1 arrived exactly that way.

      The save id lives in StorageUtil, which IS per-save (it rides in the
      co-save), so it is the one piece of state that can tell two playthroughs
      apart. Ints survive a reload; strings do not, which is why the FILENAME is
      derived from an Int rather than stored as one.

      Id 0 means "not yet claimed" and reads the legacy file, so nothing breaks
      in the window before EnsureSaveId runs on the first bootstrap. Id 1 is the
      save that owns the legacy file - see EnsureSaveId. }
    Int id = StorageUtil.GetIntValue(None, "SNKin_SaveId", 0)
    If id <= 1
        Return "SNKin_Parentage"
    EndIf
    Return "SNKin_Parentage_" + id
EndFunction

Function EnsureSaveId()
    { Claims a store for this playthrough, once, automatically.

      THE FIRST SAVE TO RUN THIS INHERITS THE EXISTING DATA. That is deliberate
      and was chosen over asking: on an install that has only ever had one
      character - the overwhelming majority - it is silently correct, and the
      alternative is a confusing question on first launch about a situation the
      player has never encountered.

      Every later save gets its own file and starts empty. The claim is recorded
      INSIDE the legacy file rather than in the co-save, because the question
      "has anyone claimed it" has to be answerable from a save that has never
      seen it. }
    If StorageUtil.GetIntValue(None, "SNKin_SaveId", 0) != 0
        Return
    EndIf

    If JsonUtil.GetIntValue("SNKin_Parentage", "claimedBy", 0) == 0
        StorageUtil.SetIntValue(None, "SNKin_SaveId", 1)
        JsonUtil.SetIntValue("SNKin_Parentage", "claimedBy", 1)
        JsonUtil.Save("SNKin_Parentage")
        Diag(LOG_INFO(), "This save now owns the existing kinship store.")
        Return
    EndIf

    ; Somebody else already owns it. Take a fresh file.
    ;
    ; RandomInt rather than a counter: a counter would have to live somewhere
    ; shared, and anything shared is precisely what this is escaping. A
    ; collision needs two saves to draw the same number out of two billion.
    Int id = Utility.RandomInt(2, 2000000000)
    StorageUtil.SetIntValue(None, "SNKin_SaveId", id)
    Diag(LOG_WARN(), "The existing kinship store belongs to another playthrough. " + \
        "This save starts a new one: SNKin_Parentage_" + id + ".json")
EndFunction

Function WriteStorePointer() Global
    { Tells the optional SKSE panel which file is live.

      The panel is a separate process-side reader with no access to StorageUtil,
      so it cannot derive the name itself. A one-key pointer file is the
      smallest thing that answers the question, and it is rewritten every
      bootstrap so it can never go stale. }
    JsonUtil.SetStringValue("SNKin_Current", "store", StoreFile())
    JsonUtil.Save("SNKin_Current")
EndFunction

Int Function SCHEMA() Global
    { Bumped whenever the on-disk key layout changes. See MigrateStore.

      2 -> 3 made the model PARENT-AGNOSTIC. Before it, a mother had a FormID
      and a reverse index while a father had only a name, so only mothers could
      be asked about their children.

      4 -> 5 folds people-roster duplicates created by load order changes. A
      light plugin's FormID encodes its position in the load order, so adding or
      removing any mod renumbers every ESL-sourced form and the roster filed the
      same follower again - one had four entries, three unselectable. Matched on
      name plus LOCAL id, never the decoded plugin name: the local is arithmetic
      and holds, the plugin name is a lookup a stale index answers wrongly.

      3 -> 4 added life stages. PURELY ADDITIVE, so it needs no migration code:
      stage, stageAt and stageLock are simply absent on an older store, every
      read supplies a default, and the first sweep backfills them from each
      child's birth stamp. MigrateStore falls through both of its branches for
      have == 3 and writes the new number, which is exactly right. }
    ; 5 -> 6 is ADDITIVE and needs no migration, for the same reason 3 -> 4 did
    ; not. source, birthGroup, bfName, uuid, priorRefs and priorUuids are all
    ; simply absent on an older store; every read supplies a default, and
    ; ChildSource in particular defaults to Fertility Mode because every record
    ; written before this existed came from that path.
    Return 6
EndFunction

String Function ParentPath(Int aiFormID) Global
    { Reverse index, one per parent, holding roster indices of their children.

      Replaces the schema 2 "mother.<id>.kids" and is used for BOTH parents.
      Also replaces the SNKin_IsMother StorageUtil flag entirely: the decorator
      now asks whether this list is non-empty instead of reading a flag off the
      actor. That is not a tidy-up - a flag has to be WRITTEN to an actor, and
      an actor who is not loaded cannot be written to, which is the same wall
      that made the web API unable to accept an absent mother. A list keyed by
      FormID in a file on disk has no such requirement. }
    Return "parent." + aiFormID + ".kids"
EndFunction

Int Function ChildIndex(String asName) Global
    { A child's record key is its POSITION IN OUR OWN ROSTER, not anything
      derived from its name. Returns -1 when the name is not on it.

      SCHEMA 1 BUILT THE KEY BY WALKING THE NAME CHARACTER BY CHARACTER -
      uppercase it, then keep only A-Z and 0-9. On the live save that produced
      mangled, lossy keys: Nicollette -> colLETTE, Toryy -> toYY,
      Ragnar -> aa, Rognir -> O, Inga -> A. The letters B, G, I, N, P and R
      were dropped everywhere, position-independently, and the surviving case
      was scrambled.

      The names themselves round-tripped PERFECTLY when passed through
      untouched - child.a.name really was "Inga" - so the corruption was
      entirely in the per-character rebuild. That is consistent with the
      case-insensitive string-table folding this stack is already scarred by,
      but the exact mechanism was never pinned down, and it does not need to
      be: nothing here decomposes a string any more, so there is no longer a
      place for it to happen.

      Indices are stable because we only ever APPEND to our roster. FMR's own
      PlayerChildRemove shifts its arrays, which is exactly why our roster is
      kept separately rather than mirroring its indices. }
    Return JsonUtil.StringListFind(StoreFile(), "roster", asName)
EndFunction

Bool Function HasChild(String asName) Global
    { True if this child is already accounted for - either recorded, or
      deliberately ignored by SeedPass because seeding was off when the mod was
      installed. Both mean "do not record this as a new birth". }
    If ChildIndex(asName) >= 0
        Return True
    EndIf
    Return JsonUtil.StringListFind(StoreFile(), "ignored", asName) >= 0
EndFunction

Function MigrateStore()
    { Brings the store up to the current schema.

      1 -> 2 WIPED, because the schema 1 keys were mangled beyond use and
      everything was regenerable: the child list comes from FMR, fathers are
      re-derived by the seed pass, bindings re-form on the next sweep.

      2 -> 3 MUST NOT WIPE, and the difference matters. By the time this ships,
      mothers have been entered BY HAND - and a hand-entered mother is the one
      thing in this store that cannot be recovered from anywhere. Wiping would
      silently destroy exactly the work the feature exists to make possible.
      So this converts in place. }
    Int have = JsonUtil.GetIntValue(StoreFile(), "schema", 0)
    If have == SCHEMA()
        Return
    EndIf

    ; A LOCK THAT CROSSES SCRIPT INSTANCES, which _sweeping does not.
    ;
    ; _sweeping is a member variable, so it guards one instance against itself
    ; and nothing against anyone else. There is routinely more than one: the
    ; quest OnInit, the alias OnInit and OnPlayerLoadGame all call Bootstrap
    ; with abForce, and orphaned quest instances from an earlier install add
    ; more. Eight concurrent sweeps were observed on the first live run.
    ;
    ; Measured again on the schema 4 -> 5 migration: two passes both read
    ; schema 4 before either wrote 5, and the repair ran twice. That was
    ; harmless only because RepairFormDrift is idempotent by construction - the
    ; migration before it called ClearAll, and two of those interleaving would
    ; have wiped what the other had just rebuilt.
    ;
    ; None-scoped StorageUtil is process-wide, so every instance sees the same
    ; flag. Papyrus has no try/finally, so a holder that dies mid-migration
    ; would deadlock the store forever - hence the staleness escape rather than
    ; a bare boolean.
    Float now = Utility.GetCurrentRealTime()
    Float held = StorageUtil.GetFloatValue(None, "SNKin_MigrateLock", 0.0)
    ; held > now means the value came from a previous session: real time counts
    ; from launch and resets, the same trap the Bootstrap debounce documents.
    If held > 0.0 && held <= now && (now - held) < 30.0
        Return
    EndIf
    StorageUtil.SetFloatValue(None, "SNKin_MigrateLock", now)

    If have < 2
        Diag(LOG_WARN(), "Store schema " + have + " -> " + SCHEMA() + \
            ": keys unusable, rebuilding from Fertility Mode.")
        JsonUtil.ClearAll(StoreFile())
        ClearBindings()
    ElseIf have == 2
        Diag(LOG_WARN(), "Store schema 2 -> 3: converting in place, keeping hand-entered parents.")
        MigrateTwoToThree()
    EndIf

    ; 2, 3 or 4 -> 5: fold roster duplicates a load order change created.
    ;
    ; Runs for any store old enough to have accumulated them, and is safe to run
    ; twice: it only touches entries whose FormID no longer resolves AND that
    ; have a live twin of the same form. Nothing is deleted without somewhere to
    ; point the references.
    If have >= 2 && have < 5
        Diag(LOG_WARN(), "Store schema " + have + " -> 5: checking the people roster for " + \
            "duplicates left by load order changes.")
        RepairFormDrift()
    EndIf

    JsonUtil.SetIntValue(StoreFile(), "schema", SCHEMA())
    JsonUtil.Save(StoreFile())
    ; Released only after the schema is written, so a second instance arriving
    ; now reads the new number and returns on the check above rather than on the
    ; lock. The lock covers the window; the schema covers everything after it.
    StorageUtil.SetFloatValue(None, "SNKin_MigrateLock", 0.0)
EndFunction

Function MigrateTwoToThree()
    { Rebuilds the reverse index under its new, parent-agnostic key.

      Schema 2 held it at "mother.<id>.kids" and only ever for mothers. Every
      child that already has a motherId keeps it - the forward record
      (child.N.mother / .motherId) is unchanged and is read as-is - it just
      gains an entry under ParentPath so the mother can still be asked what she
      bore.

      Fathers are NOT back-filled here. Schema 2 stored no father FormID, so
      there is nothing to convert; they are filled going forward by
      CaptureFatherRef, or by hand. }
    Int n = JsonUtil.StringListCount(StoreFile(), "roster")
    Int moved = 0
    Int i = 0
    While i < n
        Int motherId = JsonUtil.GetIntValue(StoreFile(), "child." + i + ".motherId", 0)
        If motherId != 0
            JsonUtil.IntListAdd(StoreFile(), ParentPath(motherId), i, False)
            ; Drop the old key so a later read cannot find two disagreeing
            ; answers for the same parent.
            JsonUtil.IntListRemove(StoreFile(), "mother." + motherId + ".kids", i, True)
            moved += 1
        EndIf
        i += 1
    EndWhile
    Diag(LOG_INFO(), "Schema 3: carried " + moved + " recorded parent link(s) across.")
EndFunction

Function ClearBindings()
    { Drops SNKin_Bound from every spawned child so BindSpawnedChildren will
      look at them again. }
    If _store == None
        Return
    EndIf
    Actor[] spawned = _store.SpawnedChildActorRefs
    If spawned == None
        Return
    EndIf
    Int i = 0
    While i < spawned.Length
        If spawned[i] != None
            StorageUtil.SetIntValue(spawned[i], "SNKin_Bound", 0)
        EndIf
        i += 1
    EndWhile
EndFunction

Function StoreSetText(Actor akActor, String asField, String asValue) Global
    { Writes AND saves. JsonUtil holds the file in memory until Save() is
      called, so skipping it means the value survives exactly until the game
      exits - the same bug in a different disguise. }
    If akActor == None || asValue == ""
        Return
    EndIf
    JsonUtil.SetStringValue(StoreFile(), "actor." + akActor.GetFormID() + "." + asField, asValue)
    JsonUtil.Save(StoreFile())
EndFunction

String Function StoreGetText(Actor akActor, String asField) Global
    If akActor == None
        Return ""
    EndIf
    Return JsonUtil.GetStringValue(StoreFile(), "actor." + akActor.GetFormID() + "." + asField, "")
EndFunction

; ===========================================================================
; Diagnostics
; ===========================================================================

Function Diag(Int aiLevel, String asText) Global
    If aiLevel > LogLevel()
        Return
    EndIf
    MiscUtil.PrintConsole("[SNKin] " + asText)
    MiscUtil.WriteToFile(DiagPath(), "[" + Utility.GetCurrentGameTime() + "] " + asText + NL(), True, False)
EndFunction
