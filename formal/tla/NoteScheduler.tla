--------------------------- MODULE NoteScheduler ---------------------------
(***************************************************************************)
(* MACHINE 3: NoteEnhancementScheduler for ONE meeting, with the parts of  *)
(* AppModel that drive it.                                                 *)
(*                                                                         *)
(* The spec describes TWO versions of the code, selected by constants:     *)
(*   "edcaebae": git edcaebae96a0f6a34ff891cbac2a0004c4f7ac7c              *)
(*   "current":  the working tree on top of that commit (the fixes are     *)
(*               uncommitted), read on 2026-11-11                          *)
(* Line numbers in the comments are the CURRENT file's.  The README has    *)
(* both columns.                                                           *)
(*                                                                         *)
(*   Sources/WorkScribe/MeetingNotes.swift  schedule 138-161, signature    *)
(*     163-165, yieldLive 172-176, beginStop 178-182, finish 183-240,      *)
(*     run 241-324; the note edits that call schedule 49-105               *)
(*   Sources/WorkScribe/AppModel.swift      consume 596-617,               *)
(*     updateRecordingPressure 740-755, finishRecording 461-468, 509-524,  *)
(*     546-554, start 208-209, 235-241, 309-311, 342-353,                  *)
(*     startCaptions 387, 402-403                                          *)
(*   Sources/WorkScribe/MeetingRetention.swift 79, 126 and                 *)
(*     Sources/WorkScribe/LocalAPI.swift 144 (other callers of finish)     *)
(*   Sources/WorkScribeCore/Engine/Line.swift 23, 32 (resume / settle)     *)
(*   Sources/WorkScribe/CurrentNoteEngine.swift 23-46 (apply)              *)
(*                                                                         *)
(* The scheduler keeps its sets per meeting id; with one meeting each set  *)
(* is a boolean.  Steps are cut at the awaits of the @MainActor methods.   *)
(* `Task { ... }` bodies are separate steps from the code that spawns them.*)
(*                                                                         *)
(* THREE KINDS OF CONSTANT, as in Recording.tla: the fixes as written in   *)
(* the working tree, candidate sketches that are not in the code, and      *)
(* mutations.  All FALSE and the refinements off is the code at edcaebae   *)
(* exactly as it was modelled then.  "previous" in configuration names is  *)
(* the first round of fixes alone.                                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    NLive, NFinish,      \* live-pass tasks and finish() calls that may exist at once (slots are reused)
    MaxInputs,           \* transcript events and note edits
    MaxPressure,         \* times recognition falls behind (AI paused)
    MaxStop, MaxResume, MaxOtherFinish,
    MaxThrow,            \* enhance() throws (model error or cancellation)
    MaxMore,             \* a live pass leaves targets unanswered (277)
    MaxUnsearched,       \* enhancer.searched() says the index could not see the transcript
    \* --- refinements, added for the current code.  Off = the model as it was at edcaebae.
    StartAwaits,         \* a resume is two steps: 237 (new generation, pressure back to normal) and, after the
                         \* awaits of start (connect, capture), 305-307.  FALSE = one step, which is what a
                         \* captions resume is (374-390) and how every resume was modelled at edcaebae.
    MaxResumeFail,       \* how many times a resumed start may fail in those awaits (catch, 338-346)
    TrackOwed,           \* record what N7 and N8 need
    \* --- the fixes as written in the working tree
    FixNilGuard,           \* 286-288: run's "found nothing" branch returns when the meeting was resumed meanwhile
    FixFinishDraining,     \* 186: finish clears `draining` before its guard at 187
    FixToken,              \* 154-156: a live task only takes ITS OWN entry out of `pending`, known by its token
    FixTailSchedules,      \* AppModel 553: the tail of finishRecording calls schedule after resetting the pressure
    FixStartSchedules,     \* AppModel 311, 403: start calls schedule once the phase is "recording"
    FixFinalRecordsInputs, \* 250: a final run records the input signature it read
    \* --- a later round (the third), written in answer to this model's findings on the first (N5, N7)
    FixCatchSchedules,     \* AppModel 353: start's catch calls schedule for whatever meeting is on screen
    FixRequeueSuperseded,  \* 288, 306: a pass that gives up at a "resumed?" guard marks the meeting dirty first
    \* --- sketches from the edcaebae round: not in the code
    FixNilBranchFence,   \* (edcaebae sketch) run re-checks generation/session/endedAt before settling at 289
    FixUnpauseSchedules, \* (edcaebae sketch) whoever resets recordingPressure to .normal also calls schedule there
    FixNoSteal,          \* (edcaebae sketch) a live task only moves ITSELF from pending to live
    \* --- mutations
    MutNoRunningGuard,   \* drop `!running.contains(id)` at 242
    MutNoPatchFence,     \* drop the generation/session guard at 264-265
    MutNoSettle,         \* never settle lines (drop 289-291 and 309-313)
    MutYieldKeepsInputs, \* yieldLive does not reset inputs[id] (drop the end of 175)
    MutNoDeferSchedule   \* drop the re-schedule in the defers at 190 and 256

LiveTasks == 1..NLive
Calls     == 1..NFinish
Runs      == 1..(NLive + NFinish)   \* run r belongs to live task r, or to finish call r - NLive

VARIABLES
    pending, liveT,            \* pending[id], live[id]: 0 or a live task
    running, finalizing, draining, dirty,
    inputs,                    \* inputs[id]: 0 = nil, else version + 1
    retry,                     \* the 3 s retry task of 294-298 is waiting
    phase,                     \* "recording" | "finalizing" | "ready" | "starting"
    paused,                    \* model.liveAIPaused
    gen, sess, ended, status,  \* recordingGeneration, last session, endedAt (0 = nil), meeting.status
    ver,                       \* version of the hashed inputs (segments and notes)
    seen,                      \* the version the most recently started run took as its snapshot
    owed,                      \* a run gave up because of a resume, after it had taken work nothing else had done
    line,                      \* state of the one note line
    clock,
    lt, fc, rn, stp,
    used, hist

vars == <<pending, liveT, running, finalizing, draining, dirty, inputs, retry, phase, paused, gen, sess,
          ended, status, ver, seen, owed, line, clock, lt, fc, rn, stp, used, hist>>

S == [pending |-> pending, liveT |-> liveT, running |-> running, finalizing |-> finalizing,
      draining |-> draining, dirty |-> dirty, inputs |-> inputs, retry |-> retry, phase |-> phase,
      paused |-> paused, gen |-> gen, sess |-> sess, ended |-> ended, status |-> status, ver |-> ver,
      seen |-> seen, owed |-> owed,
      line |-> line, clock |-> clock, lt |-> lt, fc |-> fc, rn |-> rn, stp |-> stp, used |-> used, hist |-> hist]

Set(n) ==
    /\ pending' = n.pending /\ liveT' = n.liveT /\ running' = n.running /\ finalizing' = n.finalizing
    /\ draining' = n.draining /\ dirty' = n.dirty /\ inputs' = n.inputs /\ retry' = n.retry
    /\ phase' = n.phase /\ paused' = n.paused /\ gen' = n.gen /\ sess' = n.sess /\ ended' = n.ended
    /\ status' = n.status /\ ver' = n.ver /\ seen' = n.seen /\ owed' = n.owed /\ line' = n.line /\ clock' = n.clock
    /\ lt' = n.lt /\ fc' = n.fc /\ rn' = n.rn /\ stp' = n.stp /\ used' = n.used /\ hist' = n.hist

IdleLt  == [pc |-> "idle", cancelled |-> FALSE]
IdleFc  == [pc |-> "idle", ended0 |-> 0, sess0 |-> 0, wait |-> 0, success |-> FALSE, v |-> 0]
IdleRn  == [pc |-> "none", final |-> FALSE, g |-> 0, s |-> 0, e |-> 0, v |-> 0, stopped |-> FALSE, stage |-> 0,
            had |-> FALSE]
IdleStp == [pc |-> "idle", call |-> 0, g |-> 0, e |-> 0]

-----------------------------------------------------------------------------
\* Line.swift:23, 32
Settle(l) == IF l \in {"listening", "found"} THEN "quiet" ELSE IF l = "answered" THEN "settled" ELSE l
Unsettle(l) == IF l = "quiet" THEN "listening" ELSE IF l = "settled" THEN "answered" ELSE l

\* MeetingNotes.swift:138-161
Schedule(s) ==
    IF s.paused THEN s                                                           \* 139
    ELSE IF s.inputs = s.ver + 1 THEN s                                          \* 141
    ELSE LET s1 == [s EXCEPT !.inputs = s.ver + 1, !.dirty = TRUE] IN            \* 142-144
         IF s1.finalizing \/ s1.draining THEN s1                                 \* 145
         ELSE IF s1.running \/ s1.pending # 0 THEN s1                            \* 147
         ELSE LET free == {t \in LiveTasks : s1.lt[t].pc = "idle"} IN
              IF free = {} THEN [s1 EXCEPT !.hist.overflow = TRUE]               \* model bound too small
              ELSE LET t == CHOOSE x \in free : \A y \in free : x <= y IN
                   [s1 EXCEPT !.pending = t, !.lt[t] = [pc |-> "queued", cancelled |-> FALSE]]   \* 148-160

\* `pending.removeValue(forKey: id)?.task.cancel()` (174, 181, 194, 204)
CancelPending(s) == IF s.pending = 0 THEN s ELSE [s EXCEPT !.lt[s.pending].cancelled = TRUE, !.pending = 0]

\* 172-176
YieldLive(s) ==
    LET s1 == CancelPending(s)
        s2 == IF s1.liveT # 0 THEN [s1 EXCEPT !.lt[s1.liveT].cancelled = TRUE, !.dirty = TRUE] ELSE s1
    IN [s2 EXCEPT !.inputs = IF MutYieldKeepsInputs THEN @ ELSE 0]

\* 178-182
BeginStop(s) == CancelPending([s EXCEPT !.draining = TRUE])

-----------------------------------------------------------------------------
\* run(id, model:, final:)

Superseded(s, r) == s.gen # s.rn[r].g \/ s.sess # s.rn[r].s

\* 242-243 (the retention part of the guard is not modelled)
RunGuard(s, final) == (final \/ ~s.paused) /\ (MutNoRunningGuard \/ ~s.running)

\* 244-257, up to `await enhancer.enhance` (262).  250: a final run records what it read as the inputs seen.
RunSetup(s, r, final) ==
    [s EXCEPT !.running = TRUE, !.dirty = FALSE, !.seen = s.ver, !.owed = FALSE,
              !.inputs = IF final /\ FixFinalRecordsInputs THEN s.ver + 1 ELSE @,
              !.rn[r] = [pc |-> "enh", final |-> final, g |-> s.gen, s |-> s.sess, e |-> s.ended,
                         v |-> s.ver, stopped |-> s.status # "recording", stage |-> 0,
                         \* this run is taking work that nothing has done yet
                         had |-> TrackOwed /\ (s.dirty \/ s.ver # s.seen \/ s.owed)]]

\* The caller's continuation: the live task's defer (156), or finish (207-215).
OwnerAfterRun(s, r, ok) ==
    IF r \in LiveTasks THEN [s EXCEPT !.liveT = IF FixToken /\ @ # r THEN @ ELSE 0, !.lt[r] = IdleLt]
    ELSE [s EXCEPT !.fc[r - NLive].pc = "f_runDone", !.fc[r - NLive].success = ok]

\* 254-257
RunReturn(s, r, ok) ==
    LET s1 == [s EXCEPT !.running = FALSE, !.rn[r] = IdleRn]
        s2 == IF s1.dirty /\ ~MutNoDeferSchedule THEN Schedule([s1 EXCEPT !.inputs = 0]) ELSE s1
    IN OwnerAfterRun(s2, r, ok)

\* The run stops at one of its "resumed meanwhile?" guards (286-288, 304-306) and returns false.  Up to the
\* first round nothing put back what it had taken; the third round's `dirty.insert(id)` there does.
Abandon(s, r) == [s EXCEPT !.owed = @ \/ s.rn[r].had, !.dirty = @ \/ FixRequeueSuperseded]

\* 263-275, the didProduce callback.  First patch: the plan, marking the line "found" (267-271).
\* Second patch: the outcome (272), which answers the line or leaves it listening.
Patch(s, r, answered) ==
    LET fenced == MutNoPatchFence \/ ~Superseded(s, r)                           \* 264-265
        st     == s.rn[r].stage
        l2     == IF st = 0 THEN (IF s.line = "listening" THEN "found" ELSE s.line)
                  ELSE IF s.line \in {"listening", "found"} THEN (IF answered THEN "answered" ELSE "listening")
                  ELSE s.line
    IN IF ~fenced THEN [s EXCEPT !.rn[r].stage = st + 1]
       ELSE [s EXCEPT !.rn[r].stage = st + 1, !.line = l2,
                      !.dirty = @ \/ (s.ver # s.rn[r].v),                        \* 272: apply reports a stale note
                      !.hist.n4 = @ \/ (Superseded(s, r) /\ l2 # s.line)]

\* 281-302, continuation of `await enhancer.searched(id)`.  At edcaebae there was no generation, session or
\* endedAt check here; the current code has one at 286-288, before the settling and before the retry.
AfterSearched(s, r, searched) ==
    LET x      == s.rn[r]
        stale  == Superseded(s, r) \/ s.ended # x.e
    IN IF FixNilGuard /\ stale THEN RunReturn(Abandon(s, r), r, FALSE)
       ELSE LET settle == (x.final \/ (x.stopped /\ searched)) /\ ~MutNoSettle /\ ~(FixNilBranchFence /\ stale)
                s1     == IF settle THEN [s EXCEPT !.line = Settle(@), !.hist.n4 = @ \/ (Superseded(s, r) /\ Settle(s.line) # s.line)]
                          ELSE s
                s2     == IF x.stopped /\ ~x.final /\ ~searched THEN [s1 EXCEPT !.retry = TRUE] ELSE s1   \* 292-299
            IN RunReturn(s2, r, ~(FixNilBranchFence /\ stale))

\* Continuation of `try await enhancer.enhance(...)` (262).
EnhEnd(s, r, out, more) ==
    LET x == s.rn[r] IN
    CASE out = "throw" -> RunReturn(s, r, FALSE)                                 \* 317-323
      [] out = "nil"   -> [s EXCEPT !.rn[r].pc = "searched"]                     \* 278-281
      [] out = "done"  ->
            LET s1 == IF more THEN [s EXCEPT !.dirty = TRUE] ELSE s IN           \* 277
            IF Superseded(s1, r) \/ s1.ended # x.e THEN RunReturn(Abandon(s1, r), r, FALSE)  \* 304-306
            ELSE LET s2 == IF (x.final \/ x.stopped) /\ ~MutNoSettle
                           THEN [s1 EXCEPT !.line = Settle(@)] ELSE s1 IN        \* 309-313
                 RunReturn(s2, r, TRUE)

-----------------------------------------------------------------------------
\* The live task's body, 149-159
LiveStart(s, t) ==
    LET mine == s.pending = t IN
    IF FixToken /\ ~mine THEN [s EXCEPT !.lt[t] = IdleLt]                        \* 154: not its entry; return
    ELSE LET s1 == IF FixNoSteal
                   THEN [s EXCEPT !.liveT = IF mine THEN t ELSE @, !.pending = IF mine THEN 0 ELSE @]
                   ELSE [s EXCEPT !.liveT = s.pending, !.pending = 0]            \* edcaebae:149 took whatever was pending
             quit == [s1 EXCEPT !.liveT = IF FixNoSteal /\ ~mine THEN @ ELSE 0, !.lt[t] = IdleLt]   \* defer at 156
         IN IF s.lt[t].cancelled THEN quit                                       \* 157
            ELSE IF ~RunGuard(s1, FALSE) THEN quit                               \* run returns false at 242
            ELSE [RunSetup(s1, t, FALSE) EXCEPT !.lt[t].pc = "running"]

-----------------------------------------------------------------------------
\* finish(id, model:)

\* The defer at 188-191, then return.
FinishExit(s, c, ok) ==
    LET x      == s.fc[c]
        nores  == s.ended = x.ended0 /\ s.sess = x.sess0
        open   == s.line \in {"listening", "found"}
        s1     == [s EXCEPT !.finalizing = FALSE, !.fc[c].pc = "done", !.fc[c].success = ok,
                            !.hist.n3 = @ \/ (ok /\ nores /\ open),
                            !.hist.n3e = @ \/ (ok /\ nores /\ open /\ s.ver = x.v)]
    IN IF s1.dirty /\ ~MutNoDeferSchedule THEN Schedule([s1 EXCEPT !.inputs = 0]) ELSE s1

\* 215-240 (the synthesis job of 217-238 is not modelled)
FinishC(s, c) == FinishExit(s, c, s.fc[c].success)

\* 209: the worker task of RecordingDeadline.wait starts run(final: true)
FinishRunStart(s, c) ==
    IF ~RunGuard(s, TRUE) THEN [s EXCEPT !.fc[c].pc = "f_runDone", !.fc[c].success = FALSE, !.hist.n6 = TRUE]
    ELSE [RunSetup(s, NLive + c, TRUE) EXCEPT !.fc[c].pc = "f_run", !.fc[c].v = s.ver]

\* 203-209, continuation of the await at 201
FinishB(s, c) ==
    IF s.ended # s.fc[c].ended0 THEN FinishExit(s, c, FALSE)                     \* 203
    ELSE [CancelPending(s) EXCEPT !.fc[c].pc = "f_runWait"]                      \* 204-209

\* 197-201
FinishA(s, c) ==
    IF s.ended # s.fc[c].ended0 THEN FinishExit(s, c, FALSE)                     \* 198
    ELSE [s EXCEPT !.fc[c].pc = "f_images"]                                      \* 201 suspends

\* 186-196.  At edcaebae the guard came first and `draining` was only cleared after it.
FinishEnter(s, c) ==
    IF s.finalizing
    THEN [s EXCEPT !.fc[c].pc = "done", !.fc[c].success = FALSE,                 \* 187: nothing else happens
                   !.draining = IF FixFinishDraining THEN FALSE ELSE @]
    ELSE LET s1 == CancelPending([s EXCEPT !.finalizing = TRUE, !.draining = FALSE,
                                           !.fc[c].ended0 = s.ended, !.fc[c].sess0 = s.sess, !.fc[c].v = s.ver]) IN
         IF s1.liveT # 0 THEN [s1 EXCEPT !.fc[c].pc = "f_waitLive", !.fc[c].wait = s1.liveT]   \* 196 suspends
         ELSE FinishA(s1, c)

-----------------------------------------------------------------------------
\* Actions

FreeCall == CHOOSE c \in Calls : fc[c].pc \in {"idle", "done"} /\ \A d \in Calls : d < c => fc[d].pc \notin {"idle", "done"}
HasFreeCall == \E c \in Calls : fc[c].pc \in {"idle", "done"}
ResetCall(s, c) == [s EXCEPT !.fc[c] = IdleFc]

\* --- environment ---

\* A finished transcript line arrives: AppModel.consume, 613-616.
Speech ==
    /\ used.inputs < MaxInputs /\ phase = "recording"
    /\ Set(Schedule([S EXCEPT !.ver = @ + 1, !.used.inputs = @ + 1]))

\* The user adds or rewrites a jot: MeetingNotes.swift:58-67, 75-81.  A rewritten jot listens again.
Edit ==
    /\ used.inputs < MaxInputs
    /\ Set(Schedule([S EXCEPT !.ver = @ + 1, !.used.inputs = @ + 1, !.line = "listening"]))

\* AppModel.updateRecordingPressure 740-755
PressureUp ==
    /\ used.pressure < MaxPressure /\ phase = "recording" /\ ~paused
    /\ Set(YieldLive([S EXCEPT !.paused = TRUE, !.used.pressure = @ + 1]))       \* 746, 754
PressureDown ==
    /\ phase = "recording" /\ paused
    /\ Set(Schedule([S EXCEPT !.paused = FALSE]))                                \* 746, 752

\* Stop: AppModel.finishRecording 461-468
Stop ==
    /\ used.stop < MaxStop /\ phase = "recording" /\ stp.pc = "idle"
    /\ Set(BeginStop([S EXCEPT !.phase = "finalizing", !.status = "finalizing", !.ended = clock + 1,
                               !.clock = @ + 1, !.used.stop = @ + 1, !.stp.pc = "drain"]))

\* Resume: AppModel.start 208-209, 235-241.  Allowed once Stop has reached the final pass (progress 0.35).
\* 241 sets recordingPressure = .normal without telling the scheduler.  The current code calls schedule
\* later, at 311, when the phase becomes "recording"; a captions resume (387-403) does both in one step.
Resume ==
    /\ used.resume < MaxResume /\ ended # 0 /\ status # "failed"
    /\ phase = "ready" \/ (phase = "finalizing" /\ stp.pc = "await")
    /\ LET s1 == [S EXCEPT !.phase = IF StartAwaits THEN "starting" ELSE "recording", !.status = "recording",
                           !.gen = @ + 1, !.sess = @ + 1,
                           !.ended = 0, !.paused = FALSE, !.line = Unsettle(@), !.used.resume = @ + 1]
       IN Set(IF FixUnpauseSchedules \/ (FixStartSchedules /\ ~StartAwaits) THEN Schedule(s1) ELSE s1)

\* AppModel.start 309-311: the awaits of start are over.
StartDone ==
    /\ phase = "starting"
    /\ LET s1 == [S EXCEPT !.phase = "recording"] IN Set(IF FixStartSchedules THEN Schedule(s1) ELSE s1)

\* AppModel.start 342-353: one of them threw.  The meeting is marked failed and ended (349).  Up to the first
\* round nobody then called schedule; the third round does at 353.
StartFails ==
    /\ phase = "starting" /\ used.resumeFail < MaxResumeFail
    /\ LET s1 == [S EXCEPT !.phase = "ready", !.status = "failed", !.ended = clock + 1, !.clock = @ + 1,
                           !.used.resumeFail = @ + 1]
       IN Set(IF FixCatchSchedules THEN Schedule(s1) ELSE s1)

\* A resume that fails before its meeting is installed (245): start has taken a new generation and reset the
\* pressure (241), then prepareSpeech throws (a stalled recognizer throws at 193 without suspending), and the
\* catch runs with `meeting` still the ended one: phase "error" (350), and since the third round schedule
\* (353), which is not conditional on `installed`.  One step.
ResumeFailsEarly ==
    /\ used.resume < MaxResume /\ used.resumeFail < MaxResumeFail /\ ended # 0 /\ status # "failed"
    /\ phase = "ready" \/ (phase = "finalizing" /\ stp.pc = "await")
    /\ LET s1 == [S EXCEPT !.phase = "ready", !.gen = @ + 1, !.paused = FALSE,
                           !.used.resume = @ + 1, !.used.resumeFail = @ + 1]
       IN Set(IF FixCatchSchedules THEN Schedule(s1) ELSE s1)

\* Another caller of finish on an ended meeting: recover (MeetingRetention.swift:126), done (79),
\* the plugin's Finalize (LocalAPI.swift:144).
OtherFinish ==
    /\ used.other < MaxOtherFinish /\ phase = "ready" /\ ended # 0 /\ HasFreeCall
    /\ LET c == FreeCall IN Set(FinishEnter(ResetCall([S EXCEPT !.used.other = @ + 1], c), c))

\* --- the app's own steps ---

\* finishRecording 509-519: the drain is over, the meeting is complete, the final pass begins.
StopDrained ==
    /\ stp.pc = "drain" /\ HasFreeCall
    /\ LET c == FreeCall IN
       Set(FinishEnter(ResetCall([S EXCEPT !.status = "complete",
                                           !.stp = [pc |-> "await", call |-> c, g |-> gen, e |-> ended]], c), c))

\* finishRecording 519-554.  550 resets the pressure; 553 (current code) then calls schedule.
StopAfterFinish ==
    /\ stp.pc = "await" /\ fc[stp.call].pc = "done"
    /\ IF gen # stp.g \/ ended # stp.e THEN Set([S EXCEPT !.stp = IdleStp])                       \* 524, 546
       ELSE LET s1 == [S EXCEPT !.paused = FALSE, !.phase = "ready", !.stp = IdleStp]             \* 550-554
                s2 == IF FixUnpauseSchedules \/ FixTailSchedules THEN Schedule(s1) ELSE s1
            \* for N8: that call queued a pass although the final pass had read everything there is
            IN Set([s2 EXCEPT !.hist.n8 = @ \/ (TrackOwed /\ s2.pending # s1.pending /\ S.fc[stp.call].success
                                                  /\ s1.ver = s1.seen /\ ~s1.dirty /\ ~s1.owed)])

LiveTaskRuns(t) == lt[t].pc = "queued" /\ Set(LiveStart(S, t))

PatchArrives(r) == rn[r].pc = "enh" /\ rn[r].stage < 2 /\ \E a \in BOOLEAN : Set(Patch(S, r, a))

EnhanceReturns(r) ==
    /\ rn[r].pc = "enh"
    /\ \E out \in {"done", "nil", "throw"}, more \in BOOLEAN :
          /\ out = "throw" => used.throw < MaxThrow
          /\ out = "nil" => rn[r].stage = 0 /\ ~more
          /\ out = "throw" => ~more
          /\ more => (used.more < MaxMore /\ ~rn[r].final /\ ~rn[r].stopped)
          /\ Set(EnhEnd([S EXCEPT !.used.throw = IF out = "throw" THEN @ + 1 ELSE @,
                                  !.used.more = IF more THEN @ + 1 ELSE @], r, out, more))

SearchedReturns(r) ==
    /\ rn[r].pc = "searched"
    /\ \E ok \in (IF used.unsearched < MaxUnsearched THEN {TRUE, FALSE} ELSE {TRUE}) :
          Set(AfterSearched([S EXCEPT !.used.unsearched = IF ok THEN @ ELSE @ + 1], r, ok))

\* 294-298: three seconds later
RetryFires == retry /\ Set(Schedule([S EXCEPT !.retry = FALSE, !.inputs = 0]))

FinishLiveDone(c)   == fc[c].pc = "f_waitLive" /\ lt[fc[c].wait].pc = "idle" /\ Set(FinishA(S, c))
FinishImagesDone(c) == fc[c].pc = "f_images"  /\ Set(FinishB(S, c))
FinishRunStarts(c)  == fc[c].pc = "f_runWait" /\ Set(FinishRunStart(S, c))
FinishRunDone(c)    == fc[c].pc = "f_runDone" /\ Set(FinishC(S, c))

Init ==
    /\ pending = 0 /\ liveT = 0 /\ running = FALSE /\ finalizing = FALSE /\ draining = FALSE
    /\ dirty = FALSE /\ inputs = 0 /\ retry = FALSE
    /\ phase = "recording" /\ paused = FALSE /\ gen = 1 /\ sess = 1 /\ ended = 0 /\ status = "recording"
    /\ ver = 0 /\ seen = 0 /\ owed = FALSE /\ line = "listening" /\ clock = 0
    /\ lt = [t \in LiveTasks |-> IdleLt] /\ fc = [c \in Calls |-> IdleFc] /\ rn = [r \in Runs |-> IdleRn]
    /\ stp = IdleStp
    /\ used = [inputs |-> 0, pressure |-> 0, stop |-> 0, resume |-> 0, other |-> 0, throw |-> 0,
               more |-> 0, unsearched |-> 0, resumeFail |-> 0]
    /\ hist = [n3 |-> FALSE, n3e |-> FALSE, n4 |-> FALSE, n6 |-> FALSE, n8 |-> FALSE, overflow |-> FALSE]

Next ==
    \/ Speech \/ Edit \/ PressureUp \/ PressureDown \/ Stop \/ Resume \/ StartDone \/ StartFails \/ ResumeFailsEarly
    \/ OtherFinish
    \/ StopDrained \/ StopAfterFinish \/ RetryFires
    \/ \E t \in LiveTasks : LiveTaskRuns(t)
    \/ \E r \in Runs : PatchArrives(r) \/ EnhanceReturns(r) \/ SearchedReturns(r)
    \/ \E c \in Calls : FinishLiveDone(c) \/ FinishImagesDone(c) \/ FinishRunStarts(c) \/ FinishRunDone(c)

Fairness ==
    /\ WF_vars(StopDrained) /\ WF_vars(StopAfterFinish) /\ WF_vars(RetryFires)
    /\ WF_vars(StartDone \/ StartFails)
    /\ \A t \in LiveTasks : WF_vars(LiveTaskRuns(t))
    /\ \A r \in Runs : WF_vars(EnhanceReturns(r)) /\ WF_vars(SearchedReturns(r))
    /\ \A c \in Calls : /\ WF_vars(FinishLiveDone(c)) /\ WF_vars(FinishImagesDone(c))
                        /\ WF_vars(FinishRunStarts(c)) /\ WF_vars(FinishRunDone(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

\* A live pass that will really run: queued and not cancelled.
Queued == \E t \in LiveTasks : lt[t].pc = "queued" /\ ~lt[t].cancelled

\* N1: dirty with nothing paused, draining or finalizing means a pass is queued or running
\* (or the 3 s retry is waiting to schedule one).
N1_NoLostWakeup == (dirty /\ ~paused /\ ~draining /\ ~finalizing) => (Queued \/ running \/ retry)

\* N1s: the same for inputs the scheduler never marked dirty: a changed version that no
\* run has taken as its snapshot.  schedule() returns at 139 while paused without recording anything.
N1s_NoUnseenInput == (ver # seen /\ ~paused /\ ~draining /\ ~finalizing) => (Queued \/ running \/ retry)

\* N1 and N1s with one more state excused (added for the current code): a start is between the line that
\* resets the pressure (237) and its own call of schedule (307).  Weaker than N1 and N1s; they are here to
\* tell that window apart from a wake-up that is lost for good.
N1x_NoLostWakeupOutsideStart ==
    (dirty /\ ~paused /\ ~draining /\ ~finalizing /\ phase # "starting") => (Queued \/ running \/ retry)
N1sx_NoUnseenInputOutsideStart ==
    (ver # seen /\ ~paused /\ ~draining /\ ~finalizing /\ phase # "starting") => (Queued \/ running \/ retry)

\* N2: at most one run in flight (so a final and a live pass never overlap).
N2_OneRun == Cardinality({r \in Runs : rn[r].pc \in {"enh", "searched"}}) <= 1

\* N3 as asked: when finish returns true and no resume happened, no line is listening or found.
N3_FinishSettles == ~hist.n3
\* N3 allowing for a jot the user rewrote after the final pass took its snapshot.
N3e_FinishSettlesUneditedLines == ~hist.n3e

\* N4: a pass from before a resume (generation or session changed) never changes a line.
N4_SupersededNeverApplies == ~hist.n4

\* N5: a dirty meeting is eventually processed (a run starts and clears dirty) or is paused.
N5_DirtyEventuallyRuns == dirty ~> (~dirty \/ paused)

\* N6: the final pass is never skipped because some other run is still in flight
\* (finish waits for live[id] at 196, so this means the live map lost track of a running pass).
N6_FinalPassNotSkipped == ~hist.n6

\* N7 (added for the current code): work that a run had taken and then dropped, because the meeting was
\* resumed under it, is picked up again.  N1s cannot see this: it counts an input as seen once any run has
\* started on it.
N7_AbandonedWorkRequeued == (owed /\ ~paused /\ ~draining /\ ~finalizing) => (Queued \/ running \/ retry)

\* N8 (added for the current code): the schedule call at the tail of finishRecording (AppModel 553) queues a
\* pass only when there is something this stop's final pass did not read: when that pass succeeded, nothing
\* has changed since it started and nothing is dirty, the call does nothing.  This is what line 250 is for.
N8_TailScheduleOnlyForNewInput == ~hist.n8

\* The slots were enough: schedule never needed a live task and found none free.
SlotsSuffice == ~hist.overflow

TypeOK ==
    /\ pending \in 0..NLive /\ liveT \in 0..NLive
    /\ phase \in {"recording", "finalizing", "ready", "starting"}
    /\ line \in {"listening", "found", "answered", "quiet", "settled"}
=============================================================================
