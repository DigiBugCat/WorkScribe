----------------------------- MODULE Retention -----------------------------
(***************************************************************************)
(* MACHINE 2: retention and purge of ONE meeting.                          *)
(*                                                                         *)
(* The spec describes TWO versions of the code, selected by constants:     *)
(*   "edcaebae": git edcaebae96a0f6a34ff891cbac2a0004c4f7ac7c              *)
(*   "current":  the working tree on top of that commit (the fixes are     *)
(*               uncommitted), read on 2026-11-11                          *)
(* Line numbers in the comments are the CURRENT file's.  The README has    *)
(* both columns.                                                           *)
(*                                                                         *)
(*   Sources/WorkScribe/MeetingRetention.swift   the 60 s loop 22-29,      *)
(*     finalize 31-65, done 66-114, predates 117-120, recover 121-150      *)
(*   Sources/WorkScribeCore/Retention.swift      RetentionStore.purge 51-92*)
(*   Sources/WorkScribeCore/Meeting.swift        save 120-133, load        *)
(*     134-141, list 142-147, hasTranscript 150-153,                       *)
(*     recoverInterruptedRecordings 156-164                                *)
(*   Sources/WorkScribe/AppModel.swift           deleteRecording 758-769,  *)
(*     start (resume) 230-250 and 342-350, finishRecording 464-465,        *)
(*     509-512, 519-554                                                    *)
(*   Sources/WorkScribeCore/RecordingSession.swift canResume/resume 20-38  *)
(*   Sources/WorkScribe/MeetingNotes.swift       meetingSnapshot 24-27,    *)
(*     mutateMeeting 30-47                                                 *)
(*   Sources/WorkScribe/IndexService.swift       purgeMeeting 187-198      *)
(*   Sources/WorkScribeCore/Search/SearchIndexVectors.swift purge 85-102   *)
(*   Sources/WorkScribeCore/Engine/Index.swift   apply's fence 37-38,      *)
(*     writeVectors' fence 172-173; Engine/Line.swift saveLines' fence 178 *)
(*   Sources/WorkScribeCore/Search/MeetingIndexer.swift sync 43-69         *)
(*   Sources/WorkScribe/LocalAPI.swift           openDocument 110-116,     *)
(*     syncDocument 117-139, finalizeDocument 140-147, done 148-153        *)
(*                                                                         *)
(* Steps are cut at the awaits of the @MainActor methods, exactly as in    *)
(* Recording.tla.  RetentionStore.purge is synchronous, so nothing else on *)
(* the main actor can run inside it, but the process can die inside it:    *)
(* its file operations are separate steps that only Crash can interleave.  *)
(*                                                                         *)
(* THREE KINDS OF CONSTANT, as in Recording.tla: the fixes as written in   *)
(* the working tree (three rounds touched this machine), the sketch the    *)
(* edcaebae findings were first checked against, and mutations.  All       *)
(* FALSE, no document and the environment refinements off is the code at   *)
(* edcaebae exactly as it was modelled then.  "previous" in configuration  *)
(* names is the first round.                                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    IndexUpInit,      \* the search index opened at launch (IndexService.make returned non-nil)
    IndexMayFail,     \* after a relaunch the index may be unavailable
    RequiresIndex,    \* MeetingRetention.requiresIndex (true in the app, false in --replay)
    FinishMayFail,    \* NoteEnhancementScheduler.finish may return false
    MaxResume, MaxCrash, MaxTrash, MaxCorrupt, MaxDone, MaxPluginFinalize, MaxIndexThrow,
    AllowLate,        \* stale writers: store.save and index writes by code holding an old copy
    AllowAsk,         \* a conversation scoped to the meeting may be created
    AllowDisplace,    \* model.meeting may move on to another meeting
    \* --- refinements of the environment, added for the current code.  Off = the model as it was at edcaebae.
    DocInit,          \* "none" | "open": the meeting has a plugin document (meeting.document) from the start
    MaxOpenDoc,       \* how many times the plugin may open the note later (LocalAPI 110-116)
    MaxUndo,          \* how many times the plugin may undo a finalize by syncing the note (LocalAPI 122-135)
    MaxFinalizeFail,  \* how many times finalize may throw before writing anything (vault unavailable, a document
                      \* that cannot be rebased)
    VaultDown,        \* finalize always throws
    MaxTorn,          \* how many times the process may die between finalize's two writes (60 and 61)
    TrashOnlyFinalized,   \* the user only trashes a meeting that has a receipt   (separates T5 (a) from (e))
    CorruptOnlyFinalized, \* the transcript only goes bad once there is a receipt  (separates T5 (b) from (b'))
    \* --- the fixes as written in the working tree
    FixFinalizeChecksReceipt,  \* 34: finalize refuses when the receipt ON DISK is purging/purged
    FixIndexFirst,             \* 72: done refuses for lack of an index BEFORE it journals "purging"
    FixStale,                  \* 76, 146: a receipt written before the meeting's last stop (`predates`) is not a
                               \* reason to purge: done finalizes again first, recover's last loop skips it
    FixDoneRecheckAfter,       \* 83: done re-checks "not resumed" after its own finalize
    FixL116,                   \* 142: recover skips only a meeting that is readable and has no endedAt
    FixRecoverLive,            \* 124: recover's first loop also takes ended meetings whose retention is "live"
    FixSyncDropsTrashed,       \* MeetingIndexer.swift:49: a receipt stand-in is not a live meeting
    \* --- a later round (the third), written in answer to this model's findings on the first (T7, T5 (b''))
    FixDoneRecheckStale,       \* 87-89: after its own finalize, done looks again at what sent it there (76): a receipt
                               \* that predates the last stop, or an open document, and throws
    FixStaleOnDisk,            \* 146: recover's stale-receipt skip is judged by the copy on disk (store.load), not by
                               \* the copy in memory; a transcript that cannot be read gives no skip
    \* --- the fourth round, written in answer to what the third round's re-check (87-89) broke
    FixReplaySkipsFinalize,    \* 76: `known?.state != "purging"` comes first in the branch condition, so a purge that
                               \* is already journalled is replayed as it stands, whatever the copy in memory says
    \* --- sketch from the edcaebae round: not in the code
    FixDoneRecheck,            \* done re-checks "not resumed" right before it journals, on every path
    \* --- what T9 needs (off = the state space as it was)
    TrackEarly,
    \* --- mutations
    MutNoStoreFence,           \* drop MeetingStore.save's receipt check (Meeting.swift:121)
    MutNoIndexFence,           \* drop the `purged:` checks in the index
    MutNoJournal,              \* never write "purging" before deleting
    MutNoL116,                 \* drop the endedAt check at 142
    MutPurgeSkipsIndex,        \* done does not purge the index (drop 108)
    MutNoStaleInDone,          \* drop `predates` from done (76)
    MutNoStaleInRecover        \* drop `predates` from recover (146)

Callers == {"user", "recover"}

VARIABLES
    receipt, rEpoch,          \* .retention/<id>.json: state, and which stop its endedAt / purgeAt belong to
    fEpoch,                   \* the stop whose finalization the vault note holds (0 = none): written by finalize,
                              \* taken back by the plugin's undo.  Not something the app stores; T7 is stated with it.
    folder,                   \* the meeting folder: "ok" | "unreadable" (transcript.json won't decode) | "gone"
    sEnded, sRet, sStatus, sDoc,     \* transcript.json as last written: endedAt (0 = nil), retention, status, document
    live, mEnded, mRet, mStatus, mDoc,  \* model.meeting when it is this meeting
    phase,                    \* "recording" | "finalizing" | "idle" (AppModel.busy = phase # "idle")
    idx, fence, indexUp,      \* index rows for the meeting exist; meta purged:<id> = 1; an IndexService exists
    conv,                     \* a conversation scoped to the meeting, holding answers drawn from it, is on disk
    now, epoch,               \* stops so far; how many of their 24 h deadlines have passed
    dn, working,              \* done() calls in flight, MeetingRetention.working
    rc, fz, stp,              \* recover(), the plugin's Finalize route, finishRecording's tail
    used, hist, ever

vars == <<receipt, rEpoch, fEpoch, folder, sEnded, sRet, sStatus, sDoc, live, mEnded, mRet, mStatus, mDoc, phase, idx, fence,
          indexUp, conv, now, epoch, dn, working, rc, fz, stp, used, hist, ever>>

S == [receipt |-> receipt, rEpoch |-> rEpoch, fEpoch |-> fEpoch, folder |-> folder, sEnded |-> sEnded, sRet |-> sRet,
      sStatus |-> sStatus, sDoc |-> sDoc, live |-> live, mEnded |-> mEnded, mRet |-> mRet, mStatus |-> mStatus,
      mDoc |-> mDoc, phase |-> phase, idx |-> idx, fence |-> fence, indexUp |-> indexUp, conv |-> conv, now |-> now,
      epoch |-> epoch, dn |-> dn, working |-> working, rc |-> rc, fz |-> fz, stp |-> stp, used |-> used,
      hist |-> hist]

Set(n) ==
    /\ receipt' = n.receipt /\ rEpoch' = n.rEpoch /\ fEpoch' = n.fEpoch /\ folder' = n.folder /\ sEnded' = n.sEnded
    /\ sRet' = n.sRet /\ sStatus' = n.sStatus /\ sDoc' = n.sDoc /\ live' = n.live /\ mEnded' = n.mEnded
    /\ mRet' = n.mRet /\ mStatus' = n.mStatus /\ mDoc' = n.mDoc /\ phase' = n.phase /\ idx' = n.idx
    /\ fence' = n.fence /\ indexUp' = n.indexUp
    /\ conv' = n.conv /\ now' = n.now /\ epoch' = n.epoch /\ dn' = n.dn /\ working' = n.working
    /\ rc' = n.rc /\ fz' = n.fz /\ stp' = n.stp /\ used' = n.used /\ hist' = n.hist
    /\ ever' = (ever \/ n.receipt \in {"purging", "purged"})

IdleDone == [pc |-> "idle"]
IdleRc   == [pc |-> "idle", ended |-> 0]
IdleFz   == [pc |-> "idle", at |-> 0]
IdleStp  == [pc |-> "idle", at |-> 0]

-----------------------------------------------------------------------------
\* Storage

Busy(s) == s.phase # "idle"
Gone(s) == s.receipt \in {"purging", "purged"}

\* Meeting.swift:134-141.  A purging/purged receipt answers for the meeting (Retention.swift:20-24); that
\* stand-in has no document.
Load(s) ==
    IF Gone(s) THEN [ok |-> TRUE, ended |-> s.rEpoch, ret |-> s.receipt, status |-> "complete", doc |-> "none"]
    ELSE IF s.folder = "ok" THEN [ok |-> TRUE, ended |-> s.sEnded, ret |-> s.sRet, status |-> s.sStatus, doc |-> s.sDoc]
    ELSE [ok |-> FALSE, ended |-> 0, ret |-> "nil", status |-> "none", doc |-> "none"]

\* MeetingNotes.swift:24-27
Snap(s) == IF s.live THEN [ok |-> TRUE, ended |-> s.mEnded, ret |-> s.mRet, status |-> s.mStatus, doc |-> s.mDoc]
           ELSE Load(s)

\* Meeting.swift:120-133.  Throws for a purging/purged receipt; otherwise (re)creates the folder.
SaveThrows(s) == Gone(s) /\ ~MutNoStoreFence
StoreSave(s, e, r, st, d) ==
    IF SaveThrows(s) THEN s
    ELSE [s EXCEPT !.folder = "ok", !.sEnded = e, !.sRet = r, !.sStatus = st, !.sDoc = d]

\* Any write of index rows for this meeting: SearchIndex.apply (Index.swift:37), saveLines
\* (Line.swift:178), writeVectors (Index.swift:172).  Each checks the fence inside its transaction.
IndexWrite(s) == IF s.indexUp /\ (~s.fence \/ MutNoIndexFence) THEN [s EXCEPT !.idx = TRUE] ELSE s

Forget(s) == [s EXCEPT !.live = FALSE, !.mEnded = 0, !.mRet = "nil", !.mStatus = "none", !.mDoc = "none"]

\* mutateMeeting (MeetingNotes.swift:30-47) with a change that sets retention and document.  The live copy is
\* changed in memory before save() is tried (35-36); the saved one is loaded, changed and saved (40-44).
Mutate(s, r, d) ==
    IF s.live
    THEN LET s1 == IndexWrite([s EXCEPT !.mRet = r, !.mDoc = d]) IN StoreSave(s1, s1.mEnded, r, s1.mStatus, d)
    ELSE StoreSave(IndexWrite(s), s.sEnded, r, s.sStatus, d)

-----------------------------------------------------------------------------
\* MeetingRetention.finalize, lines 31-63 (synchronous).  64 (indexFinalNote) only touches the vault
\* note's index entry; callers model the suspension there.

\* 34-36: finalize gets as far as writing.
WouldWrite(s) ==
    LET sn == Snap(s) IN
    sn.ok /\ sn.ended # 0 /\ sn.ret \notin {"purged", "purging"} /\ ~(FixFinalizeChecksReceipt /\ Gone(s))

Finalize(s) ==
    LET sn == Snap(s) IN
    IF ~WouldWrite(s) THEN s
    ELSE LET d  == IF sn.doc = "none" THEN "none" ELSE "final"                          \* 58
             s1 == IndexWrite([s EXCEPT !.receipt = "finalized", !.rEpoch = sn.ended,   \* 60, then 61 -> saveLines
                                        !.fEpoch = sn.ended])                           \* 42-56: the note is written
             s2 == IF s.live THEN [s1 EXCEPT !.mRet = "finalized", !.mDoc = d] ELSE s1  \* 61: meeting = live
         IN StoreSave(s2, sn.ended, "finalized", sn.status, d)                          \* 61: save()

\* The vault write (42-56) throws before anything is written: no vault (52), a document that cannot be
\* rebased (44).  `ok` is the environment's choice; it only matters when finalize would have written.
FinOK(s) == IF VaultDown THEN {FALSE} ELSE IF s.used.finFail < MaxFinalizeFail THEN {TRUE, FALSE} ELSE {TRUE}
Fails(s, ok) == ~ok /\ WouldWrite(s) /\ (VaultDown \/ s.used.finFail < MaxFinalizeFail)
Failed(s) == IF VaultDown THEN s ELSE [s EXCEPT !.used.finFail = @ + 1]

\* `predates` (117-120): a finalized receipt whose endedAt is earlier than the meeting's.  (The code allows one
\* second, because receipts keep whole seconds; stops here are whole stamps.)
Predates(s, sn) == s.receipt = "finalized" /\ sn.ok /\ sn.ended # 0 /\ sn.ended > s.rEpoch

-----------------------------------------------------------------------------
\* MeetingRetention.done

DoneExit(s, k) ==
    [s EXCEPT !.dn[k] = IdleDone, !.working = FALSE,
              !.rc = IF k = "recover" THEN IdleRc ELSE @]

\* Retention.swift:91, then MeetingRetention.swift:110-113
P4(s, k) ==
    LET s1 == [s EXCEPT !.receipt = "purged"] IN
    DoneExit(IF s.live THEN [s1 EXCEPT !.mEnded = s.rEpoch, !.mRet = "purged", !.mStatus = "complete", !.mDoc = "none"]
             ELSE s1, k)

\* Retention.swift:90
P3(s, k) == [s EXCEPT !.folder = "gone", !.dn[k].pc = "d_p4",
                      !.hist.t1 = @ \/ (s.folder # "gone" /\ s.receipt # "purging")]

\* Retention.swift:67-89
P2(s, k) == [s EXCEPT !.conv = FALSE, !.dn[k].pc = "d_p3",
                      !.hist.t1 = @ \/ (s.conv /\ s.receipt # "purging")]

\* Retention.swift:53-57 (called from MeetingRetention.swift:109)
P1(s, k) ==
    IF s.receipt = "none" THEN DoneExit(s, k)                                           \* 53 throws
    ELSE IF s.receipt = "purged" THEN P4(s, k)                                          \* 54 returns; 110-113 still run
    ELSE [s EXCEPT !.receipt = IF MutNoJournal THEN @ ELSE "purging", !.dn[k].pc = "d_p2"]

\* What T7 looks for at the moment the journal goes from "finalized" to "purging": the transcript on disk
\* records a stop that the note does not hold.  Without a plugin document the receipt is only ever written by
\* finalize, so this is "the receipt was written for an earlier stop" (rEpoch = fEpoch), as at edcaebae.  With
\* one, the receipt's endedAt can be moved without finalizing (AppModel.swift:538-540), and a finalization can
\* be undone.
NoteBehind(s) == s.receipt = "finalized" /\ s.folder = "ok" /\ s.sEnded # 0 /\ s.sEnded # s.fEpoch

\* 91-107
DoneJournal(s, k) ==
    IF FixDoneRecheck /\ ((Snap(s).ok /\ Snap(s).ended = 0) \/ (Busy(s) /\ s.live)) THEN DoneExit(s, k)
    ELSE IF s.receipt = "purged" THEN DoneExit(s, k)                                    \* 91
    ELSE LET s1 == IF s.receipt # "none" /\ ~MutNoJournal
                   THEN [s EXCEPT !.receipt = "purging", !.hist.t7 = @ \/ NoteBehind(s),
                                  \* for T9: the 60 s loop starts a purge before the last stop's own deadline
                                  !.hist.t9 = @ \/ (TrackEarly /\ k = "recover" /\ s.receipt = "finalized"
                                                     /\ s.folder = "ok" /\ s.sEnded # 0 /\ s.now < s.sEnded)]
                   ELSE s IN                                                             \* 93-97
         IF ~FixIndexFirst /\ RequiresIndex /\ ~s.indexUp THEN DoneExit(s1, k)          \* edcaebae:81 threw HERE
         ELSE [s1 EXCEPT !.dn[k].pc = "d_clear"]                                        \* 98-107, suspends at 107

\* 83-89, the continuation of done's own finalize.  83: resumed meanwhile, i.e. recording now?  (Not there at
\* edcaebae.)  87-89 (third round): resumed and stopped again, or the finalize undone, meanwhile?  Both read
\* the receipt on disk and the same snapshot `latest`.
DoneAfterFinalize(s, k) ==
    LET sn == Snap(s) IN
    IF FixDoneRecheckAfter /\ (~sn.ok \/ sn.ended = 0 \/ (Busy(s) /\ s.live)) THEN DoneExit(s, k)           \* 83
    ELSE IF FixDoneRecheckStale /\ (Predates(s, sn) \/ (sn.ok /\ sn.doc = "open")) THEN DoneExit(s, k)    \* 87-89
    ELSE DoneJournal(s, k)

\* 80-81, continuation of `await finish(id)` (79)
DoneAfterFinish(s, k, ok) ==
    LET sn == Snap(s) IN
    IF ~sn.ok \/ sn.ended = 0 \/ (Busy(s) /\ s.live) THEN DoneExit(s, k)                \* 80 throws
    ELSE IF Fails(s, ok) THEN DoneExit(Failed(s), k)                                    \* 81 throws
    ELSE LET s1 == Finalize(s) IN                                                       \* 81
         IF s.indexUp THEN [s1 EXCEPT !.dn[k].pc = "d_finIndex"]                        \* finalize suspends at 64
         ELSE DoneAfterFinalize(s1, k)

\* 67-79.  The branch at 76: no receipt, a receipt that predates the last stop, or an open plugin document;
\* and, since the fourth round, never for a receipt that already says "purging".
DoneEnter(s, k) ==
    IF s.working THEN [s EXCEPT !.dn[k] = IdleDone, !.rc = IF k = "recover" THEN IdleRc ELSE @]   \* 67
    ELSE LET s1    == [s EXCEPT !.working = TRUE]
             sn    == Snap(s)
             stale == FixStale /\ ~MutNoStaleInDone /\ Predates(s, sn)
         IN IF FixIndexFirst /\ RequiresIndex /\ ~s.indexUp THEN DoneExit(s1, k)        \* 72 throws
            ELSE IF ~(FixReplaySkipsFinalize /\ s.receipt = "purging")
                    /\ (s.receipt = "none" \/ stale \/ (sn.ok /\ sn.doc = "open"))
                 THEN [s1 EXCEPT !.dn[k].pc = "d_finish"]                               \* 76-79
            ELSE DoneJournal(s1, k)

-----------------------------------------------------------------------------
\* MeetingRetention.recover

\* 139-149
RecoverLoop3(s) ==
    LET due   == s.receipt = "purging" \/ (s.receipt = "finalized" /\ s.now >= s.rEpoch)
        sn    == Snap(s)
        ended == IF FixL116 THEN sn.ok /\ sn.ended = 0 ELSE ~sn.ok \/ sn.ended = 0     \* 142 (edcaebae:116)
        \* 146.  The first round judged this by the snapshot (the copy in memory when there is one).
        stale == FixStale /\ ~MutNoStaleInRecover /\ Predates(s, IF FixStaleOnDisk THEN Load(s) ELSE sn)
    IN IF ~due \/ (ended /\ ~MutNoL116) \/ stale THEN [s EXCEPT !.rc = IdleRc]
       ELSE DoneEnter([s EXCEPT !.rc.pc = "r_done", !.dn["recover"].pc = "entered"], "recover")

\* 131-138: a meeting with an open plugin document is finalized 23 h after it ended.  (An hour before the
\* deadline; here "its deadline has passed", which the same call of recover then acts on in the last loop.)
\* The list is read from disk (store.list()), where a receipt stand-in has no document.
RecoverLoop2(s, ok) ==
    LET ld == Load(s)
        c2 == ld.ok /\ ld.doc = "open" /\ ld.ended # 0 /\ ~(Busy(s) /\ s.live) /\ s.now >= ld.ended
    IN IF ~c2 THEN RecoverLoop3(s)
       ELSE IF Fails(s, ok) THEN RecoverLoop3(Failed(s))                                \* 136
       ELSE LET s1 == Finalize(s) IN                                                    \* 134
            IF s.indexUp /\ WouldWrite(s) THEN [s1 EXCEPT !.rc.pc = "r_docIndex"] ELSE RecoverLoop3(s1)

\* 126-129, continuation of `await finish(...)` (126)
RecoverAfterFinish(s, finished, ok1, ok2) ==
    IF finished \/ s.now >= s.rc.ended
    THEN IF Fails(s, ok1) THEN RecoverLoop2(Failed(s), ok2)                             \* 129
         ELSE LET s1 == Finalize(s) IN
              IF s.indexUp THEN [s1 EXCEPT !.rc.pc = "r_finIndex"] ELSE RecoverLoop2(s1, ok2)
    ELSE RecoverLoop2(s, ok2)

\* 124: the `where` clause over store.list() (Meeting.swift:142-147: a receipt stands in for a folder
\* that cannot be loaded).
RecoverStart(s, ok2) ==
    LET ld == Load(s)
        e  == IF ld.ok THEN ld
              ELSE [ok |-> s.receipt # "none", ended |-> s.rEpoch, ret |-> s.receipt, status |-> "complete", doc |-> "none"]
        c1 == e.ok /\ e.ended # 0 /\ (e.ret = "nil" \/ (FixRecoverLive /\ e.ret = "live")) /\ e.doc = "none"
              /\ ~(Busy(s) /\ s.live)
    IN IF c1 THEN [s EXCEPT !.rc = [pc |-> "r_finish", ended |-> e.ended]] ELSE RecoverLoop2(s, ok2)

-----------------------------------------------------------------------------
\* The tail of AppModel.finishRecording, reduced to what retention sees.

StopGuard(s) == s.live /\ s.phase = "finalizing" /\ s.mEnded = s.stp.at
\* 546-554.  (Recording.tla is where that guard is checked; here it is assumed present, so that what is found
\* below is not a consequence of the defect it fixed.)
StopEnd(s) == IF StopGuard(s) THEN [s EXCEPT !.phase = "idle", !.stp = IdleStp] ELSE [s EXCEPT !.stp = IdleStp]
\* 524-541, continuation of the final note pass (519)
StopAfterNotes(s, ok) ==
    IF ~StopGuard(s) THEN [s EXCEPT !.stp = IdleStp]                                    \* 524
    ELSE IF s.mDoc # "none"
         \* 536-540: a meeting with a plugin document is not finalized at Stop.  Its retention becomes "live",
         \* and a receipt that already exists has its endedAt and purgeAt moved to this stop, state unchanged.
         THEN LET s1 == Mutate(s, "live", s.mDoc)
                  s2 == IF ~SaveThrows(s) /\ s1.receipt # "none" THEN [s1 EXCEPT !.rEpoch = s1.mEnded] ELSE s1
              IN StopEnd(s2)
    ELSE IF Fails(s, ok) THEN StopEnd(Failed(s))                                        \* 543
    ELSE LET s1 == Finalize(s) IN                                                       \* 529-533
         IF s.indexUp THEN [s1 EXCEPT !.stp.pc = "st_index"] ELSE StopEnd(s1)

-----------------------------------------------------------------------------
\* Actions.  InPurge: RetentionStore.purge holds the main actor; only the process dying can cut in.

InPurge == \E k \in Callers : dn[k].pc \in {"d_p2", "d_p3", "d_p4"}

\* --- environment ---

\* Stop: AppModel.swift:464-465, 509-512 collapsed.  The save may throw (468, 512 swallow it).
Stop ==
    /\ ~InPurge /\ phase = "recording" /\ stp.pc = "idle"
    /\ LET e == epoch + 1 IN
       Set(StoreSave([S EXCEPT !.mEnded = e, !.mStatus = "complete", !.phase = "finalizing",
                               !.epoch = e, !.stp = [pc |-> "st_notes", at |-> e]], e, mRet, "complete", mDoc))

\* RecordingSession.swift:21-25 on meetingSnapshot(id); "within ten minutes" = its deadline has not passed.
CanResume(s) ==
    LET sn == Snap(s) IN
    sn.ok /\ sn.ended # 0 /\ s.now < sn.ended /\ sn.ret \notin {"purging", "purged"} /\ sn.doc # "final"
          /\ sn.status \in {"complete", "interrupted"}

\* start(resuming:) through AppModel.swift:250 (the lifecycle between is Recording.tla's subject).
\* 235 resume(): endedAt = nil, purgeAt = nil, retention = "live".  250 save() can throw on the
\* store fence; then 342-350 mark the in-memory meeting failed, with a new endedAt, and cannot save.
Resume ==
    /\ ~InPurge /\ used.resume < MaxResume
    /\ phase = "idle" \/ (phase = "finalizing" /\ stp.pc # "idle" /\ live)              \* 208-209
    /\ CanResume(S)
    /\ LET s1 == [S EXCEPT !.used.resume = @ + 1, !.live = TRUE, !.mDoc = Snap(S).doc] IN
       IF SaveThrows(S)
       THEN Set([s1 EXCEPT !.mEnded = epoch + 1, !.mRet = "live", !.mStatus = "failed",
                           !.epoch = @ + 1, !.phase = "idle"])
       ELSE Set(StoreSave([s1 EXCEPT !.mEnded = 0, !.mRet = "live", !.mStatus = "recording",
                                     !.phase = "recording"], 0, "live", "recording", s1.mDoc))

\* Done from the plugin (LocalAPI.swift:148-152) or "Done now" (RecorderView.swift:361).
UserDone ==
    /\ ~InPurge /\ used.done < MaxDone /\ dn["user"].pc = "idle"
    /\ LET sn == Snap(S) IN sn.ok /\ sn.ended # 0 /\ ~(Busy(S) /\ live)                 \* 149-150
    /\ Set(DoneEnter([S EXCEPT !.used.done = @ + 1, !.dn["user"].pc = "entered"], "user"))

\* Finalize from the plugin: LocalAPI.swift:141-144 up to `await finish`.
PluginFinalize ==
    /\ ~InPurge /\ used.finalize < MaxPluginFinalize /\ fz.pc = "idle"
    /\ LET sn == Snap(S) IN
       /\ sn.ok /\ sn.ended # 0 /\ ~Busy(S)
       /\ Set([S EXCEPT !.used.finalize = @ + 1, !.fz = [pc |-> "fz_finish", at |-> sn.ended]])

\* The plugin opens the meeting's note (LocalAPI.swift:110-116): the meeting gets a document, not finalized.
OpenDoc ==
    /\ ~InPurge /\ used.openDoc < MaxOpenDoc
    /\ LET sn == Snap(S) IN
       /\ sn.ok /\ sn.ret \notin {"purging", "purged"} /\ sn.doc = "none"
       /\ Set(Mutate([S EXCEPT !.used.openDoc = @ + 1], sn.ret, "open"))

\* The plugin syncs a finalized note back before its deadline, with the note file as it was before finalize
\* (LocalAPI.swift:122-135): the document is open again and retention is "live".  The receipt is left as it
\* is.  The note no longer holds the finalization.
UndoFinalize ==
    /\ ~InPurge /\ used.undo < MaxUndo
    /\ LET sn == Snap(S) IN
       /\ sn.ok /\ sn.doc = "final" /\ sn.ret = "finalized" /\ now < sn.ended
       /\ Set(Mutate([S EXCEPT !.used.undo = @ + 1, !.fEpoch = 0], "live", "open"))

\* AppModel.deleteRecording 758-769: the folder goes to the Trash; receipt, index rows and
\* conversations are left alone.  (767 asks the indexer to look again; IndexerSync is already always due.)
Trash ==
    /\ ~InPurge /\ used.trash < MaxTrash /\ folder # "gone" /\ ~(Busy(S) /\ live)       \* 759
    /\ TrashOnlyFinalized => receipt # "none"
    /\ Set(Forget([S EXCEPT !.used.trash = @ + 1, !.folder = "gone"]))

\* model.meeting moves on to another meeting (the next recording installs itself at AppModel.swift:245).
\* From then on meetingSnapshot(id) reads this meeting from disk.
Displace == /\ ~InPurge /\ AllowDisplace /\ live /\ phase = "idle" /\ Set(Forget(S))

\* transcript.json stops decoding (damage, or a field the running build cannot read).
Corrupt ==
    /\ ~InPurge /\ used.corrupt < MaxCorrupt /\ folder = "ok" /\ phase = "idle"
    /\ CorruptOnlyFinalized => receipt # "none"
    /\ Set([S EXCEPT !.used.corrupt = @ + 1, !.folder = "unreadable"])

\* The process dies (crash, kill, power) and is launched again.  Everything in memory is gone.
\* Launch: AppModel.init runs recoverInterruptedRecordings (Meeting.swift:156-164) before anything else.
Crashed(s, up) ==
    LET ld  == Load(s)
        cut == ld.ok /\ ~Gone(s) /\ ld.status \in {"recording", "finalizing"}
        e   == IF ld.ended = 0 THEN s.epoch + 1 ELSE ld.ended
    IN Forget([s EXCEPT !.phase = "idle", !.working = FALSE,
                        !.dn = [k \in Callers |-> IdleDone], !.rc = IdleRc, !.fz = IdleFz, !.stp = IdleStp,
                        !.indexUp = up,
                        !.sStatus = IF cut THEN "interrupted" ELSE @,
                        !.sEnded = IF cut THEN e ELSE @,
                        !.epoch = IF cut /\ ld.ended = 0 THEN @ + 1 ELSE @])

Crash(up) == used.crash < MaxCrash /\ Set(Crashed([S EXCEPT !.used.crash = @ + 1], up))

\* ... or dies inside finalize, between the receipt (60) and the transcript (61).  finalize is about to run
\* when one of its callers has just come back from the await before it.
AboutToFinalize(s) ==
    \/ \E k \in Callers : s.dn[k].pc = "d_finish" /\ Snap(s).ok /\ Snap(s).ended # 0 /\ ~(Busy(s) /\ s.live)
    \/ s.rc.pc = "r_finish"
    \/ s.fz.pc = "fz_finish" /\ Snap(s).ended = s.fz.at /\ ~Busy(s)
    \/ s.stp.pc = "st_notes" /\ StopGuard(s) /\ s.mDoc = "none"
    \/ s.rc.pc = "idle" /\ Load(s).ok /\ Load(s).doc = "open" /\ Load(s).ended # 0 /\ ~(Busy(s) /\ s.live)
                        /\ s.now >= Load(s).ended
TornFinalize(up) ==
    /\ ~InPurge /\ used.torn < MaxTorn /\ AboutToFinalize(S) /\ WouldWrite(S)
    /\ Set(Crashed([S EXCEPT !.receipt = "finalized", !.rEpoch = Snap(S).ended, !.fEpoch = Snap(S).ended,
                              !.used.torn = @ + 1], up))

\* A day passes for the oldest stop whose deadline has not passed.  No recording session, together
\* with its final pass, lasts a day: time only passes a deadline while nothing is being recorded.
Tick == /\ ~InPurge /\ now < epoch /\ phase = "idle" /\ Set([S EXCEPT !.now = @ + 1])

\* A writer that still holds a copy of the meeting saves it (title job, speaker naming, a late patch).
LateStoreSave ==
    /\ ~InPurge /\ AllowLate /\ folder # "ok" /\ ~SaveThrows(S)
    /\ Set(StoreSave(S, sEnded, sRet, sStatus, sDoc))

\* ... or indexes it (IndexService.liveChanged with a stale Meeting, an embedding batch finishing late).
LateIndexWrite == /\ ~InPurge /\ AllowLate /\ ~idx /\ Set(IndexWrite(S))

\* A question scoped to the meeting is answered while its transcript is still reachable.
AskScoped == /\ ~InPurge /\ AllowAsk /\ ~conv /\ receipt # "purged" /\ (folder = "ok" \/ idx) /\ Set([S EXCEPT !.conv = TRUE])

\* --- the app's own steps ---

StopNotesDone     == ~InPurge /\ stp.pc = "st_notes" /\ \E ok \in FinOK(S) : Set(StopAfterNotes(S, ok))
StopIndexReturned == ~InPurge /\ stp.pc = "st_index" /\ Set(StopEnd(S))

FinishValues == IF FinishMayFail THEN {TRUE, FALSE} ELSE {TRUE}

\* LocalAPI.swift:144-146
PluginFinalizeRun ==
    /\ ~InPurge /\ fz.pc = "fz_finish"
    /\ \E finished \in FinishValues, ok \in FinOK(S) :
          Set(IF finished /\ Snap(S).ended = fz.at /\ ~Busy(S)
              THEN (IF Fails(S, ok) THEN [Failed(S) EXCEPT !.fz = IdleFz] ELSE [Finalize(S) EXCEPT !.fz = IdleFz])
              ELSE [S EXCEPT !.fz = IdleFz])

RecoverFires         == ~InPurge /\ rc.pc = "idle" /\ \E ok2 \in FinOK(S) : Set(RecoverStart(S, ok2))
RecoverFinishDone    == ~InPurge /\ rc.pc = "r_finish"
                        /\ \E f \in FinishValues, ok1 \in FinOK(S), ok2 \in FinOK(S) : Set(RecoverAfterFinish(S, f, ok1, ok2))
RecoverIndexReturned == ~InPurge /\ rc.pc = "r_finIndex" /\ \E ok2 \in FinOK(S) : Set(RecoverLoop2(S, ok2))
RecoverDocReturned   == ~InPurge /\ rc.pc = "r_docIndex" /\ Set(RecoverLoop3(S))

DoneFinishDone(k)    == ~InPurge /\ dn[k].pc = "d_finish"   /\ \E ok \in FinOK(S) : Set(DoneAfterFinish(S, k, ok))
DoneIndexReturned(k) == ~InPurge /\ dn[k].pc = "d_finIndex" /\ Set(DoneAfterFinalize(S, k))
\* MeetingRetention.swift:108: hop to the IndexService actor
DoneClearReturned(k) ==
    /\ ~InPurge /\ dn[k].pc = "d_clear"
    /\ Set(IF indexUp /\ ~MutPurgeSkipsIndex THEN [S EXCEPT !.dn[k].pc = "d_idxWait"] ELSE P1(S, k))
\* IndexService.swift:195-196
IndexPurgeFence(k) == ~InPurge /\ dn[k].pc = "d_idxWait" /\ Set([S EXCEPT !.fence = TRUE, !.dn[k].pc = "d_idxMid"])
\* IndexService.swift:197 -> SearchIndexVectors.swift:85-102 (may throw)
IndexPurgeRows(k) ==
    /\ ~InPurge /\ dn[k].pc = "d_idxMid"
    /\ \E ok \in (IF used.idxThrow < MaxIndexThrow THEN {TRUE, FALSE} ELSE {TRUE}) :
          Set(IF ok THEN [S EXCEPT !.idx = FALSE, !.dn[k].pc = "d_idxDone",
                                   !.hist.t1 = @ \/ (idx /\ receipt # "purging")]
              ELSE DoneExit([S EXCEPT !.used.idxThrow = @ + 1], k))
\* MeetingRetention.swift:109: back on the main actor, RetentionStore.purge begins
DonePurgeBegin(k) == ~InPurge /\ dn[k].pc = "d_idxDone" /\ Set(P1(S, k))
DonePurgeConvs(k)  == dn[k].pc = "d_p2" /\ Set(P2(S, k))
DonePurgeFolder(k) == dn[k].pc = "d_p3" /\ Set(P3(S, k))
DonePurgeMark(k)   == dn[k].pc = "d_p4" /\ Set(P4(S, k))

\* MeetingIndexer.sync (43-69), run at launch, whenever a recording ends (SearchHookup.swift:61-68) and, in the
\* current code, when a recording is moved to the Trash (AppModel.swift:767).
\* A meeting that is not "live" loses its rows (50-52); a listed, indexable one is (re)indexed.  At edcaebae
\* "live" was "listed", and the list has a stand-in for every receipt; now it also needs its transcript.json.
IndexerSync ==
    /\ ~InPurge /\ indexUp
    /\ LET ld     == Load(S)
           listed == ld.ok \/ receipt # "none"
           drop   == IF FixSyncDropsTrashed THEN ~(listed /\ folder # "gone") ELSE ~listed
       IN IF drop THEN idx /\ Set([S EXCEPT !.idx = FALSE])
          ELSE /\ ld.ok /\ ld.ret \notin {"purging", "purged"} /\ ld.status \notin {"recording", "finalizing"} /\ ~idx
               /\ Set(IndexWrite(S))

Init ==
    /\ receipt = "none" /\ rEpoch = 0 /\ fEpoch = 0 /\ folder = "ok" /\ sEnded = 0 /\ sRet = "nil" /\ sStatus = "recording"
    /\ sDoc = DocInit
    /\ live = TRUE /\ mEnded = 0 /\ mRet = "nil" /\ mStatus = "recording" /\ mDoc = DocInit /\ phase = "recording"
    /\ idx = IndexUpInit /\ fence = FALSE /\ indexUp = IndexUpInit /\ conv = FALSE /\ now = 0 /\ epoch = 0
    /\ dn = [k \in Callers |-> IdleDone] /\ working = FALSE /\ rc = IdleRc /\ fz = IdleFz /\ stp = IdleStp
    /\ used = [resume |-> 0, crash |-> 0, trash |-> 0, corrupt |-> 0, done |-> 0, finalize |-> 0, idxThrow |-> 0,
               openDoc |-> 0, undo |-> 0, finFail |-> 0, torn |-> 0]
    /\ hist = [t1 |-> FALSE, t7 |-> FALSE, t9 |-> FALSE] /\ ever = FALSE

Next ==
    \/ Stop \/ Resume \/ UserDone \/ PluginFinalize \/ OpenDoc \/ UndoFinalize \/ Trash \/ Displace \/ Corrupt \/ Tick
    \/ \E up \in (IF IndexMayFail THEN {TRUE, FALSE} ELSE {TRUE}) : Crash(up) \/ TornFinalize(up)
    \/ LateStoreSave \/ LateIndexWrite \/ AskScoped
    \/ StopNotesDone \/ StopIndexReturned \/ PluginFinalizeRun
    \/ RecoverFires \/ RecoverFinishDone \/ RecoverIndexReturned \/ RecoverDocReturned
    \/ \E k \in Callers : DoneFinishDone(k) \/ DoneIndexReturned(k) \/ DoneClearReturned(k)
                          \/ IndexPurgeFence(k) \/ IndexPurgeRows(k) \/ DonePurgeBegin(k)
                          \/ DonePurgeConvs(k) \/ DonePurgeFolder(k) \/ DonePurgeMark(k)
    \/ IndexerSync

\* The app keeps running, awaits return, and the 60 s loop keeps firing.
Fairness ==
    /\ WF_vars(StopNotesDone) /\ WF_vars(StopIndexReturned) /\ WF_vars(PluginFinalizeRun)
    /\ WF_vars(RecoverFires) /\ WF_vars(RecoverFinishDone) /\ WF_vars(RecoverIndexReturned)
    /\ WF_vars(RecoverDocReturned)
    /\ WF_vars(IndexerSync)
    /\ \A k \in Callers :
          /\ WF_vars(DoneFinishDone(k)) /\ WF_vars(DoneIndexReturned(k)) /\ WF_vars(DoneClearReturned(k))
          /\ WF_vars(IndexPurgeFence(k)) /\ WF_vars(IndexPurgeRows(k)) /\ WF_vars(DonePurgeBegin(k))
          /\ WF_vars(DonePurgeConvs(k)) /\ WF_vars(DonePurgeFolder(k)) /\ WF_vars(DonePurgeMark(k))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

\* T1: the purge machinery deletes nothing unless the receipt on disk says "purging" at that moment.
\* (The user's Move to Trash and the indexer dropping rows of a vanished meeting are not purges.)
T1_JournalFirst == ~hist.t1

\* T2: purged means gone.
T2_PurgedMeansGone == receipt = "purged" => (folder = "gone" /\ ~idx /\ ~conv)

\* T3: once the receipt has been purging or purged, a deleted folder is never recreated, and index
\* rows never reappear after the index purge has set its fence.
T3_NoResurrection ==
    [][ ever => ((folder = "gone" => folder' = "gone") /\ ((fence /\ ~idx) => ~idx')) ]_vars

\* T4: the receipt never goes backwards.
T4_NoRegression ==
    [][ (receipt = "purging" => receipt' \in {"purging", "purged"}) /\ (receipt = "purged" => receipt' = "purged") ]_vars

\* T5: once every deadline has passed, the raw material is eventually gone and the receipt, if the
\* meeting ever got one, says purged.
Late  == epoch >= 1 /\ now >= epoch
Clean == folder = "gone" /\ ~idx /\ ~conv
T5_EventuallyPurged == Late ~> (Clean /\ receipt \in {"purged", "none"})

\* T7: a purge never starts while the transcript on disk records a stop that the note does not hold.
\* (Without a plugin document in the model that is exactly "on a receipt older than the meeting's last stop",
\* T7 as it was stated at edcaebae.)
T7_PurgeOnlyFinalizedSession == ~hist.t7

\* T8 (added for the current code): the index rows of a meeting whose folder is gone do not stay findable.
\* (Before any deadline: this is about a meeting moved to the Trash, not about the purge.)
T8_TrashedLeavesIndex == (folder = "gone" /\ indexUp) ~> (~idx \/ ~indexUp \/ folder # "gone")

\* T9 (added with the third round): a purge the 60 s loop starts (not one the user asked for with Done) never
\* starts before the 24 h deadline of the meeting's last stop.  This is what the skip at 146 is for.
T9_LoopPurgesOnTheLastStopsClock == ~hist.t9

\* T6: a meeting being recorded is never purging or purged.
T6_NotPurgedWhileRecording == ~(phase = "recording" /\ receipt \in {"purging", "purged"})

TypeOK ==
    /\ receipt \in {"none", "finalized", "purging", "purged"}
    /\ folder \in {"ok", "unreadable", "gone"}
    /\ sRet \in {"nil", "live", "finalized"} /\ mRet \in {"nil", "live", "finalized", "purged"}
    /\ sDoc \in {"none", "open", "final"} /\ mDoc \in {"none", "open", "final"}
    /\ phase \in {"recording", "finalizing", "idle"}
    /\ now <= epoch
=============================================================================
