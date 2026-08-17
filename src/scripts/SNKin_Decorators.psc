Scriptname SNKin_Decorators Hidden
{ Decorator functions for SkyrimNet.

  DELIBERATELY A STANDALONE HIDDEN SCRIPT, NOT THE QUEST SCRIPT. SkyrimNet's
  documented example registers decorators against a plain script containing
  Global functions, and the Romantasy mod established by experiment that
  hosting them on a Quest-extending script fails: RegisterDecorator returns
  rc=0 and lookups then fail with "Decorator '<name>' not found".

  EVERY FUNCTION REGISTERED AS A DECORATOR RETURNS String - INCLUDING THE
  BOOLEAN ONES. Bool-returning decorators register with rc=0 and then fail at
  dispatch. Surveyed across ten decorators in four other mods; there are no
  exceptions.

  These read state only. Anything that MUTATES state stays on SNKin_Bridge. }

; ===========================================================================
; INTS, NOT JSON BOOLEANS - and this is a deliberate departure from the spec,
; which asked for {"known":false}.
;
; Papyrus interns strings CASE-INSENSITIVELY. A hand-written lowercase "false"
; folds into whatever casing already holds that slot in the compiled script -
; and `False` is a Papyrus keyword, so it is very often already there in
; capitals. The literal then ships as `False`, which is not valid JSON, and
; Inja gives up on the WHOLE object: every kin.* field becomes undefined at
; once. Read through default() the prompt does not error, it simply renders
; nothing, and nothing says why.
;
; The Romantasy mod has been getting away with lowercase in one file and was
; bitten by capitals in another on 2026-08-07. An Int cannot be case-folded.
; The prompt tests == 1.
; ===========================================================================

String Function Unknown() Global
    Return "{\"known\":0}"
EndFunction

String Function GetKinship(Actor akActor) Global
    { Rich parentage for prompts. Answers for BOTH halves of the relationship:
      a child gets its parents, a mother gets the children she bore.

      Never call inside a get_nearby_npc_list loop - mod-added decorators only
      resolve for the current speaker or target, and return null elsewhere,
      which makes SkyrimNet throw
      "json.exception.type_error.302 type must be number, but is null". }
    If akActor == None
        Return Unknown()
    EndIf

    ; Child, by explicit binding first. SNKin_Bridge.BindSpawnedChildren sets
    ; this when it matches one of FMR's spawned references to a roster entry,
    ; so it is an exact lookup rather than a name comparison.
    If StorageUtil.GetIntValue(akActor, "SNKin_Bound", 0) == 1
        Int idx = JsonUtil.GetIntValue(SNKin_Bridge.StoreFile(), \
            "ref." + akActor.GetFormID() + ".child", -1)
        If idx >= 0
            Return ChildPayload(idx)
        EndIf
    EndIf

    ; Child, by name - and this is the PRIMARY path, not a fallback.
    ;
    ; SpawnedChildActorRefs CANNOT HOLD ALL OF THE PLAYER'S CHILDREN. It is not
    ; a list of children at all; it is a cache keyed by appearance archetype,
    ; and FMR sizes it wrong. From the 1.0.3 sources:
    ;
    ;   - it is indexed by PlayerChildActorIndex, an index into AdultChildren,
    ;     which holds 220 entries (11 classes x 10 races x 2 genders)
    ;   - but _JSW_BB_Storage.psc:254 allocates `new Actor[128]`, so any child
    ;     whose archetype lands at 128 or above can never be written to it -
    ;     _JSW_BB_ConfigQuestScript.psc:4120 is then an out-of-bounds write,
    ;     which Papyrus logs and skips
    ;   - and because the key is the ARCHETYPE, two of the player's children
    ;     sharing a class, race and gender share ONE slot: the second summon
    ;     re-uses the first one's actor (:4100) and never renames it
    ;
    ; So on the live save Nicollette and Lyra bound and Toryy did not, even
    ; though she HAD been summoned as an adult and made a follower - which also
    ; rules out the first guess, that only grown-and-summoned children appear
    ; there. SummonAdultChild does call SetDisplayName (:4123), so the name is
    ; trustworthy; it is the array that is incomplete.
    ;
    ; With 23 children on one save, collisions are the norm rather than the
    ; exception, which is why this path carries the feature and
    ; BindSpawnedChildren is only an optimisation for the cases it can hold.
    ;
    ; Matching on display name is safe here ONLY because of the dynamic-ref
    ; guard. FMR children are always PlaceActorAtMe spawns in the 0xFF range,
    ; while a vanilla NPC who happens to share a name (there is an Inga in
    ; Skyrim, and Inga is on this player's roster) is a static reference and is
    ; excluded. Without that guard this would misattribute parentage to
    ; strangers on a name collision.
    ;
    ; Deliberately NOT persisted. Writing a binding from a decorator would make
    ; a read path mutate state during a prompt render; the lookup is one
    ; StringListFind and is cheap enough to repeat.
    If SNKin_Bridge.IsDynamicRef(akActor.GetFormID())
        Int byName = SNKin_Bridge.ChildIndex(akActor.GetDisplayName())
        If byName >= 0
            Return ChildPayload(byName)
        EndIf
    EndIf

    ; Then parent - either one.
    ;
    ; Asked of the STORE rather than of a flag on the actor. SNKin_IsMother
    ; used to live in StorageUtil, which meant the actor had to be loaded for
    ; it to be written - the same wall that stopped the web API accepting an
    ; absent mother. A list keyed by FormID in a file has no such requirement,
    ; so a parent recorded while they were on the other side of Skyrim answers
    ; correctly the moment you meet them.
    If JsonUtil.IntListCount(SNKin_Bridge.StoreFile(), \
            SNKin_Bridge.ParentPath(akActor.GetFormID())) > 0
        Return ParentPayload(akActor)
    EndIf

    Return Unknown()
EndFunction

String Function ChildPayload(Int aiIdx) Global
    { aiIdx is the child's position in our roster - see SNKin_Bridge.ChildIndex
      for why the key is an index and not anything derived from the name. }
    String f = SNKin_Bridge.StoreFile()
    String nm = JsonUtil.GetStringValue(f, "child." + aiIdx + ".name", "")
    If nm == ""
        Return Unknown()
    EndIf
    ; A tombstoned record must not speak. Hiding a child is usually a statement
    ; that it belongs to a DIFFERENT playthrough, and the last thing that child
    ; should do is turn up in this one's dialogue.
    If JsonUtil.GetIntValue(f, "child." + aiIdx + ".hidden", 0) == 1
        Return Unknown()
    EndIf
    String mother = JsonUtil.GetStringValue(f, "child." + aiIdx + ".mother", "")
    ; motherKnown is what the prompt tests before saying anything about her.
    ; A child whose mother was never recovered must read as a child who has not
    ; been told, not as a child with no mother.
    Int motherKnown = 0
    If mother != ""
        motherKnown = 1
    EndIf
    Return "{\"known\":1,\"role\":\"child\"" + \
        ",\"name\":\"" + JsonEscape(nm) + "\"" + \
        ",\"father\":\"" + JsonEscape(JsonUtil.GetStringValue(f, "child." + aiIdx + ".father", "")) + "\"" + \
        ",\"mother\":\"" + JsonEscape(mother) + "\"" + \
        ",\"motherKnown\":" + motherKnown + \
        ",\"gender\":\"" + JsonEscape(JsonUtil.GetStringValue(f, "child." + aiIdx + ".gender", "")) + "\"" + \
        ",\"race\":\"" + JsonEscape(JsonUtil.GetStringValue(f, "child." + aiIdx + ".race", "")) + "\"" + \
        ",\"born\":" + JsonUtil.GetFloatValue(f, "child." + aiIdx + ".born", 0.0) + "}"
EndFunction

String Function ParentPayload(Actor akActor) Global
    { This actor's children, as a JSON array.

      Works for either parent. `relation` says which they are TO THIS CHILD,
      resolved per child rather than per actor, because one NPC can be the
      mother of one child and - on a different playthrough shape - there is no
      reason to assume every entry in their list has the same role.

      Capped at eight. A parent with more than eight of the player's children
      has already made the point, and an unbounded loop here would build an
      unbounded string inside a prompt render. }
    String f = SNKin_Bridge.StoreFile()
    Int me = akActor.GetFormID()
    String path = SNKin_Bridge.ParentPath(me)
    Int n = JsonUtil.IntListCount(f, path)
    If n <= 0
        Return Unknown()
    EndIf
    Int shown = n
    If shown > 8
        shown = 8
    EndIf
    String kids = ""
    Int i = 0
    While i < shown
        Int idx = JsonUtil.IntListGet(f, path, i)
        If i > 0
            kids += ","
        EndIf
        ; Which parent am I to THIS child? Compared by FormID, never inferred
        ; from sex - a female player's children have an NPC father, and that is
        ; the whole case this rewrite exists for.
        String relation = "parent"
        String otherName = ""
        If JsonUtil.GetIntValue(f, "child." + idx + ".motherId", 0) == me
            relation = "mother"
            otherName = JsonUtil.GetStringValue(f, "child." + idx + ".father", "")
        ElseIf JsonUtil.GetIntValue(f, "child." + idx + ".fatherId", 0) == me
            relation = "father"
            otherName = JsonUtil.GetStringValue(f, "child." + idx + ".mother", "")
        EndIf
        kids += "{\"name\":\"" + JsonEscape(JsonUtil.GetStringValue(f, "child." + idx + ".name", "")) + "\"" + \
            ",\"relation\":\"" + relation + "\"" + \
            ",\"otherParent\":\"" + JsonEscape(otherName) + "\"" + \
            ",\"gender\":\"" + JsonEscape(JsonUtil.GetStringValue(f, "child." + idx + ".gender", "")) + "\"" + \
            ",\"born\":" + JsonUtil.GetFloatValue(f, "child." + idx + ".born", 0.0) + "}"
        i += 1
    EndWhile
    Return "{\"known\":1,\"role\":\"parent\",\"count\":" + n + ",\"children\":[" + kids + "]}"
EndFunction

String Function IsChildOfPlayer(Actor akActor) Global
    { Cheap gate for prompt guards that only need yes/no. Returns the STRING
      "1" or "0" - see the note at the top about Bool-returning decorators.

      Must apply BOTH tests GetKinship applies, or an unbound small child reads
      as "not a child" here while rendering a full parentage block there. }
    If akActor == None
        Return "0"
    EndIf
    If StorageUtil.GetIntValue(akActor, "SNKin_Bound", 0) == 1
        Return "1"
    EndIf
    If SNKin_Bridge.IsDynamicRef(akActor.GetFormID()) && \
       SNKin_Bridge.ChildIndex(akActor.GetDisplayName()) >= 0
        Return "1"
    EndIf
    Return "0"
EndFunction

String Function IsParentOfPlayersChild(Actor akActor) Global
    { Either parent. Reads the store rather than an actor flag, for the same
      reason GetKinship does - see the note there. }
    If akActor != None && JsonUtil.IntListCount(SNKin_Bridge.StoreFile(), \
            SNKin_Bridge.ParentPath(akActor.GetFormID())) > 0
        Return "1"
    EndIf
    Return "0"
EndFunction

; ===========================================================================
; String helpers.
;
; Upper() USED TO LIVE HERE and was removed in schema 2. It walked a name
; character by character with GetNthChar / AsOrd / AsChar, and on the live save
; the result was lossy and case-scrambled: Nicollette came back "colLETTE",
; Ragnar came back "aa", and the letters B, G, I, N, P and R vanished
; everywhere regardless of position.
;
; Names passed through UNTOUCHED round-tripped perfectly through the same
; JsonUtil store, so the fault was in the per-character rebuild and nowhere
; else. Rather than chase a mechanism that could not be pinned down from
; outside the game, nothing in this mod decomposes a string any more - record
; keys are roster indices, and names are only ever copied whole.
;
; Do not reintroduce a character loop here without testing its output against
; a real name in a live save first.
; ===========================================================================

String Function ReplaceAll(String asText, String asFind, String asWith) Global
    String out = ""
    String rest = asText
    Int at = StringUtil.Find(rest, asFind)
    While at >= 0
        out += StringUtil.Substring(rest, 0, at) + asWith
        rest = StringUtil.Substring(rest, at + StringUtil.GetLength(asFind))
        at = StringUtil.Find(rest, asFind)
    EndWhile
    Return out + rest
EndFunction

String Function JsonEscape(String asText) Global
    { Child names are TYPED BY THE PLAYER, so none of this is under our
      control. One stray quote or backslash makes the whole object
      unparseable and every kin.* field silently undefined.

      Removing rather than escaping: these are short display names bound for a
      prompt, so a lost backslash costs nothing, while emitting an escaped pair
      and relying on both ends to agree is one more thing to get wrong.

      NEVER loop AsChar(0..31) here. AsChar(0) yields an EMPTY string, so the
      first iteration becomes ReplaceAll(s, "", " ") - replacing the empty
      string, which faults. Tab, LF and CR are named explicitly. }
    String s = asText
    s = ReplaceAll(s, "\\", "")
    s = ReplaceAll(s, "\"", "'")
    s = ReplaceAll(s, StringUtil.AsChar(9), " ")
    s = ReplaceAll(s, StringUtil.AsChar(10), " ")
    s = ReplaceAll(s, StringUtil.AsChar(13), " ")
    Return s
EndFunction
