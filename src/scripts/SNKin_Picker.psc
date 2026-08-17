Scriptname SNKin_Picker Hidden
{ In-game UI for assigning a parent to a child.

  EVERY DESIGN CHOICE HERE COMES FROM NPC Renamer (_CV_NPCRenamer), which
  solved this exact problem on this exact load order. Its lessons, in the order
  they matter:

  1. DO NOT DEPEND ON AN MCM PAGE RENDERING. SkyUI's mod registry is a Papyrus
     array capped at 128 entries. On a load order sitting at that ceiling a
     menu registers and can never display - and MCM Helper's keybind can then
     never be bound, because binding happens on the page. NPC Renamer works
     around it by registering its key directly in Papyrus, and so do we. The
     MCM page here is a convenience; the hotkey is the product.

  2. UILIB_1 PROVIDES BOTH WIDGETS WE NEED. ShowList gives a scrollable picker
     and ShowTextInput gives a text field, so there is no need for UIExtensions
     headers, MCM_ConfigBase (which lives only inside MCMHelper.bsa), or a
     custom UI. FMR ships UILIB_1.psc, so we compile against a real header
     rather than guessing native signatures.

  3. UILIB_1 MUST BE BORROWED FROM A FORM THAT HAS IT ATTACHED. Casting a Form
     to a script type only succeeds when that script is actually on that form,
     so "(Self as Form) as UILIB_1" is None for us. FMR's handler quest carries
     it - that is how FMR shows its own naming prompt - so we borrow it exactly
     as NPC Renamer does.

  Hidden with Global functions on purpose: nothing here is attached to a form,
  so the whole picker ships as loose scripts and needs no Creation Kit work.
  MCM Helper's keybinds.json can call a Global directly with
  CallGlobalFunction, and SNKin_Bridge forwards its own OnKeyDown here. }

; ===========================================================================
; UI plumbing
; ===========================================================================

UILIB_1 Function Lib() Global
    { The UILIB_1 instance, borrowed from Fertility Mode's handler quest.

      Returns None when FMR is absent, which is also when this whole mod is
      inert, so callers treat None as "say so and stop" rather than as a bug. }
    If Game.GetModByName("Fertility Mode.esm") == 255
        Return None
    EndIf
    Return Game.GetFormFromFile(0x0D62, "Fertility Mode.esm") as UILIB_1
EndFunction

Function Say(String asText) Global
    Debug.Notification("[Kinship] " + asText)
EndFunction

Int Function Pick(String asTitle, String[] asOptions) Global
    { One list prompt. Returns the chosen index, or -1 if cancelled.

      ShowList takes a start index and a default index; both 0 puts the cursor
      on the first row, which is what every caller here wants. }
    ; NOT "ui" - UI is a known Papyrus script (UI.OpenCustomMenu and friends)
    ; and a local of that name fails to compile.
    UILIB_1 provider = Lib()
    If provider == None || asOptions == None || asOptions.Length == 0
        Return -1
    EndIf
    Return provider.ShowList(asTitle, asOptions, 0, 0)
EndFunction

; ===========================================================================
; Entry points
;
; These three are what MCM Helper's keybinds.json and SNKin_Bridge call.
; ===========================================================================

Function OpenMenu() Global
    { The hotkey lands here: one key, then choose what to do.

      A single key rather than three separate binds, because a mod that asks
      the player to remember three scan codes for something they will use a
      handful of times has designed for the author, not the player. }
    Int pending = CountUnresolved()
    Int future = SNKin_Bridge.CountFutureChildren()
    String[] actions = new String[5]
    ; Listed FIRST and with its count, because it is the only entry that is
    ; time-sensitive: an unresolved shortlist is a question the game already
    ; asked and is waiting on.
    actions[0] = "Choose a mother (" + pending + " waiting)"
    actions[1] = "Assign the person under my crosshair"
    actions[2] = "Assign someone tracked by Fertility Mode"
    actions[3] = "Show what is recorded"
    actions[4] = "Records from a later save (" + future + ")"
    Int pick = Pick("Kinship", actions)
    If pick == 0
        ResolveUncertain()
    ElseIf pick == 1
        AssignCrosshairParent()
    ElseIf pick == 2
        AssignRemoteParent()
    ElseIf pick == 3
        ShowRoster()
    ElseIf pick == 4
        ReviewFuture()
    EndIf
EndFunction

Function ReviewFuture() Global
    { The keep-or-delete prompt for records dated after this save point.

      TWO DELIBERATE STEPS, and the second names the consequence in full. This
      is the only destructive action in the mod, and the situation it fires in -
      "I loaded an old save for a minute" - is exactly the one where a hasty
      yes would cost a family that took days of play to build.

      SkyrimNet asks a similar question about its own history, and it would be
      neater to inherit the answer than to ask twice. It exposes no such event,
      so we ask separately and say plainly what OUR yes destroys, because the
      two are not the same thing: theirs is memories, ours is the record of
      which NPCs are whose children. }
    Int n = SNKin_Bridge.CountFutureChildren()
    If n == 0
        Say("Nothing recorded after this point - the timeline looks consistent.")
        Return
    EndIf

    String[] first = new String[2]
    first[0] = "Keep them (I am going back to a later save)"
    first[1] = "Review deleting them"
    If Pick(n + " child record(s) are dated after this save", first) != 1
        Return
    EndIf

    ; Name them, so the choice is made against actual children rather than a
    ; count. UILIB_1 shows one row per line.
    String[] names = StringUtil.Split(SNKin_Bridge.FutureChildNames(), StringUtil.AsChar(10))
    Pick("These would be deleted", names)

    String[] confirm = new String[2]
    confirm[0] = "No, keep them"
    confirm[1] = "Yes - permanently delete these " + n + " record(s)"
    If Pick("This erases who their parents were, for good", confirm) == 1
        Int gone = SNKin_Bridge.ForgetFutureChildren()
        Say(gone + " record(s) deleted.")
    EndIf
EndFunction

Int Function CountUnresolved() Global
    { How many children were recorded with a shortlist instead of a mother. }
    String f = SNKin_Bridge.StoreFile()
    Int n = JsonUtil.StringListCount(f, "roster")
    Int count = 0
    Int i = 0
    While i < n
        If JsonUtil.IntListCount(f, "child." + i + ".candidates") > 0
            count += 1
        EndIf
        i += 1
    EndWhile
    Return count
EndFunction

Function ResolveUncertain() Global
    { Resolves a child whose mother could not be told apart at the time.

      This is the payoff for keeping the shortlist. Two mothers who give birth
      in the same in-game minute mature in the same minute ten days later, so
      the automatic path cannot separate them and refuses to guess - but it
      knows it was one of these two. Choosing between two named women is a
      question the player can actually answer; "which of Skyrim's NPCs bore
      this child" is not. }
    String f = SNKin_Bridge.StoreFile()
    Int n = JsonUtil.StringListCount(f, "roster")

    ; Collect the children still waiting, remembering which roster index each
    ; row maps back to.
    Int[] idxOf = Utility.CreateIntArray(32, -1)
    String[] rows = Utility.CreateStringArray(32, "")
    Int count = 0
    Int i = 0
    While i < n && count < 32
        Int c = JsonUtil.IntListCount(f, "child." + i + ".candidates")
        If c > 0
            idxOf[count] = i
            rows[count] = JsonUtil.StringListGet(f, "roster", i) + "   (" + c + " possible mothers)"
            count += 1
        EndIf
        i += 1
    EndWhile

    If count == 0
        Say("Nothing waiting - every child either has a mother or never had a shortlist.")
        Return
    EndIf

    String[] shown = Utility.CreateStringArray(count, "")
    Int j = 0
    While j < count
        shown[j] = rows[j]
        j += 1
    EndWhile
    Int pickChild = Pick("Which child?", shown)
    If pickChild < 0
        Return
    EndIf
    Int childIdx = idxOf[pickChild]
    String childName = JsonUtil.StringListGet(f, "roster", childIdx)

    ; Offer only that child's shortlist. The names were stored alongside the
    ; FormIDs at record time precisely so this list can be shown without the
    ; candidates being loaded - they are usually nowhere near the player.
    Int nc = JsonUtil.IntListCount(f, "child." + childIdx + ".candidates")
    String[] names = Utility.CreateStringArray(nc, "")
    Int k = 0
    While k < nc
        names[k] = JsonUtil.StringListGet(f, "child." + childIdx + ".candidateNames", k)
        k += 1
    EndWhile
    Int pickMother = Pick("Who bore " + childName + "?", names)
    If pickMother < 0
        Return
    EndIf

    Int formId = JsonUtil.IntListGet(f, "child." + childIdx + ".candidates", pickMother)
    If SNKin_Bridge.SetParentByIdStatic(childName, formId, 0)
        Say(childName + "'s mother is " + names[pickMother] + ".")
    Else
        Say("Could not record that - see snkin.log.")
    EndIf
EndFunction

Function AssignCrosshairParent() Global
    { Point at someone and press the key: they become a parent of a child you
      then choose.

      THE CROSSHAIR IS THE PRIMARY PATH because it needs no candidate list at
      all - the hard part of "which of Skyrim's NPCs is this" is answered by
      the player looking at them. AssignRemoteParent covers the ones you cannot
      walk to. }
    Actor who = Game.GetCurrentCrosshairRef() as Actor
    If who == None
        Say("No actor under the crosshair.")
        Return
    EndIf
    If who == Game.GetPlayer()
        Say("That is you. Point at the other parent.")
        Return
    EndIf
    AssignTo(who)
EndFunction

Function AssignRemoteParent() Global
    { For a parent who is nowhere near you - the common case when filling in
      history. Offers everyone Fertility Mode has tracked, which is the only
      list of plausible parents available without another mod's data. }
    Actor who = PickTrackedActor()
    If who == None
        Return
    EndIf
    AssignTo(who)
EndFunction

Function ShowRoster() Global
    { Read-only: every child and what is recorded for them. Exists because the
      first question anyone asks is "what does it already think?", and until
      now the only answer was a PowerShell call. }
    Int n = JsonUtil.StringListCount(SNKin_Bridge.StoreFile(), "roster")
    If n == 0
        Say("No children recorded yet.")
        Return
    EndIf
    String[] rows = RosterRows(n)
    Pick("Recorded children (" + n + ")", rows)
EndFunction

; ===========================================================================
; The flow
; ===========================================================================

Function AssignTo(Actor akParent) Global
    { Shared tail of both entry points: choose the child, choose the role,
      confirm, write. }
    Int n = JsonUtil.StringListCount(SNKin_Bridge.StoreFile(), "roster")
    If n == 0
        Say("No children recorded yet - nothing to assign.")
        Return
    EndIf

    Int childIdx = PickChild(akParent.GetDisplayName(), n)
    If childIdx < 0
        Return
    EndIf
    String childName = JsonUtil.StringListGet(SNKin_Bridge.StoreFile(), "roster", childIdx)

    Int isFather = PickRole(akParent, childName)
    If isFather < 0
        Return
    EndIf

    ; Confirm before writing. A wrong parent is permanent and renders in the
    ; child's own bio as established fact - the same asymmetry that makes the
    ; automatic path fail closed rather than guess.
    String role = "mother"
    If isFather == 1
        role = "father"
    EndIf
    String[] yesNo = new String[2]
    yesNo[0] = "Yes - record it"
    yesNo[1] = "No - cancel"
    If Pick(akParent.GetDisplayName() + " is " + childName + "'s " + role + "?", yesNo) != 0
        Return
    EndIf

    If SNKin_Bridge.SetParentStatic(childName, akParent, isFather)
        Say(childName + "'s " + role + " is now " + akParent.GetDisplayName() + ".")
    Else
        Say("Could not record that - see snkin.log.")
    EndIf
EndFunction

Int Function PickChild(String asParentName, Int aiCount) Global
    { Lists every child WITH what is already recorded, so the player can see at
      a glance which ones still need a parent rather than picking blind. }
    Return Pick("Which child is " + asParentName + " a parent of?", RosterRows(aiCount))
EndFunction

String[] Function RosterRows(Int aiCount) Global
    { One row per child: name, then mother and father or a dash.

      Deliberately shows BOTH parents even when only one is being set - seeing
      "Toryy   mother: - / father: Haruk" is what tells you the entry is half
      done. }
    String f = SNKin_Bridge.StoreFile()
    String[] rows = Utility.CreateStringArray(aiCount, "")
    Int i = 0
    While i < aiCount
        String m = JsonUtil.GetStringValue(f, "child." + i + ".mother", "")
        String d = JsonUtil.GetStringValue(f, "child." + i + ".father", "")
        If m == ""
            m = "-"
        EndIf
        If d == ""
            d = "-"
        EndIf
        rows[i] = JsonUtil.StringListGet(f, "roster", i) + "   (mother: " + m + " / father: " + d + ")"
        i += 1
    EndWhile
    Return rows
EndFunction

Int Function PickRole(Actor akParent, String asChildName) Global
    { Mother or father. Returns 0, 1, or -1 for cancelled.

      THE ACTOR'S SEX ONLY CHOOSES WHICH OPTION IS LISTED FIRST - it never
      decides. Parentage in this mod is recorded by FormID on both sides
      precisely so a female player's children can have an NPC father, and a UI
      that inferred the role from sex would quietly re-introduce the assumption
      the storage model just removed. }
    String[] roles = new String[2]
    Int femaleFirst = 0
    If akParent.GetActorBase().GetSex() == 1
        femaleFirst = 1
    EndIf
    If femaleFirst == 1
        roles[0] = "Mother of " + asChildName
        roles[1] = "Father of " + asChildName
    Else
        roles[0] = "Father of " + asChildName
        roles[1] = "Mother of " + asChildName
    EndIf
    Int pick = Pick("What is " + akParent.GetDisplayName() + " to " + asChildName + "?", roles)
    If pick < 0
        Return -1
    EndIf
    ; Map the chosen row back through the ordering above.
    If femaleFirst == 1
        Return pick        ; 0 mother, 1 father
    EndIf
    Return 1 - pick        ; 0 father, 1 mother
EndFunction

; ===========================================================================
; Candidates
; ===========================================================================

Actor Function PickTrackedActor() Global
    { Everyone Fertility Mode is tracking, women and men in one list.

      TrackedActors holds the women it follows cycles for; TrackedFathers holds
      the men it has recorded as fathers. Together they are the only list of
      plausible parents obtainable without taking a dependency on another mod,
      and they cost nothing because this mod already reads both arrays.

      Capped at 128 rows: Papyrus arrays cannot exceed that, FMR's own tracking
      ceiling is 256, and a list longer than a screen is not a picker anyway.
      When it overflows, say so rather than silently truncating. }
    _JSW_BB_Storage store = SNKin_Bridge.ResolveStorage()
    If store == None
        Say("Fertility Mode not found.")
        Return None
    EndIf

    Form[] women = store.TrackedActors
    Form[] men = store.TrackedFathers
    ; `new Actor[128]`, not Utility.CreateActorArray - PapyrusUtil provides
    ; Create*Array for Form, Alias, Int, Float, String and Bool but NOT Actor.
    ; A literal-size `new` is the only way to size an Actor array.
    Actor[] found = new Actor[128]
    String[] rows = Utility.CreateStringArray(128, "")
    Int count = 0

    count = Gather(women, found, rows, count, "")
    count = Gather(men, found, rows, count, "")

    If count == 0
        Say("Fertility Mode is not tracking anyone yet.")
        Return None
    EndIf

    ; Trim to what was actually filled - ShowList would otherwise render blanks.
    String[] shown = Utility.CreateStringArray(count, "")
    Int i = 0
    While i < count
        shown[i] = rows[i]
        i += 1
    EndWhile

    Int pick = Pick("Tracked by Fertility Mode (" + count + ")", shown)
    If pick < 0
        Return None
    EndIf
    Return found[pick]
EndFunction

Int Function Gather(Form[] akSource, Actor[] akInto, String[] asRows, Int aiCount, String asTag) Global
    { Appends the non-empty, non-duplicate actors from one FMR array. Returns
      the new count. Duplicates matter: a woman can appear in both arrays on a
      female-player save. }
    If akSource == None
        Return aiCount
    EndIf
    Int n = aiCount
    Int i = 0
    While i < akSource.Length && n < akInto.Length
        Actor a = akSource[i] as Actor
        If a != None && akInto.Find(a) < 0
            akInto[n] = a
            String sex = " (m)"
            If a.GetActorBase().GetSex() == 1
                sex = " (f)"
            EndIf
            asRows[n] = a.GetDisplayName() + sex + asTag
            n += 1
        EndIf
        i += 1
    EndWhile
    Return n
EndFunction
