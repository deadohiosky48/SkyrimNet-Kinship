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
Bool            _sweeping

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

Event OnUpdate()
    { Game-time poll, matched to FMR's own cadence. FMR drives its whole
      simulation from RegisterForSingleUpdateGameTime(PollingInterval), so
      polling faster than it updates cannot find anything sooner and only
      spends Papyrus budget. }
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
    ; Papyrus has no lock primitive; a plain flag is the standard idiom and is
    ; sufficient here because every caller is on the same script instance and
    ; the guarded region contains no waits.
    If _sweeping
        Return
    EndIf
    _sweeping = True

    MigrateStore()
    SeedPass()
    RememberPeople()
    ; AFTER RememberPeople, never before: it resolves names against the roster,
    ; so the roster has to be current or a name that could have been linked this
    ; sweep is left for the next one.
    RepairParentIds()
    NoteDeliveries()
    NoteNewChildren()
    BindSpawnedChildren()
    ; LAST, and it has to be. It publishes what the passes above just decided,
    ; so anything running earlier would export the previous sweep's answer.
    RefreshKinshipExports()

    _sweeping = False
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
                    StorageUtil.SetFloatValue(mother, "SNKin_AwaitingAt", Utility.GetCurrentGameTime())
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
        shortlist = MothersMaturedRecently(1.0)
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
    Int i = 0
    While i < n
        Actor a = StorageUtil.FormListGet(None, "SNKin_Watch", i) as Actor
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
        Return None
    EndIf
    If tied > 0
        ; FAILS CLOSED: no mother is written. The shortlist is NOT built here -
        ; RecordChild derives it from MothersMaturedRecently at the point it is
        ; written. Handing an array back through a member variable is exactly
        ; what silently lost Danica and Nilsine's shortlists: the tie was
        ; detected and logged, and the candidates arrived empty.
        Diag(LOG_WARN(), (tied + 1) + " mothers delivered in the same sweep - nothing " + \
            "distinguishes them, so this child is recorded with a CANDIDATE LIST " + \
            "instead of a mother. Resolve it from the in-game menu.")
        Return None
    EndIf
    If found > 1
        Diag(LOG_INFO(), found + " mothers awaiting; claimed the earliest delivery.")
    EndIf
    StorageUtil.SetIntValue(best, "SNKin_Awaiting", 0)
    WatchRemove(best)
    Return best
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
            ; ONLY TRUST THE BODY WHEN THERE IS ONE LOADED. IsChild reads the
            ; actor's race off its 3D; with the actor unloaded it answers False,
            ; which is indistinguishable from "grown" unless we ask separately.
            ;
            ; The first live run planted two bound, child-bodied daughters as
            ; ADULTS for exactly this reason - they were simply somewhere else
            ; at the time. Reading a false negative as evidence of adulthood is
            ; the fail-dangerous direction: it ages children permanently on the
            ; strength of them being out of the cell.
            If akKid != None && akKid.Is3DLoaded() && !akKid.IsChild()
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
    ; Only while the body is actually loaded - see the note in the plant branch.
    ; An unloaded actor answers IsChild False and would age a child permanently.
    If akKid != None && akKid.Is3DLoaded()
        If !akKid.IsChild()
            want = STAGE_ADULT()
        ElseIf want < 2
            want = 2
        ElseIf want == STAGE_ADULT()
            ; SELF-HEAL A CHILD WRONGLY AGED. A child-bodied actor recorded as
            ; an adult is a contradiction the player can see, and it is the
            ; exact wreckage the unloaded-IsChild bug left behind. Demote to the
            ; configured stage and let the clock carry them forward again.
            Int back = SkyrimNetApi.GetConfigInt(CFG(), "kinStageBackfill", 3)
            If back >= STAGE_ADULT()
                back = 3
            EndIf
            Diag(LOG_WARN(), JsonUtil.GetStringValue(StoreFile(), "child." + aiIdx + ".name", "?") + \
                " is recorded as an adult but has a child's body - correcting to " + \
                StageName(back) + ".")
            PlantStage(aiIdx, back)
            want = back
        EndIf
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
    If akKid != None
        StorageUtil.SetIntValue(akKid, "SNKin_ChildStage", want)
        StorageUtil.SetIntValue(akKid, "SNKin_ChildPlasticity", PlasticityFor(want))
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

      3 -> 4 added life stages. PURELY ADDITIVE, so it needs no migration code:
      stage, stageAt and stageLock are simply absent on an older store, every
      read supplies a default, and the first sweep backfills them from each
      child's birth stamp. MigrateStore falls through both of its branches for
      have == 3 and writes the new number, which is exactly right. }
    Return 4
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

    If have < 2
        Diag(LOG_WARN(), "Store schema " + have + " -> " + SCHEMA() + \
            ": keys unusable, rebuilding from Fertility Mode.")
        JsonUtil.ClearAll(StoreFile())
        ClearBindings()
    ElseIf have == 2
        Diag(LOG_WARN(), "Store schema 2 -> 3: converting in place, keeping hand-entered parents.")
        MigrateTwoToThree()
    EndIf

    JsonUtil.SetIntValue(StoreFile(), "schema", SCHEMA())
    JsonUtil.Save(StoreFile())
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
