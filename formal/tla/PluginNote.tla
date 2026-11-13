--------------------------- MODULE PluginNote ---------------------------
(***************************************************************************)
(* MACHINE 5: the Obsidian plugin's sync lane and finalize for ONE note,   *)
(* with the WorkScribe app as the other party over the local HTTP API.     *)
(*                                                                         *)
(* The spec describes TWO versions of the plugin, selected by constants:   *)
(*   "found": obsidian-plugin/src/ui/note-editor.ts as it was in the       *)
(*            working tree on 2026-11-12 (all Fix* FALSE)                  *)
(*   "fixed": the same file after the fixes of this round (Fix* TRUE)      *)
(* Line numbers in the comments are the FIXED file's; PluginNote.md has    *)
(* both columns.                                                           *)
(*                                                                         *)
(*   obsidian-plugin/src/ui/note-editor.ts   session, changed, queue,      *)
(*     flush, diskChanged, checkFinalized, markFinalized, finalize, purge, *)
(*     openInner, the rename handler                                       *)
(*   obsidian-plugin/src/lib/finalize-merge.ts  (fixed only)               *)
(*   obsidian-plugin/src/main.ts             handleEvent (purged, notes),  *)
(*     the connection callback                                             *)
(*   Sources/WorkScribe/LocalAPI.swift       openDocument, syncDocument,   *)
(*     finalizeDocument routes (read only)                                 *)
(*   Sources/WorkScribe/MeetingRetention.swift  finalize, done             *)
(*   Sources/WorkScribeCore/Vault/VaultStore.swift  finalizeDocument       *)
(*                                                                         *)
(* JavaScript is single threaded: a function runs uninterrupted until an   *)
(* `await` that really waits (a file write, an HTTP response).  Promise    *)
(* continuations that are already resolved run before any other event, so  *)
(* "the flush body ends, flush's tail runs, finalize continues, the next   *)
(* queued flush body starts" is ONE step here.                             *)
(*                                                                         *)
(* Text is a set of tokens: each keystroke adds one new token, nothing is  *)
(* ever deleted by the person, so "lost" means "a typed token is absent".  *)
(* `ai` says whether the finalize insertions are in that copy of the text. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    \* --- bounds
    MaxType,             \* keystrokes (each a new token)
    MaxPress,            \* presses of Finalize (Cmd+Return or the button)
    MaxFail,             \* requests that end in an error for the plugin (no answer, answer lost, 5xx)
    MaxDrop,             \* times the /v1/events connection drops
    MaxReopen,           \* NoteEditor.open() on a note that already has a session (jot, live view, resume)
    MaxExternal,         \* renames and outside modifications of the file
    \* --- scenario
    Meeting,             \* TRUE: a meeting note (frontmatter `workscribe`).  FALSE: an ordinary note
    ViewOpen,            \* an editor is open on the note
    AppFinalizes,        \* the app may finalize on its own (23-hour mark, Done)
    AppPurges,           \* the app may purge a finalized meeting
    SlowIndex,           \* the finalize route answers in a later step than its commit (indexFinalNote suspends)
    Polls,               \* the 2-second checkFinalized poll runs
    \* --- the fixes as written
    FixOneFinalize,      \* finalize(): one run per meeting at a time; a second press joins it
    FixKeepTyped,        \* the finalize answer is merged into what the editor holds now, never replaces it
    FixMeetingOnly,      \* sessions the editor made for ordinary notes are never queued or polled
    FixRetry,            \* a failed sync is retried while the app is reachable (409: adopt the revision, retry)
    FixFence,            \* a flush or open() stops when its session was replaced or purged while it waited
    FixLearnPurge,       \* a 404 on sync, and the poll, drop the session of a meeting the app has purged
    FixReopenEditor,     \* open() on a note with an open editor takes the editor's text, not the file's
    FixDropDirty,        \* a finalized note is no longer dirty (flush, the poll, the conflict branch)
    \* --- mutations
    MutNoCAS,            \* the app accepts a PATCH whatever its revision
    MutGuardNeverCleared \* FixOneFinalize without clearing its guard when a run fails

Calls == 1..MaxPress

VARIABLES
    typed,               \* every token the person typed
    ed, edBase, disk,    \* editor text, the file text the editor last loaded or saved, the file
    sess,                \* the plugin's session for this note: "none" | "meeting" | "ordinary"
    renamed,             \* an ordinary session whose id (its first path) is no longer its path
    sdoc,                \* session.document: [t, rev, fin]
    dirty, timer, ledger,\* dirty.has(id), a queue() timer is pending, documentLedgers[id] exists
    ops, op,             \* flush calls waiting for the lane; the flush body that is running
    patch, late,         \* the PATCH in flight; a PATCH the plugin gave up on that may still arrive
    fin, hd,             \* finalize() calls; the app's handler for each one's request
    finalizing, finBusy, \* the plugin's `finalizing` set; the fix's "a run is in flight" guard
    conn,                \* "online" | "offline" (the events connection)
    adoc, aphase,        \* the app's NoteDocument [has, t, rev, fin]; "ended" | "purged"
    apassing,            \* NoteEnhancementScheduler is in a final pass for the finalize route
    conflict, apath,     \* a " (WorkScribe).md" sibling exists; the path the app returns
    evFin, evPurged,     \* events in transit: notes{documentFinalized}, meeting.purged
    knowsPurged,         \* the plugin handled the purge of this meeting
    rpo, poll,           \* open() in flight; the poll's GET in flight
    used, hist

vars == <<typed, ed, edBase, disk, sess, renamed, sdoc, dirty, timer, ledger, ops, op, patch, late, fin, hd,
          finalizing, finBusy, conn, adoc, aphase, apassing, conflict, apath, evFin, evPurged, knowsPurged,
          rpo, poll, used, hist>>

S == [typed |-> typed, ed |-> ed, edBase |-> edBase, disk |-> disk, sess |-> sess, renamed |-> renamed,
      sdoc |-> sdoc, dirty |-> dirty, timer |-> timer, ledger |-> ledger, ops |-> ops, op |-> op,
      patch |-> patch, late |-> late, fin |-> fin, hd |-> hd, finalizing |-> finalizing, finBusy |-> finBusy,
      conn |-> conn, adoc |-> adoc, aphase |-> aphase, apassing |-> apassing, conflict |-> conflict,
      apath |-> apath, evFin |-> evFin, evPurged |-> evPurged, knowsPurged |-> knowsPurged, rpo |-> rpo,
      poll |-> poll, used |-> used, hist |-> hist]

Set(n) ==
    /\ typed' = n.typed /\ ed' = n.ed /\ edBase' = n.edBase /\ disk' = n.disk /\ sess' = n.sess
    /\ renamed' = n.renamed /\ sdoc' = n.sdoc /\ dirty' = n.dirty /\ timer' = n.timer /\ ledger' = n.ledger
    /\ ops' = n.ops /\ op' = n.op /\ patch' = n.patch /\ late' = n.late /\ fin' = n.fin /\ hd' = n.hd
    /\ finalizing' = n.finalizing /\ finBusy' = n.finBusy /\ conn' = n.conn /\ adoc' = n.adoc
    /\ aphase' = n.aphase /\ apassing' = n.apassing /\ conflict' = n.conflict /\ apath' = n.apath
    /\ evFin' = n.evFin /\ evPurged' = n.evPurged /\ knowsPurged' = n.knowsPurged /\ rpo' = n.rpo
    /\ poll' = n.poll /\ used' = n.used /\ hist' = n.hist

NoOp    == [pc |-> "idle", owner |-> 0, kind |-> "none", t |-> {}, rev |-> 0, stale |-> FALSE, orphan |-> FALSE]
NoPatch == [st |-> "none", t |-> {}, rev |-> 0]
NoLate  == [has |-> FALSE, t |-> {}, rev |-> 0]
NoCall  == [pc |-> "idle", t |-> {}, path |-> "note"]
NoHd    == [st |-> "none", res |-> "ok", t |-> {}, path |-> "note"]
NoRpo   == [pc |-> "idle", t |-> {}, rev |-> 0, fin |-> FALSE]
NoPoll  == [pc |-> "idle", kind |-> "none", orphan |-> FALSE]

Online(s) == s.conn = "online"

-----------------------------------------------------------------------------
\* The plugin

\* A session's document is assigned a new object: a flush that captured the old one will see `s.document !== before`.
Reassigned(s) == [s EXCEPT !.op.stale = IF s.op.pc # "idle" /\ ~s.op.orphan THEN TRUE ELSE @]

\* The session object itself is replaced (open) or removed (purge): the running flush keeps the old object.
Orphaned(s) == [s EXCEPT !.op.orphan = IF s.op.pc # "idle" THEN TRUE ELSE @,
                         !.poll.orphan = IF s.poll.pc # "idle" THEN TRUE ELSE @]

\* queue(id), 349-361: mark dirty, (re)arm the 650 ms timer, copy the document into the saved ledger.
Queue(s) == [s EXCEPT !.dirty = TRUE, !.timer = TRUE, !.ledger = @ \/ (s.sess # "none")]

\* What purge(id) leaves, 645-652 (called from main.ts meetingPurged, 313-326).  The session is deleted; an open editor then gets a
\* fresh session keyed by its path the next time session(state) runs (refresh, in the same step).  A timer
\* left armed for the meeting id only finds dirty.has(id) false, so it is dropped here.
PurgeLocal(s) ==
    Orphaned([s EXCEPT !.sess = IF ViewOpen THEN "ordinary" ELSE "none", !.renamed = FALSE,
                       !.sdoc = [t |-> s.ed.t, rev |-> 0, fin |-> FALSE],
                       !.ledger = FALSE, !.dirty = FALSE, !.timer = FALSE, !.knowsPurged = TRUE])

RECURSIVE RunLane(_)

\* What the caller of flush() does when its flush settles.
\*   a finalize() call c, 517-524: on an error it rejects; otherwise it takes `before`, marks the meeting as
\*   finalizing and sends POST finalize.
Continue(s, o, threw) ==
    IF o \notin Calls THEN s                                                     \* the timer: showError at most
    ELSE IF threw \/ s.sess # "meeting"
         THEN [s EXCEPT !.fin[o].pc = "done", !.finBusy = IF MutGuardNeverCleared THEN @ ELSE FALSE]
         ELSE [s EXCEPT !.fin[o].pc = "req", !.finalizing = TRUE, !.hd[o].st = "sent",
                        !.hist.twoFinalizes = @ \/ (\E c \in Calls \ {o} : s.fin[c].pc = "req")]

\* The flush body is over (it returned, or threw).  flush's own tail, 422-432, then the caller, then the next
\* flush body in the lane.
OpDone(s, o, threw) ==
    LET s0 == [s EXCEPT !.op = NoOp]
        s1 == IF ~(s0.dirty /\ Online(s0)) THEN s0
              ELSE IF ~threw THEN Queue(s0)                                      \* 432, the tail: queue(id)
              ELSE IF FixRetry THEN [s0 EXCEPT !.timer = TRUE]                   \* 424-429, the catch: arm(id, backoff)
              ELSE s0
    IN RunLane(Continue(s1, o, threw))

\* 392-399: the save through Obsidian is over; send the snapshot taken before it, or give up.
AfterSave(s) ==
    IF FixFence /\ s.op.orphan THEN OpDone(s, s.op.owner, FALSE)                 \* 392: gone()
    ELSE IF ~Online(s) THEN OpDone(s, s.op.owner, FALSE)                         \* 392
    ELSE [s EXCEPT !.op.pc = "sync", !.patch = [st |-> "sent", t |-> s.op.t, rev |-> s.op.rev],
                   !.hist.sentOrdinary = @ \/ (s.op.kind = "ordinary"),
                   !.hist.sentAfterPurge = @ \/ (s.op.kind = "meeting" /\ s.knowsPurged)]

\* 376-391: the body of flush, up to its first real wait.
BodyStart(s, o) ==
    IF ~s.dirty THEN OpDone(s, o, FALSE)                                         \* 377
    ELSE IF s.sess = "none" \/ s.sdoc.fin \/ (FixMeetingOnly /\ s.sess = "ordinary")      \* 378-381
         THEN OpDone(IF FixDropDirty THEN [s EXCEPT !.dirty = FALSE] ELSE s, o, FALSE)
    ELSE LET s1 == [s EXCEPT !.op = [pc |-> "save", owner |-> o, kind |-> s.sess, t |-> s.sdoc.t,
                                     rev |-> s.sdoc.rev, stale |-> FALSE, orphan |-> FALSE]]
         IN IF ViewOpen THEN s1 ELSE AfterSave(s1)                               \* 388-391: await v.save()

RunLane(s) ==
    IF s.op.pc # "idle" \/ s.ops = <<>> THEN s
    ELSE BodyStart([s EXCEPT !.ops = Tail(@)], Head(s.ops))

\* flush(id), 373-433
Flush(s, o) == RunLane([s EXCEPT !.timer = FALSE, !.ops = Append(@, o)])

\* changed(view, blocks), 340-348: the editor's text changed.
Changed(s) ==
    IF s.sess = "none" \/ s.sdoc.fin THEN s                                      \* 342
    ELSE LET s1 == Reassigned([s EXCEPT !.sdoc.t = s.ed.t])
         IN IF s.sess = "meeting" \/ (s.renamed /\ ~FixMeetingOnly) THEN Queue(s1) ELSE s1   \* 344

-----------------------------------------------------------------------------
\* The app

\* PATCH document, LocalAPI.swift 137-159.  An authoritative full snapshot, compare-and-swap on the revision.
AppPatched(s, t, rev) ==
    IF ~Meeting \/ ~s.adoc.has THEN [s |-> s, res |-> "e404"]                    \* 141
    ELSE IF s.adoc.fin \/ (~MutNoCAS /\ rev # s.adoc.rev) THEN [s |-> s, res |-> "e409"]   \* 145
    ELSE [s |-> [s EXCEPT !.adoc = [has |-> TRUE, t |-> t, rev |-> s.adoc.rev + 1, fin |-> FALSE],
                          !.hist.rollback = @ \/ ~(s.adoc.t \subseteq t)],
          res |-> "ok"]

\* MeetingRetention.finalize 31-65 with VaultStore.finalizeDocument 284-306, up to `await index.indexFinalNote`.
\* rebase = allowRebase (Done and the 23-hour recovery): insert into whatever the file holds now.
Commit(s, rebase) ==
    LET pre  == [t |-> s.adoc.t, ai |-> FALSE]
        post == [t |-> s.adoc.t, ai |-> TRUE]
        done(x) == [x EXCEPT !.adoc.fin = TRUE, !.evFin = Online(x)]             \* 58-63: notesChanged publishes
    IN IF s.aphase = "purged" \/ ~s.adoc.has THEN [s |-> s, ok |-> FALSE]         \* 34-36, then a null document
       ELSE IF s.adoc.fin \/ s.disk = post THEN [s |-> done(s), ok |-> TRUE]     \* 288, 293: idempotent
       ELSE IF s.disk = pre THEN [s |-> done([s EXCEPT !.disk = post, !.apath = "note"]), ok |-> TRUE]   \* 304
       ELSE IF rebase THEN [s |-> done([s EXCEPT !.disk.ai = TRUE, !.apath = "note"]), ok |-> TRUE]      \* 302
       ELSE IF s.conflict THEN [s |-> s, ok |-> FALSE]                           \* 298: Failure.changed
       ELSE [s |-> done([s EXCEPT !.conflict = TRUE, !.apath = "conflict"]), ok |-> TRUE]                \* 296-300

-----------------------------------------------------------------------------
\* Actions: the person and Obsidian

\* A keystroke.  editor-extension.ts 150-155 calls changed() in the same step.
Type ==
    /\ ViewOpen /\ Cardinality(typed) < MaxType
    /\ LET k == Cardinality(typed) + 1 IN
       Set(Changed([S EXCEPT !.typed = @ \cup {k}, !.ed.t = @ \cup {k}]))

\* Obsidian writes the editor to the file on its own (about two seconds after an edit).
Autosave == ViewOpen /\ ed # edBase /\ Set([S EXCEPT !.disk = ed, !.edBase = ed])

\* Obsidian loads a file that changed underneath an editor with nothing unsaved.  It is a document change
\* like any other, so changed() runs.  (What Obsidian does when the editor does have unsaved text is not
\* modelled as a merge: its next save overwrites the file.)
Reload ==
    /\ ViewOpen /\ ed = edBase /\ disk # edBase
    /\ Set(Changed([S EXCEPT !.ed = disk, !.edBase = disk]))

\* Finalize: the keydown handler at 64, or the button at 298.
Press ==
    /\ used.press < MaxPress /\ Meeting /\ ViewOpen
    /\ sess = "meeting" /\ ~sdoc.fin
    /\ ~(FixOneFinalize /\ finBusy)                                              \* 509-511: joins the run in flight
    /\ LET c == used.press + 1 IN
       Set(Flush([S EXCEPT !.used.press = c, !.fin[c].pc = "flush",
                           !.finBusy = IF FixOneFinalize THEN TRUE ELSE @], c))  \* 512-513, 517

\* open(id) on a note that has a session already: append 638 (a jot), main.ts activateLiveView, a resume.
ReopenSend ==
    /\ used.reopen < MaxReopen /\ Meeting /\ sess = "meeting" /\ rpo.pc = "idle"
    /\ Set([S EXCEPT !.used.reopen = @ + 1, !.rpo.pc = "req"])

\* The file is renamed (the handler at 82-87).
Rename ==
    /\ used.ext < MaxExternal /\ sess # "none"
    /\ LET s1 == [S EXCEPT !.used.ext = @ + 1, !.renamed = (sess = "ordinary") \/ @] IN
       Set(IF sess = "meeting" \/ ~FixMeetingOnly THEN Queue(s1) ELSE s1)        \* 85, 351

\* Something else writes the file (a sync tool, another program): token 0.  diskChanged, 439-450.
ExternalModify ==
    /\ used.ext < MaxExternal /\ 0 \notin disk.t
    /\ LET s1 == [S EXCEPT !.used.ext = @ + 1, !.disk.t = @ \cup {0}] IN
       Set(IF s1.sess = "none" \/ s1.sdoc.fin \/ ViewOpen THEN s1                \* 442, 446-447
           ELSE LET s2 == Reassigned([s1 EXCEPT !.sdoc.t = s1.disk.t]) IN
                IF s1.sess = "meeting" \/ ~FixMeetingOnly THEN Queue(s2) ELSE s2)   \* 448-449, 351

-----------------------------------------------------------------------------
\* Actions: the plugin

\* The timer of queue() or of a retry fires: flush(id), 365.
TimerFires == timer /\ Set(Flush(S, 0))

\* `await v.save()` is over, 390.
SaveDone == op.pc = "save" /\ Set(AfterSave([S EXCEPT !.disk = ed, !.edBase = ed]))

\* The PATCH is answered, 399-420.
SyncResponse ==
    /\ op.pc = "sync" /\ patch.st \in {"ok", "e409", "e404", "err"}
    /\ LET s0 == [S EXCEPT !.patch = NoPatch]
           o  == op.owner IN
       IF FixFence /\ op.orphan THEN Set(OpDone(s0, o, FALSE))                   \* 400, 406: gone()
       ELSE CASE patch.st = "ok" ->
                   \* 401-404.  The writes go to the session object the flush captured.
                   LET s1 == IF ~op.stale
                             THEN [s0 EXCEPT !.sdoc = IF op.orphan THEN @ ELSE [t |-> op.t, rev |-> patch.rev, fin |-> FALSE],
                                             !.dirty = FALSE, !.ledger = TRUE]
                             ELSE [s0 EXCEPT !.sdoc.rev = IF op.orphan THEN @ ELSE patch.rev, !.ledger = TRUE]
                   IN Set([s1 EXCEPT !.op.pc = "store"])                         \* 404: await saveSettings()
              [] patch.st = "e409" ->                                            \* 411: await openDocument(id)
                   Set([s0 EXCEPT !.op.pc = "open409",
                                  !.hist.sentAfterPurge = @ \/ (op.kind = "meeting" /\ knowsPurged)])
              [] patch.st = "e404" ->
                   IF FixLearnPurge /\ op.kind = "meeting"
                   THEN Set([s0 EXCEPT !.op.pc = "gone"])                        \* 418: await purgedMeanwhile(id)
                   ELSE Set(OpDone(s0, o, TRUE))
              [] patch.st = "err" -> Set(OpDone(s0, o, TRUE))

\* `await this.p.saveSettings()` is over, 404.
StoreDone == op.pc = "store" /\ Set(OpDone(S, op.owner, FALSE))

\* POST document after a 409, 411-414.  The app's answer and its arrival are one step.
Open409Response ==
    /\ op.pc = "open409"
    /\ \/ /\ used.fail < MaxFail                                                 \* no answer
          /\ Set(OpDone([S EXCEPT !.used.fail = @ + 1], op.owner, TRUE))
       \/ IF FixFence /\ op.orphan THEN Set(OpDone(S, op.owner, FALSE))          \* 412: gone()
          ELSE IF aphase = "purged" \/ ~adoc.has THEN Set(OpDone(S, op.owner, TRUE))   \* 409 from LocalAPI 132
          ELSE IF adoc.fin
               THEN Set(OpDone(Reassigned([S EXCEPT !.sdoc = IF op.orphan THEN @ ELSE [t |-> adoc.t, rev |-> adoc.rev, fin |-> TRUE],
                                                    !.dirty = FALSE]), op.owner, FALSE))            \* 413
               ELSE Set(OpDone(Reassigned([S EXCEPT !.sdoc.rev = IF op.orphan THEN @ ELSE adoc.rev]),
                               op.owner, TRUE))                                                    \* 414, 419

\* purgedMeanwhile(id), 453-459 (fixed only): the app answered 404 to a sync; ask what became of the meeting.
GoneResponse ==
    /\ op.pc = "gone"
    /\ IF aphase = "purged" THEN Set(OpDone(PurgeLocal(S), op.owner, FALSE))
       ELSE Set(OpDone(S, op.owner, TRUE))

\* The finalize request is answered, 524.
FinalizeResponse(c) ==
    /\ fin[c].pc = "req"
    /\ \/ /\ hd[c].st = "done" /\ hd[c].res = "ok"
          /\ Set([S EXCEPT !.finalizing = FALSE, !.fin[c] = [pc |-> "read", t |-> hd[c].t, path |-> hd[c].path]])   \* 526
       \/ /\ \/ hd[c].st = "done" /\ hd[c].res = "err"
             \/ used.fail < MaxFail                                              \* no answer; the app carries on
          /\ Set([S EXCEPT !.finalizing = FALSE, !.fin[c].pc = "done",
                           !.finBusy = IF MutGuardNeverCleared THEN @ ELSE FALSE,
                           !.used.fail = IF hd[c].st = "done" /\ hd[c].res = "err" THEN @ ELSE @ + 1])

\* `await adapter.read(file)` is over, 526-565: apply the answer.
FinalizeRead(c) ==
    /\ fin[c].pc = "read"
    /\ IF fin[c].path = "conflict"
       THEN \* 527-534: the finalized version is beside the note; the editor is left alone.
            Set(Reassigned([S EXCEPT !.fin[c].pc = "done", !.finBusy = FALSE,
                                     !.sdoc = IF sess = "meeting" THEN [t |-> fin[c].t, rev |-> @.rev, fin |-> TRUE] ELSE @,
                                     !.dirty = IF FixDropDirty THEN FALSE ELSE @,
                                     !.timer = IF FixDropDirty THEN FALSE ELSE @]))
       ELSE IF ViewOpen
       THEN \* 535-564.  Found: whatever the editor held, it ends up equal to the file as just read.
            \* Fixed: the insertions are added to what the editor holds (finalize-merge.ts).
            LET e == IF FixKeepTyped THEN [ed EXCEPT !.ai = TRUE] ELSE disk IN
            Set(Reassigned([S EXCEPT !.ed = e, !.sdoc = [t |-> e.t, rev |-> @.rev, fin |-> TRUE],
                                     !.fin[c].pc = "save"]))                     \* 566: await leaf.view.save()
       ELSE \* 565: no editor; the session takes the file's text.
            Set(Reassigned([S EXCEPT !.sdoc = IF sess = "meeting" THEN [t |-> disk.t, rev |-> @.rev, fin |-> TRUE] ELSE @,
                                     !.dirty = FALSE, !.timer = FALSE, !.fin[c].pc = "done", !.finBusy = FALSE]))

\* `await leaf.view.save()` is over, 566-567.
FinalizeSave(c) ==
    /\ fin[c].pc = "save"
    /\ Set([S EXCEPT !.disk = ed, !.edBase = ed, !.dirty = FALSE, !.timer = FALSE,
                     !.fin[c].pc = "done", !.finBusy = FALSE])

\* notes{documentFinalized}: main.ts 278 -> markFinalized, 496-503.
EvFinalized ==
    /\ evFin /\ conn = "online"
    /\ IF finalizing \/ sess # "meeting" THEN Set([S EXCEPT !.evFin = FALSE])    \* 497-498
       ELSE Set(Reassigned([S EXCEPT !.evFin = FALSE, !.sdoc.fin = TRUE, !.dirty = FALSE, !.timer = FALSE,
                                     !.ledger = FALSE]))

\* meeting.purged: main.ts 279-282 -> meetingPurged 313-326 -> purge, 645-652.
EvPurged ==
    /\ evPurged /\ ~evFin /\ conn = "online"
    /\ Set(PurgeLocal([S EXCEPT !.evPurged = FALSE]))

\* The connection callback, main.ts 56-60, and the subscriber at note-editor.ts 75.
ConnDrop ==
    /\ conn = "online" /\ used.drop < MaxDrop
    /\ Set([S EXCEPT !.conn = "offline", !.used.drop = @ + 1, !.evFin = FALSE, !.evPurged = FALSE])
ConnUp ==
    /\ conn = "offline"
    /\ LET s1 == [S EXCEPT !.conn = "online"] IN Set(IF dirty THEN Queue(s1) ELSE s1)

\* checkFinalized, 460-480 (the interval at 88-90): every two seconds, for each session that is not finalized,
\* dirty or finalizing.  One round at a time.
PollSend ==
    /\ Polls /\ poll.pc = "idle" /\ conn = "online"
    /\ sess # "none" /\ ~sdoc.fin /\ ~dirty /\ ~finalizing
    /\ sess = "meeting" \/ ~FixMeetingOnly                                       \* 465
    /\ Set([S EXCEPT !.poll = [pc |-> "req", kind |-> sess, orphan |-> FALSE],
                     !.hist.askedOrdinary = @ \/ (sess = "ordinary")])
PollResponse ==
    /\ poll.pc = "req"
    /\ LET s0 == [S EXCEPT !.poll = NoPoll] IN
       IF poll.kind # "meeting" THEN Set(s0)                                     \* an ordinary note: 404
       ELSE IF aphase = "purged" THEN Set(IF FixLearnPurge THEN PurgeLocal(s0) ELSE s0)   \* 468
       ELSE IF ~(adoc.has /\ adoc.fin) THEN Set(s0)
       ELSE IF poll.orphan \/ sess # "meeting"                                   \* the session it asked for is gone
            THEN Set(IF FixFence THEN s0 ELSE [s0 EXCEPT !.ledger = FALSE])
            ELSE Set(Reassigned([s0 EXCEPT !.sdoc = [t |-> adoc.t, rev |-> adoc.rev, fin |-> TRUE], !.ledger = FALSE,
                                           !.dirty = IF FixDropDirty THEN FALSE ELSE @,
                                           !.timer = IF FixDropDirty THEN FALSE ELSE @]))

\* openInner, 309-339.  POST document is answered; then the file is read; then the session is replaced.
ReopenResponse ==
    /\ rpo.pc = "req"
    /\ \/ used.fail < MaxFail /\ Set([S EXCEPT !.used.fail = @ + 1, !.rpo = NoRpo])
       \/ IF aphase = "purged" \/ ~adoc.has THEN Set([S EXCEPT !.rpo = NoRpo])   \* 409 from LocalAPI 132
          ELSE Set([S EXCEPT !.rpo = [pc |-> "read", t |-> adoc.t, rev |-> adoc.rev, fin |-> adoc.fin]])
ReopenApply ==
    /\ rpo.pc = "read"
    /\ IF FixFence /\ knowsPurged THEN Set([S EXCEPT !.rpo = NoRpo])             \* 326
       ELSE LET src == IF FixReopenEditor /\ ViewOpen THEN ed.t ELSE disk.t      \* 323-324
                s1  == Orphaned([S EXCEPT !.rpo = NoRpo, !.sess = "meeting",
                                          !.sdoc = [t |-> src, rev |-> rpo.rev, fin |-> rpo.fin]])   \* 330
            IN Set(IF rpo.fin THEN s1 ELSE Queue(s1))                            \* 331

-----------------------------------------------------------------------------
\* Actions: the app and the network

AppPatch ==
    /\ patch.st = "sent"
    /\ LET r == AppPatched(S, patch.t, patch.rev) IN
       Set([r.s EXCEPT !.patch.st = r.res, !.patch.rev = r.s.adoc.rev])

\* The plugin gets an error for its PATCH.  If the app had not seen the request yet, it may still arrive later.
PatchFails ==
    /\ op.pc = "sync" /\ patch.st \in {"sent", "ok", "e409", "e404"} /\ used.fail < MaxFail
    /\ \E keep \in BOOLEAN :
          /\ keep => (patch.st = "sent" /\ ~late.has)
          /\ Set([S EXCEPT !.used.fail = @ + 1, !.patch.st = "err",
                           !.late = IF keep THEN [has |-> TRUE, t |-> patch.t, rev |-> patch.rev] ELSE @])
AppLatePatch ==
    /\ late.has
    /\ Set([AppPatched(S, late.t, late.rev).s EXCEPT !.late = NoLate])

\* POST finalize, LocalAPI.swift 160-167.
AppFinalizeStart(c) ==
    /\ hd[c].st = "sent"
    /\ IF apassing THEN Set([S EXCEPT !.hd[c].st = "done", !.hd[c].res = "err"])   \* 164: finish() returns false at once
       ELSE Set([S EXCEPT !.hd[c].st = "pass", !.apassing = TRUE])                 \* 164 suspends in the final pass
AppFinalizeCommit(c) ==
    /\ hd[c].st = "pass"
    /\ LET s0 == [S EXCEPT !.apassing = FALSE]
           r  == Commit(s0, FALSE) IN
       IF r.ok THEN Set([r.s EXCEPT !.hd[c] = [st |-> IF SlowIndex THEN "index" ELSE "done", res |-> "ok",
                                               t |-> r.s.adoc.t, path |-> r.s.apath]])
       ELSE Set([r.s EXCEPT !.hd[c].st = "done", !.hd[c].res = "err"])
AppFinalizeIndexed(c) == hd[c].st = "index" /\ Set([S EXCEPT !.hd[c].st = "done"])

\* The app finalizes without the plugin: MeetingRetention.recover 131-137, or the first half of done, 76-81.
AppFinalizeSelf ==
    /\ AppFinalizes /\ aphase = "ended" /\ adoc.has /\ ~adoc.fin /\ ~apassing
    /\ Set(Commit(S, TRUE).s)

\* MeetingRetention.done 91-113, or the same from recover at the deadline.
AppPurge ==
    /\ AppPurges /\ aphase = "ended" /\ adoc.has /\ adoc.fin
    /\ Set([S EXCEPT !.aphase = "purged", !.adoc = [has |-> FALSE, t |-> {}, rev |-> 0, fin |-> FALSE],
                     !.evPurged = Online(S)])

-----------------------------------------------------------------------------
Init ==
    /\ typed = {}
    /\ ed = [t |-> {}, ai |-> FALSE] /\ edBase = [t |-> {}, ai |-> FALSE] /\ disk = [t |-> {}, ai |-> FALSE]
    /\ sess = (IF Meeting THEN "meeting" ELSE "ordinary") /\ renamed = FALSE
    /\ sdoc = [t |-> {}, rev |-> 0, fin |-> FALSE]
    /\ dirty = FALSE /\ timer = FALSE /\ ledger = Meeting
    /\ ops = <<>> /\ op = NoOp /\ patch = NoPatch /\ late = NoLate
    /\ fin = [c \in Calls |-> NoCall] /\ hd = [c \in Calls |-> NoHd]
    /\ finalizing = FALSE /\ finBusy = FALSE /\ conn = "online"
    /\ adoc = [has |-> Meeting, t |-> {}, rev |-> 0, fin |-> FALSE] /\ aphase = "ended" /\ apassing = FALSE
    /\ conflict = FALSE /\ apath = "note" /\ evFin = FALSE /\ evPurged = FALSE /\ knowsPurged = FALSE
    /\ rpo = NoRpo /\ poll = NoPoll
    /\ used = [press |-> 0, fail |-> 0, drop |-> 0, reopen |-> 0, ext |-> 0]
    /\ hist = [rollback |-> FALSE, twoFinalizes |-> FALSE, sentOrdinary |-> FALSE, askedOrdinary |-> FALSE,
               sentAfterPurge |-> FALSE]

Env ==
    \/ Type \/ Press \/ ReopenSend \/ Rename \/ ExternalModify
    \/ ConnDrop \/ PatchFails \/ AppFinalizeSelf \/ AppPurge

Sys ==
    \/ Autosave \/ Reload \/ TimerFires \/ SaveDone \/ SyncResponse \/ StoreDone \/ Open409Response \/ GoneResponse
    \/ EvFinalized \/ EvPurged \/ ConnUp \/ PollSend \/ PollResponse \/ ReopenResponse \/ ReopenApply
    \/ AppPatch \/ AppLatePatch
    \/ \E c \in Calls : FinalizeResponse(c) \/ FinalizeRead(c) \/ FinalizeSave(c)
                        \/ AppFinalizeStart(c) \/ AppFinalizeCommit(c) \/ AppFinalizeIndexed(c)

Next == Env \/ Sys

\* Everything the plugin, Obsidian and the app do on their own eventually happens; what the person and the
\* network do to them (Env) is not obliged to.
Fairness ==
    /\ WF_vars(Autosave) /\ WF_vars(Reload) /\ WF_vars(TimerFires) /\ WF_vars(SaveDone) /\ WF_vars(SyncResponse)
    /\ WF_vars(StoreDone) /\ WF_vars(Open409Response) /\ WF_vars(GoneResponse) /\ WF_vars(EvFinalized)
    /\ WF_vars(EvPurged) /\ WF_vars(ConnUp) /\ WF_vars(PollSend) /\ WF_vars(PollResponse)
    /\ WF_vars(ReopenResponse) /\ WF_vars(ReopenApply) /\ WF_vars(AppPatch) /\ WF_vars(AppLatePatch)
    /\ \A c \in Calls : /\ WF_vars(FinalizeResponse(c)) /\ WF_vars(FinalizeRead(c)) /\ WF_vars(FinalizeSave(c))
                        /\ WF_vars(AppFinalizeStart(c)) /\ WF_vars(AppFinalizeCommit(c))
                        /\ WF_vars(AppFinalizeIndexed(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

AppText == IF adoc.has THEN adoc.t ELSE {}

\* P1: every character the person typed is still in the editor, or in the document the app holds.
P1_NothingTypedIsLost == typed \subseteq (ed.t \cup AppText)
\* P1e, stronger: it is still in the editor.  The plugin never has a reason to take a person's text out.
P1e_EditorKeepsTyped == typed \subseteq ed.t

\* P2: the app never replaces its document with one that lacks text it already had.
P2_NoRollback == ~hist.rollback

\* P3: a finalize request is never sent while another one is waiting for its answer.
P3_OneFinalizePerPress == ~hist.twoFinalizes
\* P3b: when no finalize is in flight, nothing stops the next press (a failed one can be retried).
P3b_FailedFinalizeCanBeRetried == finBusy => \E c \in Calls : fin[c].pc \in {"flush", "req", "read", "save"}

\* P4: once the plugin has handled a meeting's purge it sends no document request for it,
P4_QuietAfterPurge == ~hist.sentAfterPurge
\* keeps no saved ledger of it,
P4b_NoLedgerAfterPurge == knowsPurged => ~ledger
\* and it does get to know: after a purge the plugin eventually has no live (unfinalized) session of the meeting.
P4c_PurgeIsLearned == (aphase = "purged") ~> (sess # "meeting" \/ sdoc.fin)

\* P5: a note that is not a meeting note is never sent to the app (its text), never asked about (its path),
\* and never copied into the plugin's saved data.
P5_OrdinaryNeverSent == ~hist.sentOrdinary
P5b_OrdinaryNeverAsked == ~hist.askedOrdinary
P5c_OrdinaryNotInLedger == ~Meeting => ~ledger

\* Nothing is scheduled, in flight or about to happen by itself.
Quiet ==
    /\ conn = "online" /\ ~timer /\ op.pc = "idle" /\ ops = <<>> /\ patch.st = "none" /\ ~late.has
    /\ \A c \in Calls : fin[c].pc \in {"idle", "done"} /\ hd[c].st \in {"none", "done"}
    /\ rpo.pc = "idle" /\ poll.pc = "idle" /\ ~evFin /\ ~evPurged
    /\ ed = edBase /\ disk = edBase

\* The app's document is what the note holds (while the note is still a live, unfinalized meeting note).
Synced == (sess = "meeting" /\ ~sdoc.fin /\ adoc.has /\ ~adoc.fin) => adoc.t = (IF ViewOpen THEN ed.t ELSE disk.t)

\* P6a: nothing is left unsaved with nothing scheduled.
P6a_NothingStranded == Quiet => Synced
\* P6: with the app reachable, the note is eventually saved and stays so, and the timer stops firing.
P6_EventuallySavedAndQuiet == <>[](Synced /\ ~timer)

TypeOK ==
    /\ sess \in {"none", "meeting", "ordinary"} /\ conn \in {"online", "offline"}
    /\ aphase \in {"ended", "purged"} /\ apath \in {"note", "conflict"}
    /\ op.pc \in {"idle", "save", "sync", "store", "open409", "gone"}
    /\ patch.st \in {"none", "sent", "ok", "e409", "e404", "err"}
    /\ \A c \in Calls : fin[c].pc \in {"idle", "flush", "req", "read", "save", "done"}
                        /\ hd[c].st \in {"none", "sent", "pass", "index", "done"}
=============================================================================
