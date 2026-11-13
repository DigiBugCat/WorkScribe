----------------------------- MODULE VaultNote -----------------------------
(***************************************************************************)
(* One note in the vault, written by two programs: the person, through     *)
(* Obsidian, and WorkScribe.                                               *)
(*                                                                         *)
(* Code: Sources/WorkScribeCore/Vault/VaultStore.swift                     *)
(*         replace(_:with:expected:)  the one place a note is replaced     *)
(*         update, finalizeDocument, appendToInbox  its callers            *)
(*       Sources/WorkScribe/MeetingRetention.swift (done)                  *)
(*         the rewrite that takes WorkScribe's markers out of a note       *)
(*         before the meeting's raw material is purged                     *)
(*                                                                         *)
(* WorkScribe reads the note, works out its new text from what it read     *)
(* (merging region by region, so the person's own text is carried over),   *)
(* and replaces the file.  Obsidian saves the person's text whenever it    *)
(* likes; the two programs share nothing but the file.  Each system call   *)
(* is a step, and a save can land between any two of them.                 *)
(*                                                                         *)
(* A file's content is modelled by who wrote it and which of the person's  *)
(* saves it carries: WorkScribe's text carries the save it was worked out  *)
(* from.  All fix constants FALSE is the code as it was found.             *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANTS
    MaxSaves,       \* how many times the person saves
    MaxJobs,        \* how many times WorkScribe sets out to write the note
    Kinds,          \* which of WorkScribe's writes happen: "merge" (update, finalize, inbox), "strip" (before a purge)

    \* Fixes as written.
    SwapAndVerify,  \* replace() exchanges its text with the file, looks at what it took out, and puts it back if that is not what it read
    StripCompares,  \* the rewrite before a purge goes through replace() with the text it read, like every other write

    \* Mutations.
    MutNoPutBack,           \* what was taken out is checked, but a surprise is not put back
    MutPutBackUnchecked     \* the put-back does not look at what it took out in turn

VARIABLES
    file,       \* the note
    saves,      \* how many times the person has saved
    pc, kind,   \* WorkScribe's write in progress
    base,       \* what it read
    temp,       \* the file beside the note that holds what is being exchanged
    put,        \* what the latest exchange moved into the note's place
    expect,     \* what that exchange should have taken out, if nobody saved since the one before
    back,       \* the write has given up and is putting the person's text back
    jobs

vars == <<file, saves, pc, kind, base, temp, put, expect, back, jobs>>

Content == [by : {"person", "app"}, v : 0..MaxSaves]
None == [by |-> "nobody", v |-> 0]

TypeOK ==
    /\ file \in Content /\ saves \in 0..MaxSaves /\ jobs \in 0..MaxJobs
    /\ pc \in {"idle", "read", "checked", "took", "back"}
    /\ kind \in Kinds \cup {"none"} /\ back \in BOOLEAN
    /\ base \in Content \cup {None} /\ temp \in Content \cup {None}
    /\ put \in Content \cup {None} /\ expect \in Content \cup {None}

Init ==
    /\ file = [by |-> "person", v |-> 0] /\ saves = 0
    /\ pc = "idle" /\ kind = "none" /\ base = None /\ temp = None /\ put = None /\ expect = None
    /\ back = FALSE /\ jobs = 0

\* Obsidian writes the person's text to the note's path, whatever is there at that moment.
Save ==
    /\ saves < MaxSaves
    /\ saves' = saves + 1
    /\ file' = [by |-> "person", v |-> saves + 1]
    /\ UNCHANGED <<pc, kind, base, temp, put, expect, back, jobs>>

\* What WorkScribe writes: its sections, around the person's text as it was when the note was read.
Mine == [by |-> "app", v |-> base.v]

Finish == pc' = "idle" /\ kind' = "none" /\ base' = None /\ temp' = None /\ put' = None /\ expect' = None /\ back' = FALSE

\* `Data(contentsOf:)`, then the merge (no system calls).
Read(k) ==
    /\ pc = "idle" /\ jobs < MaxJobs /\ k \in Kinds
    /\ pc' = "read" /\ kind' = k /\ base' = file /\ jobs' = jobs + 1
    /\ UNCHANGED <<file, saves, temp, put, expect, back>>

\* replace(expected:) reads the note again and compares its hash.  A note that changed is left alone: the
\* caller reads it again and merges again (another job).
Recheck ==
    /\ pc = "read" /\ (kind = "merge" \/ StripCompares)
    /\ IF file = base THEN pc' = "checked" /\ UNCHANGED <<kind, base, temp, put, expect, back>> ELSE Finish
    /\ UNCHANGED <<file, saves, jobs>>

\* As found: the temporary file is written (many system calls, during which the note can be saved), then
\* renamed over the note.
Rename ==
    /\ ~SwapAndVerify /\ pc = "checked"
    /\ file' = Mine /\ Finish
    /\ UNCHANGED <<saves, jobs>>

\* As found, before a purge: read, clean, `write(atomically:)`.  No comparison at all.
StripWrite ==
    /\ ~StripCompares /\ pc = "read" /\ kind = "strip"
    /\ file' = Mine /\ Finish
    /\ UNCHANGED <<saves, jobs>>

\* As fixed.  renamex_np(RENAME_SWAP) exchanges the two files in one step: the note's place now holds
\* WorkScribe's text and the temporary file holds whatever the note was.
Exchange ==
    /\ SwapAndVerify /\ pc = "checked"
    /\ file' = Mine /\ temp' = file /\ put' = Mine /\ expect' = base /\ pc' = "took"
    /\ UNCHANGED <<saves, kind, base, back, jobs>>

\* What was taken out is read.  The first time: if it is what the merge started from, nothing was missed
\* and the write is done.  While putting back: if it is what the exchange before had put in, nobody saved
\* in between, and what is in the note's place now is the person's latest save.
Judge ==
    /\ pc = "took"
    /\ IF temp = expect \/ MutNoPutBack \/ (back /\ MutPutBackUnchecked) THEN Finish
       ELSE pc' = "back" /\ back' = TRUE /\ UNCHANGED <<kind, base, temp, put, expect>>
    /\ UNCHANGED <<file, saves, jobs>>

\* It is not.  What came out is a save WorkScribe had not seen, made after the exchange before: it is the
\* newest there is, and it goes back in.  What comes out in its turn is judged the same way.
PutBack ==
    /\ pc = "back"
    /\ file' = temp /\ temp' = file /\ expect' = put /\ put' = temp /\ pc' = "took"
    /\ UNCHANGED <<saves, kind, base, back, jobs>>

Write == Recheck \/ Rename \/ StripWrite \/ Exchange \/ Judge \/ PutBack

Next == Save \/ (\E k \in Kinds : Read(k)) \/ Write

Spec == Init /\ [][Next]_vars
Live == Spec /\ WF_vars(Write)

(***************************************************************************)
(* Properties.                                                             *)
(***************************************************************************)

\* Whenever WorkScribe is not in the middle of a write, the note carries the person's latest save: as they
\* saved it, or inside WorkScribe's text that was worked out from it.  Nothing they saved is replaced by a
\* text that never saw it.
NoLostSave == pc = "idle" => file.v = saves

\* A write that WorkScribe starts comes to an end, however the saves fall.
WriteEnds == (pc # "idle") ~> (pc = "idle")

=============================================================================
