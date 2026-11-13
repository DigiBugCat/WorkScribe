----------------------------- MODULE Recording -----------------------------
(***************************************************************************)
(* MACHINE 1: the recording lifecycle of WorkScribe's AppModel.            *)
(*                                                                         *)
(* The spec describes THREE versions of the code, selected by constants:   *)
(*   "edcaebae": git edcaebae96a0f6a34ff891cbac2a0004c4f7ac7c              *)
(*   "previous": the working tree with the first round of fixes (nine)     *)
(*   "current":  the working tree as read on 2026-11-11, with the four of  *)
(*               the second round and the bounded closeStreams of the      *)
(*               third.  All fixes are uncommitted.                        *)
(* Line numbers in the comments are the CURRENT file's.  The README has    *)
(* the edcaebae column.                                                    *)
(*                                                                         *)
(*   Sources/WorkScribe/AppModel.swift       busy 127, checkCall 165-191,  *)
(*     prepareSpeech 192-206, start 207-365, startCaptions 368-430,        *)
(*     stop 441-460, finishRecording 461-563, fail 590-594,                *)
(*     prepareToQuit 682-694, save 726                                     *)
(*   Sources/WorkScribe/RecordingQuit.swift  8-16                          *)
(*   Sources/WorkScribe/Entry.swift          395-398, 429-442              *)
(*   Sources/WorkScribe/LocalAPI.swift       76-91 (start/resume/stop)     *)
(*   Sources/WorkScribeCore/RecordingSession.swift 20-38 (canResume/resume)*)
(*   Sources/WorkScribeCore/AutoRecordPolicy.swift 5-43                    *)
(*   Sources/WorkScribe/MeetingRetention.swift 31-65 (finalize, as called  *)
(*     from AppModel.swift:532)                                            *)
(*                                                                         *)
(* HOW THE CODE IS CUT INTO STEPS.  AppModel is @MainActor, so a method    *)
(* runs without interruption until it really suspends.  Every operator     *)
(* below named after a code region is one such uninterrupted run; it takes *)
(* the whole state `s` and returns the state at the next suspension.  An   *)
(* `await` that calls same-actor code which returns without suspending     *)
(* (prepareSpeech when the engine is warm, pauseImports in a non-Plaud     *)
(* build) is NOT a step boundary; the regions are composed in one step.    *)
(*                                                                         *)
(* THREE KINDS OF CONSTANT.  `Fix…` listed under "as written" are the      *)
(* fixes in the working tree, modelled as they were written: nine from the *)
(* first round and four from the second.  `Fix…` under "sketches" are NOT  *)
(* in the code: the ones the edcaebae findings were first checked against. *)
(* `Mut…` are deliberate breakage.  All FALSE (and the environment         *)
(* refinements off) is the code at edcaebae, exactly as it was modelled    *)
(* then.                                                                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Source,          \* AppModel.transcriptSource: "recorder" | "auto" | "zoom-captions"
    InMeetingValues, \* what ZoomCaptions.read().inMeeting may return, e.g. {TRUE, FALSE}
    ScreenCapture,   \* `await startScreen()` (306) really suspends.  It did at edcaebae (ScreenRecorder.start was
                     \* async).  In the current tree ScreenWatcher.start is synchronous, so it does not; TRUE is kept
                     \* for the current code as the harder case (a superset of what the app can do).
    HasDocument,     \* meeting.document # nil: 535-541 run instead of the await at 529
    SpeechInit,      \* "warm" (speechReady) | "cold" (prepareSpeech suspends, may throw)
    MaxFresh, MaxResume, MaxStop, MaxFail, MaxQuit,   \* how many calls the environment may make
    MaxStartErrors,  \* how many times prepareSpeech / connect / capture.start may throw
    MaxStall,        \* how many times the drain at 483 may stall
    \* --- refinements of the environment, added for the current code.  Off = the model as it was at edcaebae.
    MaxFinalizeErrors, \* how many times the wait at 529 may throw (finalize throws, or its 30 s watchdog fires)
    MaxAuto,           \* how many starts the auto-record monitor may ask for (0 = no monitor, no policy)
    MaxCall,           \* how many times a call may begin
    QuitTail,          \* prepareToQuit's wait on the title jobs (688) is a step: the app terminates after it, not at 686
    CatchTail,         \* `await runtime.closeStreams()` (356) at the end of start's catch is a step
    Extended,          \* record what R11, R13 and R15 need (off = the state space as it was)
    \* --- the fixes as written in the working tree
    FixStartClaim,       \* 208-210: start refuses while another start is between its guard and its return
    FixQuitFlag,         \* 208, 683: start refuses once prepareToQuit has begun (never reset, not looked at again)
    FixStopLoop,         \* 447-459: stop joins whatever stopTask holds, clears it if still that one, looks again
    FixInnerGenCheck,    \* 531: the closure given to the last wait re-checks the generation (only) before finalize
    FixTailGuard,        \* 546: the full "resumed?" guard again after that wait, AFTER the catch at 543
    FixFailRecheck,      \* 308: start re-checks errorText after startScreen
    FixCatchOwn,         \* 349: start's catch only marks failed a meeting this start installed at 245
    FixRefuse,           \* 371-375: a refused captions start leaves the phase alone while busy, and suppresses the
                         \* auto-record policy when the start was automatic
    FixStartDidNotBegin, \* 185: the monitor resets the policy's latch when its start did not begin a recording
    \* --- the second round, written in answer to this model's findings on the first (R11, R5d/R8, R9, R15)
    FixStopOwnSession,        \* 443, 454, 686: stop takes `asked` = the generation recording on entry (nil when nothing
                              \* is), and after joining only goes on when that is still the generation; quit is exempt
    FixCatchAfterGuard,       \* 526, 543-547: the catch keeps its text in a local; errorText is set after the guard at 546
    FixQuitRecheck,           \* 225, 381: start looks at `quitting` again after each ZoomCaptions.read
    FixCaptionsResetLate,     \* 384: startCaptions resets errorText / progress after its refusals, not on entry
    \* --- the third round
    FixCloseBounded,          \* 354-356: the catch waits for runtime.closeStreams() inside RecordingDeadline.wait, so it
                              \* goes on after the stall timeout whether or not closeStreams ever answers
    \* --- sketches from the edcaebae round: not in the code
    FixRecheckBusy,           \* start re-checks its first guard after the awaits at 223 and 380
    FixStopJoin,              \* stop ignores a finished stopTask, and after joining re-checks phase
    FixRecheckAfterFinalize,  \* the full guard inside and after the last wait
    FixQuitBlocksStart,       \* start is refused while a quit is waiting in prepareToQuit
    \* --- mutations: deliberately broken variants, used to show a passing property can fail
    MutNoBusyGuard,           \* drop the `!busy || ...` part of the guard at 208-209
    MutNoGenFence,            \* drop the guards at 524 and 546
    MutResumeAnyProgress,     \* drop `finalizationProgress >= 0.35` from the guard at 209
    MutNoCaptureHandoff,      \* finishRecording does not stop the capture (drop 473-475)
    MutFinishKeepsStatus,     \* finishRecording never writes meeting.status (drop 464 and 509)
    MutFinalPassHangs,        \* the await at 519 never returns (no stall watchdog in the scheduler)
    MutStatusAfterFinalPass,  \* meeting.status = "complete" is written after the await at 519 instead of at 509
    MutReadHangs,             \* ZoomCaptions.read() (223, 380) never returns
    MutCloseHangs,            \* runtime.closeStreams() (356) never returns
    MutNoStopJoin             \* stop does not join a stop already under way (drop 447-450)

StartSlots == 1..(MaxFresh + MaxResume + MaxAuto)
StopSlots  == 1..(MaxStop + MaxFail + MaxQuit + MaxCall)
MeetingIds == 1..(MaxFresh + MaxResume + MaxAuto)

VARIABLES
    phase,         \* AppModel.phase (10); "preview" is the QA demo only and is left out
    progress,      \* finalizationProgress * 100 (54)
    gen,           \* recordingGeneration (92), a counter instead of a UUID
    errorText,     \* errorText # nil (106)
    speech,        \* "warm" | "cold" | "stalled" (speechReady 69, recognizerStalled 107)
    mem,           \* the in-memory `meeting` (12); id 0 = nil
    disk,          \* transcript.json per meeting as last written by save() (726)
    nextId, clock, \* fresh meeting ids; distinct Date() values for endedAt
    stopTask,      \* stopTask (93): 0 or the finish task it points to
    captureVar,    \* `capture` (85): 0 or the start call whose AudioCapture it holds
    captionVar,    \* `captionTask` (27): 0 or the start call whose caption loop it holds
    audioOwners,   \* AudioCapture objects started and not yet stopped
    captionOwners, \* caption loops alive: start call -> generation it was created under (0 = none)
    st, sp, fin,   \* start calls, stop/fail/quit calls, finishRecording tasks
    used,          \* environment budgets spent
    hist,          \* history flags that record a property violation at the step it happens
    terminated,    \* the app replied terminate (Entry.swift:441)
    call,          \* CallDetector sees a call (checkCall 171)
    pol            \* AutoRecordPolicy: req = requestedStart, sup = suppressed.  Its two timers are not modelled:
                   \* "settled" and "absent for 120 s" are things the environment decides.

vars == <<phase, progress, gen, errorText, speech, mem, disk, nextId, clock, stopTask, captureVar,
          captionVar, audioOwners, captionOwners, st, sp, fin, used, hist, terminated, call, pol>>

\* `startClaimed` (96) and `quitting` (98) are not variables: the first is set right after the guard and reset by a
\* `defer`, so it is TRUE exactly while a start call is between its guard and its return; the second is set at
\* the top of prepareToQuit and never reset.  Both are read off `st` and `sp` below (Claimed, QuitStarted).

NoMeeting == [id |-> 0, status |-> "none", ended |-> 0, sess |-> 0, capt |-> FALSE, trig |-> FALSE]
IdleStart == [pc |-> "idle", rid |-> 0, res |-> NoMeeting, with |-> {}, made |-> FALSE, stopping |-> 0, trig |-> FALSE]
IdleStop  == [pc |-> "idle", kind |-> "stop", joined |-> 0, target |-> <<0, 0>>, asked |-> 0]
IdleFin   == [pc |-> "idle", cap |-> 0, id |-> 0, at |-> 0, g |-> 0, sup |-> FALSE, ran |-> FALSE, tgt |-> <<0, 0>>]

\* The whole state as one record, so code regions can be written as functions and composed.
S == [phase |-> phase, progress |-> progress, gen |-> gen, errorText |-> errorText, speech |-> speech,
      mem |-> mem, disk |-> disk, nextId |-> nextId, clock |-> clock, stopTask |-> stopTask,
      captureVar |-> captureVar, captionVar |-> captionVar, audioOwners |-> audioOwners,
      captionOwners |-> captionOwners, st |-> st, sp |-> sp, fin |-> fin, used |-> used, hist |-> hist,
      terminated |-> terminated, call |-> call, pol |-> pol]

Set(n) ==
    /\ phase' = n.phase /\ progress' = n.progress /\ gen' = n.gen /\ errorText' = n.errorText
    /\ speech' = n.speech /\ mem' = n.mem /\ disk' = n.disk /\ nextId' = n.nextId /\ clock' = n.clock
    /\ stopTask' = n.stopTask /\ captureVar' = n.captureVar /\ captionVar' = n.captionVar
    /\ audioOwners' = n.audioOwners /\ captionOwners' = n.captionOwners
    /\ st' = n.st /\ sp' = n.sp /\ fin' = n.fin /\ used' = n.used /\ hist' = n.hist
    /\ terminated' = n.terminated /\ call' = n.call /\ pol' = n.pol

-----------------------------------------------------------------------------
\* Helpers

\* AppModel.swift:127
Busy(s) == s.phase \in {"starting", "recording", "finalizing"}

\* MeetingNotes.swift:24-27 meetingSnapshot: the live meeting when it is the one asked for, else the saved one.
Snap(s, id) == IF id = 0 THEN NoMeeting ELSE IF s.mem.id = id THEN s.mem ELSE s.disk[id]

\* RecordingSession.swift:21-25.  The ten-minute window, retention and document.finalized are abstracted:
\* the environment only asks to resume inside the window.
CanResume(m) == m.ended # 0 /\ m.status \in {"complete", "interrupted"}

\* RecordingSession.swift:27-37
Resumed(m) == [m EXCEPT !.status = "recording", !.ended = 0, !.sess = @ + 1]

\* AppModel.swift:726 save(): writes the in-memory meeting under its own id.
Save(s) == IF s.mem.id = 0 THEN s ELSE [s EXCEPT !.disk[s.mem.id] = s.mem]

InFlightStarts(s) == {i \in StartSlots : s.st[i].pc \notin {"idle", "done"}}

\* startClaimed (96, 210): a start is past its guard and has not returned.  A monitor Task that has been created
\* but has not run yet ("m_task") has not claimed anything.
Claimed(s) == \E i \in StartSlots : s.st[i].pc \notin {"idle", "done", "m_task"}

\* quitting (98, 683)
QuitStarted(s) == \E k \in StopSlots : s.sp[k].kind = "quit" /\ s.sp[k].pc # "idle"

\* A resume that commits (new generation) supersedes every finishRecording still in flight.
Supersede(s, rid) ==
    IF rid = 0 THEN s.fin
    ELSE [f \in StopSlots |-> IF s.fin[f].pc \notin {"idle", "done"} THEN [s.fin[f] EXCEPT !.sup = TRUE] ELSE s.fin[f]]

\* The `!busy || ...` part of the guard at 208-209, as written (it is the whole guard at edcaebae:198)
RealGuard(s, rid) ==
    \/ ~Busy(s)
    \/ /\ s.phase = "finalizing" /\ s.progress >= 35 /\ rid # 0 /\ rid = s.mem.id /\ CanResume(s.mem)

\* ... and as modelled (with the two mutations that weaken it)
Guard(s, rid) ==
    \/ MutNoBusyGuard
    \/ ~Busy(s)
    \/ /\ s.phase = "finalizing" /\ (MutResumeAnyProgress \/ s.progress >= 35)
       /\ rid # 0 /\ rid = s.mem.id /\ CanResume(s.mem)

\* What a start that re-checks after its awaits would test (edcaebae sketches only).
QuitWaiting(s) == \E k \in StopSlots : s.sp[k].kind = "quit" /\ s.sp[k].pc \in {"join", "await"}
Recheck(s, rid) == Guard(s, rid) /\ ~(FixQuitBlocksStart /\ QuitWaiting(s))

\* The whole first guard of start (208-209), as a call finds it.
Admit(s, rid) ==
    /\ Guard(s, rid)
    /\ ~(FixStartClaim /\ Claimed(s))
    /\ ~(FixQuitFlag /\ QuitStarted(s))
    /\ ~(FixQuitBlocksStart /\ QuitWaiting(s))

\* AutoRecordPolicy.suppressCurrentCall (14-16).  Left alone when there is no monitor in the model.
Suppress(s) == IF MaxAuto = 0 THEN s ELSE [s EXCEPT !.pol = [req |-> FALSE, sup |-> TRUE]]

\* A start call returns.  For the monitor's start, the line after it (185): when no automatic recording of this
\* call is running, AutoRecordPolicy.startDidNotBegin (23-26) lets the call be asked for again.
EndStart(s0, i) ==
    LET s == [s0 EXCEPT !.st[i].pc = "done"] IN
    IF s.st[i].trig /\ FixStartDidNotBegin /\ ~(Busy(s) /\ s.mem.trig) /\ ~s.pol.sup
    THEN [s EXCEPT !.pol.req = FALSE] ELSE s

-----------------------------------------------------------------------------
\* start(), recorder path.  Regions are listed last-first because TLA+ needs definitions before use.

\* 356-364: the continuation of `await runtime.closeStreams()`, then return.  359 suppresses the call when the
\* start was automatic.
CatchEnd(s, i) == EndStart(IF s.st[i].trig THEN Suppress(s) ELSE s, i)

\* 345-356, the part of the catch block after `await capture?.stop()`.
\* `capture = nil` (345) and `meeting?.status = "failed"` (349) act on whatever those variables hold NOW.
CatchFinish(s, i) ==
    LET owns    == s.st[i].made
        clobber == s.mem.id # 0 /\ (owns \/ ~FixCatchOwn)
        m2      == IF clobber THEN [s.mem EXCEPT !.status = "failed", !.ended = s.clock + 1] ELSE s.mem
        s1      == Save([s EXCEPT !.audioOwners = @ \ {s.st[i].stopping}, !.captureVar = 0, !.mem = m2,
                                  !.clock = IF clobber THEN @ + 1 ELSE @, !.phase = "error",
                                  !.hist.r7 = @ \/ (clobber /\ ~owns)])
    IN IF CatchTail THEN [s1 EXCEPT !.st[i].pc = "s_catchClose"] ELSE CatchEnd(s1, i)

\* 342-345, up to `await capture?.stop()` (stopScreen at 344 is folded in).
CatchBegin(s, i) ==
    LET s1 == [s EXCEPT !.errorText = TRUE] IN
    IF s1.captureVar # 0
    THEN [s1 EXCEPT !.st[i].pc = "s_catchStop", !.st[i].stopping = s1.captureVar]
    ELSE CatchFinish(s1, i)

\* 309-341
StartRecording(s, i) == EndStart([s EXCEPT !.phase = "recording"], i)

\* 306-308, continuation of `await startScreen()`.  At edcaebae the code did not look at errorText again.
AfterScreen(s, i) == IF FixFailRecheck /\ s.errorText THEN CatchBegin(s, i) ELSE StartRecording(s, i)

\* 294-306, continuation of `try await capture.start(...)`.
AfterCaptureStart(s, i, ok) ==
    IF ~ok \/ s.errorText THEN CatchBegin(s, i)                       \* 294 throws, or 295
    ELSE IF ScreenCapture THEN [s EXCEPT !.st[i].pc = "s_screen"]     \* 306 suspends
    ELSE AfterScreen(s, i)

\* 266-294, continuation of `try await connection.connect()`.  The loop over microphone/system (257) is
\* modelled as one connect.  290 overwrites `capture` without stopping a previous one; the new AudioCapture
\* owns the devices from here until someone stops it.
AfterConnect(s, i, ok) ==
    IF ~ok THEN CatchBegin(s, i)
    ELSE [s EXCEPT !.captureVar = i, !.audioOwners = @ \cup {i}, !.st[i].pc = "s_capture"]

\* 245-266: install the meeting (`installed = true` at 246), save it (status "recording" from Meeting.init or
\* resume()).  248 writes recordingTrigger from this start's trigger, "manual" when it has none.
RecorderCreate(s, i) ==
    LET fresh == s.st[i].rid = 0
        m == IF fresh THEN [id |-> s.nextId, status |-> "recording", ended |-> 0, sess |-> 1, capt |-> FALSE,
                            trig |-> s.st[i].trig]
             ELSE [s.st[i].res EXCEPT !.trig = s.st[i].trig]
    IN Save([s EXCEPT !.mem = m, !.nextId = IF fresh THEN @ + 1 ELSE @,
                      !.st[i].made = TRUE, !.st[i].pc = "s_connect"])

\* 244, continuation of `try await prepareSpeech()` when it had to warm the engine.
AfterPrep(s, i, ok) == IF ok THEN RecorderCreate([s EXCEPT !.speech = "warm"], i) ELSE CatchBegin(s, i)

\* 230-244.  `resumed` (235) is a copy taken here and installed only at 245.
RecorderBegin(s, i) ==
    LET rid  == s.st[i].rid
        snap == Snap(s, rid) IN
    IF rid # 0 /\ ~CanResume(snap)
    THEN EndStart([s EXCEPT !.errorText = TRUE], i)                                 \* 232-234
    ELSE LET res == IF rid # 0 THEN Resumed(snap) ELSE NoMeeting
             s1  == [s EXCEPT !.progress = 0, !.phase = "starting", !.errorText = FALSE, !.gen = @ + 1,
                              !.st[i].res = res, !.fin = Supersede(s, rid),         \* 237-241
                              !.hist.r3 = @ \/ ~RealGuard(s, rid)]
         IN CASE s.speech = "warm"    -> RecorderCreate(s1, i)                      \* 242, 244 do not suspend
              [] s.speech = "cold"    -> [s1 EXCEPT !.st[i].pc = "s_prep"]          \* 244 suspends in warm-up
              [] s.speech = "stalled" -> CatchBegin(s1, i)                          \* prepareSpeech throws at 193

-----------------------------------------------------------------------------
\* startCaptions()

\* 380-430, continuation of `await ZoomCaptions.read()`.  No look at `busy`, `phase` or `quitting`.
\* 390-397: a resume that is no longer possible silently becomes a fresh meeting.
\* 398: a resumed captions meeting keeps its recordingTrigger when this start has none.
\* 409: `captionTask` is overwritten without cancelling the previous loop.
CaptionsAfterRead(s, i, inMeeting) ==
    LET rid == s.st[i].rid IN
    IF FixRecheckBusy /\ ~Recheck(s, rid) THEN EndStart(s, i)
    ELSE IF ~inMeeting                                                              \* 380 -> refuse (371-375)
         \* at edcaebae this set phase = "error" even while a finalization owned the phase
         THEN LET s1 == [s EXCEPT !.phase = IF (FixRecheckBusy \/ FixRefuse) /\ Busy(s) THEN @ ELSE "error"] IN
              EndStart(IF FixRefuse /\ s.st[i].trig THEN Suppress(s1) ELSE s1, i)
    ELSE IF FixQuitRecheck /\ QuitStarted(s) THEN EndStart(s, i)                    \* 381
    ELSE LET snap     == Snap(s, rid)
             resumeOK == rid # 0 /\ CanResume(snap)
             late     == FixRecheckBusy \/ FixCaptionsResetLate
             \* For R3: the reset on entry (previous code) was this start's own reset of the progress its guard had looked at, not a sign
             \* that something else got in.  (Nothing else sets it to 0, and only a start that resets late
             \* can find it there otherwise.)
             mine     == [s EXCEPT !.progress = IF ~late /\ @ = 0 THEN 35 ELSE @]
             m == IF resumeOK THEN [Resumed(snap) EXCEPT !.capt = TRUE, !.trig = s.st[i].trig \/ snap.trig]
                  ELSE [id |-> s.nextId, status |-> "recording", ended |-> 0, sess |-> 1, capt |-> TRUE,
                        trig |-> s.st[i].trig]
         IN EndStart(Save([s EXCEPT !.gen = @ + 1, !.mem = m, !.nextId = IF resumeOK THEN @ ELSE @ + 1,
                           !.phase = "recording", !.captionVar = i, !.captionOwners[i] = s.gen + 1,
                           !.errorText = IF late THEN FALSE ELSE @,
                           !.progress = IF late THEN 0 ELSE @,
                           !.st[i].made = TRUE, !.fin = Supersede(s, rid),
                           !.hist.r3 = @ \/ ~RealGuard(mine, rid)]), i)

\* 368-380 up to the await.  Access (376) is assumed granted.  Up to and including the previous code, the
\* first line reset the progress and the error of whatever was going on, before anything was known about
\* whether this start would happen; the current code does that at 384, after the refusals.
CaptionsEnter(s, i) ==
    IF FixCaptionsResetLate THEN [s EXCEPT !.st[i].pc = "c_read"]
    ELSE [s EXCEPT !.progress = 0, !.errorText = FALSE, !.st[i].pc = "c_read"]

\* 227-229
Dispatch(s, i, captions) ==
    LET rid == s.st[i].rid IN
    IF captions /\ (rid = 0 \/ Snap(s, rid).capt) THEN CaptionsEnter(s, i) ELSE RecorderBegin(s, i)

\* 223, continuation of `await ZoomCaptions.read()` in start.
AfterRead(s, i, inMeeting) ==
    IF (FixRecheckBusy /\ ~Recheck(s, s.st[i].rid)) \/ (FixQuitRecheck /\ QuitStarted(s)) THEN EndStart(s, i)
    ELSE Dispatch(s, i, inMeeting)

\* 208-223.  Called only when the guard admits the call.  `startClaimed = true` (210) is `st[i].pc` leaving
\* "idle".  223 suspends only for source "auto" (with Accessibility trusted, which "auto" is taken to mean).
Enter(s, i, rid) ==
    LET s1 == [s EXCEPT !.st[i].rid = rid, !.st[i].with = InFlightStarts(s) \ {i},
                        !.used.fresh = IF rid = 0 /\ ~s.st[i].trig THEN @ + 1 ELSE @,
                        !.used.resume = IF rid # 0 THEN @ + 1 ELSE @]
    IN IF Source = "auto" THEN [s1 EXCEPT !.st[i].pc = "s_read"]
       ELSE Dispatch(s1, i, Source = "zoom-captions")

-----------------------------------------------------------------------------
\* stop(), fail(), prepareToQuit()

Target(s) == IF s.phase = "recording" THEN <<s.mem.id, s.mem.sess>> ELSE <<0, 0>>
\* 443: `let asked = phase == "recording" ? recordingGeneration : nil`.  0 stands for nil (a recording always
\* has a generation of at least 1).  Only kept when the code has that line.
Asked(s) == IF FixStopOwnSession /\ s.phase = "recording" THEN s.gen ELSE 0
StillRecording(s, t) == t # <<0, 0>> /\ s.mem.id = t[1] /\ s.mem.sess = t[2] /\ s.mem.status = "recording"

\* The stop() call returns to its caller.  For quit the caller is prepareToQuit (686), which then waits for the
\* title jobs (688) before Entry.swift:441 lets the app terminate.
Return(s, k) ==
    LET s1 == [s EXCEPT !.hist.r4 = @ \/ StillRecording(s, s.sp[k].target)] IN
    IF s.sp[k].kind = "quit" /\ QuitTail THEN [s1 EXCEPT !.sp[k].pc = "q_tail"]
    ELSE [s1 EXCEPT !.sp[k].pc = "done", !.terminated = @ \/ (s.sp[k].kind = "quit")]

\* 447-458.  edcaebae: `if let stopTask { await stopTask.value; return }`, then 451-458.
StopBody(s, k) ==
    IF ~MutNoStopJoin /\ s.stopTask # 0 /\ (FixStopLoop \/ ~FixStopJoin \/ s.fin[s.stopTask].pc # "done")
    THEN [s EXCEPT !.sp[k].pc = "join", !.sp[k].joined = s.stopTask]                \* 447-448
    ELSE IF s.phase # "recording" THEN Return(s, k)                                 \* 451
    ELSE IF FixStopOwnSession /\ s.sp[k].kind # "quit" /\ s.sp[k].asked # s.gen THEN Return(s, k)    \* 454
    ELSE [s EXCEPT !.fin[k].pc = "f_begin", !.stopTask = k, !.sp[k].pc = "await",   \* 455-458
                   !.fin[k].tgt = IF Extended THEN Target(s) ELSE <<0, 0>>,
                   \* a Stop that was not called on this session is about to stop it
                   !.hist.r11 = @ \/ (Extended /\ s.sp[k].kind # "quit" /\ s.sp[k].target # Target(s)),
                   \* a second finishRecording for a session that already had one
                   !.hist.r13 = @ \/ (Extended /\ \E f \in StopSlots : s.fin[f].tgt = Target(s))]

\* Entry of stop() (441), of fail() (590-593) and of prepareToQuit() (682-686).
StopEnter(s, k, kind) ==
    LET s1 == [s EXCEPT !.sp[k].kind = kind, !.sp[k].target = Target(s), !.sp[k].asked = Asked(s),
                        !.used.stop = IF kind = "stop" THEN @ + 1 ELSE @,
                        !.used.fail = IF kind = "fail" THEN @ + 1 ELSE @,
                        !.used.quit = IF kind = "quit" THEN @ + 1 ELSE @]
    IN IF kind = "fail"
       THEN LET s2 == [s1 EXCEPT !.errorText = TRUE] IN                             \* 592
            IF s.phase = "recording" THEN StopBody(s2, k) ELSE [s2 EXCEPT !.sp[k].pc = "done"]   \* 593
       ELSE StopBody(s1, k)

\* 448-449: the joined task has ended.  The current code clears stopTask when it is still that task and goes
\* round the loop; at edcaebae the call returned here.
JoinReturn(s, k) ==
    IF FixStopLoop THEN StopBody([s EXCEPT !.stopTask = IF @ = s.sp[k].joined THEN 0 ELSE @], k)
    ELSE IF FixStopJoin THEN StopBody(s, k) ELSE Return(s, k)

\* 458-459 `await task.value; if stopTask?.id == id { stopTask = nil }` (edcaebae: `stopTask = nil`)
AwaitReturn(s, k) == Return([s EXCEPT !.stopTask = IF (FixStopLoop \/ FixStopJoin) /\ @ # k THEN @ ELSE 0], k)

-----------------------------------------------------------------------------
\* finishRecording()

\* 524 and 546
StopGuard(s, f) == MutNoGenFence \/ (s.gen = s.fin[f].g /\ s.mem.id = s.fin[f].id /\ s.mem.ended = s.fin[f].at)

\* 549-563
Fin5(s, f) ==
    [s EXCEPT !.progress = 100, !.phase = IF s.errorText THEN "error" ELSE "ready",
              !.hist.r5a = @ \/ s.fin[f].sup,
              \* this stop saved its meeting as "interrupted" and is about to call the result "ready"
              !.hist.r15 = @ \/ (Extended /\ ~s.fin[f].sup /\ s.fin[f].id # 0 /\ s.mem.id = s.fin[f].id
                                  /\ s.mem.status = "interrupted" /\ ~s.errorText),
              !.fin[f].pc = "done", !.fin[f].ran = FALSE]

\* 543-546, continuation of the wait at 529.  ok = it did not throw.  The catch (543) writes errorText first;
\* the guard (546) comes after it.  At edcaebae there was no guard here at all.
F5(s0, f, ok) ==
    LET own  == StopGuard(s0, f)
        werr == ~ok /\ (own \/ ~FixCatchAfterGuard)
        s    == IF werr THEN [s0 EXCEPT !.errorText = TRUE, !.hist.r5d = @ \/ s0.fin[f].sup] ELSE s0
    IN IF (FixRecheckAfterFinalize \/ FixTailGuard) /\ ~own
       THEN [s EXCEPT !.fin[f].pc = "done", !.fin[f].ran = FALSE]
       ELSE Fin5(s, f)

\* What the closure handed to the wait at 529 checks before it calls finalize (531).
InnerOK(s, f) ==
    CASE FixRecheckAfterFinalize -> StopGuard(s, f)
      [] FixInnerGenCheck        -> s.gen = s.fin[f].g
      [] OTHER                   -> TRUE

\* 530-532 and MeetingRetention.swift:31-63: the closure, run by the worker task that RecordingDeadline.wait
\* spawns, and the synchronous part of finalize(id).  finalize's own guard (35-36) reads meetingSnapshot(id).
F4b(s, f) ==
    LET does == Snap(s, s.fin[f].id).ended # 0 /\ InnerOK(s, f) IN
    [s EXCEPT !.fin[f].pc = "f_finIndex", !.fin[f].ran = (MaxFinalizeErrors > 0 /\ does),
              !.hist.r5b = @ \/ (does /\ s.fin[f].sup)]

\* 519-529, continuation of `await NoteEnhancementScheduler.shared.finish(id, ...)`.
F4(s0, f) ==
    LET s == IF MutStatusAfterFinalPass /\ s0.mem.id # 0
             THEN Save([s0 EXCEPT !.mem.status = "complete", !.hist.r5c = @ \/ s0.fin[f].sup]) ELSE s0 IN
    IF ~StopGuard(s, f) THEN [s EXCEPT !.fin[f].pc = "done"]                       \* 524 return
    ELSE LET s1 == [s EXCEPT !.progress = 90] IN
         IF HasDocument THEN Fin5(s1, f)                                            \* 535-546 are synchronous
         ELSE [s1 EXCEPT !.fin[f].pc = "f_finWait"]                                 \* 529 suspends

\* 478-519, continuation of the drain (483).  stall = RecordingDeadline threw (487-492).
F3(s, f, stall) ==
    LET s1  == IF stall THEN [s EXCEPT !.errorText = TRUE, !.speech = "stalled", !.gen = @ + 1,
                                       !.used.stall = @ + 1] ELSE s
        has == s1.mem.id # 0
        m2  == IF has /\ ~MutFinishKeepsStatus
               THEN [s1.mem EXCEPT !.status = IF s1.errorText THEN "interrupted" ELSE "complete"] ELSE s1.mem
        s2  == Save([s1 EXCEPT !.mem = m2, !.progress = 35, !.hist.r5c = @ \/ (s.fin[f].sup /\ has)])
    IN IF has
       THEN [s2 EXCEPT !.fin[f].pc = "f_notes", !.fin[f].id = m2.id, !.fin[f].at = m2.ended, !.fin[f].g = s2.gen]
       ELSE Fin5(s2, f)                                                             \* `if let id` (518) is skipped

\* 475-477, continuations of capture.stop() and stopScreen() (folded into one).
F1(s, f) == [s EXCEPT !.audioOwners = @ \ {s.fin[f].cap}, !.fin[f].pc = "f_drain"]

\* 461-475, the first run of the task created at 456.  462: a stop the user (or a failure, or quit) asked for
\* suppresses the call; the monitor's own stop does not.
F0(s0, f) ==
    LET s   == IF s0.sp[f].kind # "auto" THEN Suppress(s0) ELSE s0
        has == s.mem.id # 0
        m2  == IF has THEN [s.mem EXCEPT !.status = IF MutFinishKeepsStatus THEN @ ELSE "finalizing",
                                         !.ended = s.clock + 1] ELSE s.mem
        cap == IF MutNoCaptureHandoff THEN 0 ELSE s.captureVar
    IN Save([s EXCEPT !.progress = 10, !.phase = "finalizing", !.mem = m2, !.clock = @ + 1,
                      !.captionOwners = IF s.captionVar # 0 THEN [@ EXCEPT ![s.captionVar] = 0] ELSE @,  \* 469-472
                      !.captionVar = 0,
                      !.fin[f].cap = cap, !.captureVar = IF MutNoCaptureHandoff THEN @ ELSE 0,          \* 473
                      !.fin[f].pc = "f_capStop", !.hist.r5c = @ \/ (s.fin[f].sup /\ has)])

-----------------------------------------------------------------------------
\* Actions

HasIdleStart == \E i \in StartSlots : st[i].pc = "idle"
LowestIdleStart == CHOOSE i \in StartSlots : st[i].pc = "idle" /\ \A j \in StartSlots : j < i => st[j].pc # "idle"
HasIdleStop == \E k \in StopSlots : sp[k].pc = "idle"
LowestIdleStop == CHOOSE k \in StopSlots : sp[k].pc = "idle" /\ \A j \in StopSlots : j < k => sp[j].pc # "idle"

OkValues == IF used.err < MaxStartErrors THEN {TRUE, FALSE} ELSE {TRUE}
WithErr(s, ok) == IF ok THEN s ELSE [s EXCEPT !.used.err = @ + 1]

\* Someone calls start(): the Start button and hotkey (RecorderView.swift:122, Entry.swift:397),
\* POST start / resume (LocalAPI.swift:81, 86), the Resume buttons (RecorderView.swift:286, 392).
\* rid = 0 is a fresh start.  Every caller's own precondition is implied by the guard at 208-209, and a call
\* the guard refuses changes nothing, so the call is modelled from the guard.
CallStart(rid) ==
    /\ ~terminated /\ HasIdleStart
    /\ IF rid = 0 THEN used.fresh < MaxFresh ELSE used.resume < MaxResume /\ CanResume(Snap(S, rid))
    /\ Admit(S, rid)
    /\ Set(Enter(S, LowestIdleStart, rid))

StartAfterRead(i)      == ~terminated /\ ~MutReadHangs /\ st[i].pc = "s_read" /\ \E b \in InMeetingValues : Set(AfterRead(S, i, b))
StartCaptionsRead(i)   == ~terminated /\ ~MutReadHangs /\ st[i].pc = "c_read" /\ \E b \in InMeetingValues : Set(CaptionsAfterRead(S, i, b))
StartAfterPrep(i)      == ~terminated /\ st[i].pc = "s_prep"      /\ \E ok \in OkValues : Set(AfterPrep(WithErr(S, ok), i, ok))
StartAfterConnect(i)   == ~terminated /\ st[i].pc = "s_connect"   /\ \E ok \in OkValues : Set(AfterConnect(WithErr(S, ok), i, ok))
StartAfterCapture(i)   == ~terminated /\ st[i].pc = "s_capture"   /\ \E ok \in OkValues : Set(AfterCaptureStart(WithErr(S, ok), i, ok))
StartAfterScreen(i)    == ~terminated /\ st[i].pc = "s_screen"    /\ Set(AfterScreen(S, i))
StartCatchFinish(i)    == ~terminated /\ st[i].pc = "s_catchStop" /\ Set(CatchFinish(S, i))
StartCatchClosed(i)    == ~terminated /\ (~MutCloseHangs \/ FixCloseBounded) /\ st[i].pc = "s_catchClose" /\ Set(CatchEnd(S, i))

\* Someone calls stop(): Stop button / hotkey / POST stop are kind "stop" (POST stop is also accepted while
\* "finalizing", LocalAPI.swift:89); a capture, track or pump failure calling fail() (264, 286, 291) is kind
\* "fail"; applicationShouldTerminate -> prepareToQuit is kind "quit" (refused while "starting",
\* RecordingQuit.swift:12).
CallStop(kind) ==
    /\ ~terminated /\ HasIdleStop
    /\ CASE kind = "stop" -> used.stop < MaxStop /\ (phase = "recording" \/ (phase = "finalizing" /\ stopTask # 0))
         [] kind = "fail" -> used.fail < MaxFail /\ phase \in {"recording", "starting"} /\ audioOwners # {}
         [] kind = "quit" -> used.quit < MaxQuit /\ phase # "starting"
    /\ Set(StopEnter(S, LowestIdleStop, kind))

StopJoinReturn(k)  == ~terminated /\ sp[k].pc = "join"  /\ fin[sp[k].joined].pc = "done" /\ Set(JoinReturn(S, k))
StopAwaitReturn(k) == ~terminated /\ sp[k].pc = "await" /\ fin[k].pc = "done"            /\ Set(AwaitReturn(S, k))
\* 688-693 and Entry.swift:437-441: the title jobs have been waited for; the app terminates.
QuitFinish(k)      == ~terminated /\ sp[k].pc = "q_tail" /\ Set([S EXCEPT !.sp[k].pc = "done", !.terminated = TRUE])

FinBegin(f)            == ~terminated /\ fin[f].pc = "f_begin"    /\ Set(F0(S, f))
FinCaptureStopped(f)   == ~terminated /\ fin[f].pc = "f_capStop"  /\ Set(F1(S, f))
FinDrained(f)          == ~terminated /\ fin[f].pc = "f_drain"
                          /\ \E stall \in (IF used.stall < MaxStall THEN {TRUE, FALSE} ELSE {FALSE}) : Set(F3(S, f, stall))
FinNotesDone(f)        == ~terminated /\ ~MutFinalPassHangs /\ fin[f].pc = "f_notes" /\ Set(F4(S, f))
FinFinalizeSync(f)     == ~terminated /\ fin[f].pc = "f_finWait"  /\ Set(F4b(S, f))
\* The wait can only throw when finalize was really entered: vault unavailable (MeetingRetention.swift:52), a
\* receipt or transcript that cannot be written (60-61), or the watchdog after 30 s in indexFinalNote (64).
FinFinalizeReturned(f) ==
    /\ ~terminated /\ fin[f].pc = "f_finIndex"
    /\ \E ok \in (IF fin[f].ran /\ used.finErr < MaxFinalizeErrors THEN {TRUE, FALSE} ELSE {TRUE}) :
          Set(F5(IF ok THEN S ELSE [S EXCEPT !.used.finErr = @ + 1], f, ok))

\* 412 / 415: a caption loop whose generation is no longer current ends itself.
CaptionTick(o) ==
    /\ ~terminated /\ captionOwners[o] # 0 /\ captionOwners[o] # gen
    /\ captionOwners' = [captionOwners EXCEPT ![o] = 0]
    /\ UNCHANGED <<phase, progress, gen, errorText, speech, mem, disk, nextId, clock, stopTask, captureVar,
                   captionVar, audioOwners, st, sp, fin, used, hist, terminated, call, pol>>

\* --- the auto-record monitor (checkCall 165-191, every 2 s; cancelled by prepareToQuit at 684) ---

\* A call starts being detected.
CallBegins == ~terminated /\ MaxAuto > 0 /\ ~call /\ used.calls < MaxCall
              /\ Set([S EXCEPT !.call = TRUE, !.used.calls = @ + 1])

\* AutoRecordPolicy.update (29-35) answers .start: the call has settled, nothing is busy, it has not been asked
\* for and is not suppressed.  176-186 create a Task; the latch `requestedStart` is set now.
MonitorAsks ==
    /\ ~terminated /\ MaxAuto > 0 /\ call /\ ~pol.sup /\ ~pol.req /\ ~Busy(S) /\ ~QuitStarted(S)
    /\ used.auto < MaxAuto /\ HasIdleStart
    /\ Set([S EXCEPT !.pol.req = TRUE, !.used.auto = @ + 1,
                     !.st[LowestIdleStart].pc = "m_task", !.st[LowestIdleStart].trig = TRUE])

\* That Task runs: start(trigger:) from its guard.  A refused start returns at once, and 185 follows.
MonitorTaskRuns(i) ==
    /\ ~terminated /\ st[i].pc = "m_task"
    /\ Set(IF Admit(S, 0) THEN Enter(S, i, 0) ELSE EndStart(S, i))

\* The call has been gone for two minutes (37-41): the policy forgets it, and when the recording is an
\* automatic one, 188 creates a Task that stops it without suppressing anything.
CallEnds ==
    /\ ~terminated /\ MaxAuto > 0 /\ call /\ HasIdleStop
    /\ LET s1 == [S EXCEPT !.call = FALSE, !.pol = [req |-> FALSE, sup |-> FALSE]] IN
       IF phase = "recording" /\ mem.trig /\ ~QuitStarted(S)
       THEN Set([s1 EXCEPT !.sp[LowestIdleStop].pc = "m_stop", !.sp[LowestIdleStop].kind = "auto"])
       ELSE Set(s1)

\* That Task runs stop(userInitiated: false) from its first line (443).
MonitorStopRuns(k) ==
    /\ ~terminated /\ sp[k].pc = "m_stop"
    /\ Set(StopBody([S EXCEPT !.sp[k].target = Target(S), !.sp[k].asked = Asked(S)], k))

Init ==
    /\ phase = "ready" /\ progress = 0 /\ gen = 0 /\ errorText = FALSE /\ speech = SpeechInit
    /\ mem = NoMeeting /\ disk = [m \in MeetingIds |-> NoMeeting] /\ nextId = 1 /\ clock = 0
    /\ stopTask = 0 /\ captureVar = 0 /\ captionVar = 0 /\ audioOwners = {}
    /\ captionOwners = [i \in StartSlots |-> 0]
    /\ st = [i \in StartSlots |-> IdleStart] /\ sp = [k \in StopSlots |-> IdleStop]
    /\ fin = [k \in StopSlots |-> IdleFin]
    /\ used = [fresh |-> 0, resume |-> 0, stop |-> 0, fail |-> 0, quit |-> 0, err |-> 0, stall |-> 0,
               finErr |-> 0, auto |-> 0, calls |-> 0]
    /\ hist = [r3 |-> FALSE, r4 |-> FALSE, r5a |-> FALSE, r5b |-> FALSE, r5c |-> FALSE, r5d |-> FALSE,
               r7 |-> FALSE, r11 |-> FALSE, r13 |-> FALSE, r15 |-> FALSE]
    /\ terminated = FALSE /\ call = FALSE /\ pol = [req |-> FALSE, sup |-> FALSE]

Next ==
    \/ \E rid \in {0} \cup MeetingIds : CallStart(rid)
    \/ \E i \in StartSlots : StartAfterRead(i)
    \/ \E i \in StartSlots : StartCaptionsRead(i)
    \/ \E i \in StartSlots : StartAfterPrep(i)
    \/ \E i \in StartSlots : StartAfterConnect(i)
    \/ \E i \in StartSlots : StartAfterCapture(i)
    \/ \E i \in StartSlots : StartAfterScreen(i)
    \/ \E i \in StartSlots : StartCatchFinish(i)
    \/ \E i \in StartSlots : StartCatchClosed(i)
    \/ \E kind \in {"stop", "fail", "quit"} : CallStop(kind)
    \/ \E k \in StopSlots : StopJoinReturn(k)
    \/ \E k \in StopSlots : StopAwaitReturn(k)
    \/ \E k \in StopSlots : QuitFinish(k)
    \/ \E f \in StopSlots : FinBegin(f)
    \/ \E f \in StopSlots : FinCaptureStopped(f)
    \/ \E f \in StopSlots : FinDrained(f)
    \/ \E f \in StopSlots : FinNotesDone(f)
    \/ \E f \in StopSlots : FinFinalizeSync(f)
    \/ \E f \in StopSlots : FinFinalizeReturned(f)
    \/ \E o \in StartSlots : CaptionTick(o)
    \/ CallBegins \/ MonitorAsks \/ CallEnds
    \/ \E i \in StartSlots : MonitorTaskRuns(i)
    \/ \E k \in StopSlots : MonitorStopRuns(k)

\* "Awaits return": every continuation eventually runs.  Calls by the environment are not forced.
Fairness ==
    /\ \A i \in StartSlots :
          /\ WF_vars(StartAfterRead(i)) /\ WF_vars(StartCaptionsRead(i)) /\ WF_vars(StartAfterPrep(i))
          /\ WF_vars(StartAfterConnect(i)) /\ WF_vars(StartAfterCapture(i)) /\ WF_vars(StartAfterScreen(i))
          /\ WF_vars(StartCatchFinish(i)) /\ WF_vars(StartCatchClosed(i)) /\ WF_vars(CaptionTick(i))
          /\ WF_vars(MonitorTaskRuns(i))
    /\ \A k \in StopSlots :
          /\ WF_vars(StopJoinReturn(k)) /\ WF_vars(StopAwaitReturn(k)) /\ WF_vars(QuitFinish(k))
          /\ WF_vars(MonitorStopRuns(k))
          /\ WF_vars(FinBegin(k)) /\ WF_vars(FinCaptureStopped(k)) /\ WF_vars(FinDrained(k))
          /\ WF_vars(FinNotesDone(k)) /\ WF_vars(FinFinalizeSync(k)) /\ WF_vars(FinFinalizeReturned(k))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Properties

\* A caption loop created under an older generation is fenced (412, 415) and ends within one poll;
\* it is not counted as an owner.  AudioCapture objects are never fenced, so every one counts.
LiveOwners == Cardinality(audioOwners) + Cardinality({o \in StartSlots : captionOwners[o] # 0 /\ captionOwners[o] = gen})

R1a_OneCaptureOwner    == LiveOwners <= 1
R1b_OneRecordingOnDisk == Cardinality({m \in MeetingIds : disk[m].status = "recording"}) <= 1

StartInFlight == \E i \in StartSlots : st[i].pc \notin {"idle", "done"}
StopInFlight  == \E k \in StopSlots : sp[k].pc \in {"join", "await", "m_stop"} \/ fin[k].pc \notin {"idle", "done"}

R2_NoOrphan ==
    (phase \in {"ready", "error"} /\ ~StartInFlight /\ ~StopInFlight)
        => \A m \in MeetingIds : disk[m].status \notin {"starting", "recording", "finalizing"}

\* A start only commits (phase := "starting" at 239, or a captions meeting at 387-402) in a state where the
\* `!busy || ...` part of its own guard holds.  hist.r3 is set at the commit when it does not: another start
\* (or a stop) got in between the guard and the commit, and both go on to own a meeting.
R3_NoDoubleStart == ~hist.r3

R4_StopNotSwallowed == ~hist.r4
R5a_SupersededNeverSetsPhase == ~hist.r5a
R5b_SupersededNeverFinalizes == ~hist.r5b
R5c_SupersededNeverWritesStatus == ~hist.r5c
\* R5d (added for the current code): ... nor the error the new session will be judged by.
R5d_SupersededNeverSetsError == ~hist.r5d

\* R6 exactly as asked: every accepted stop (a finishRecording task in flight) reaches ready or error.
InFlight(f) == fin[f].pc \notin {"idle", "done"}
R6_AcceptedStopSettles ==
    \A f \in StopSlots : InFlight(f) ~> (phase \in {"ready", "error"} \/ terminated)
\* R6 with the one legitimate exception: a resume took the meeting back to recording.
R6r_AcceptedStopSettlesUnlessResumed ==
    \A f \in StopSlots : InFlight(f) ~> (phase \in {"ready", "error"} \/ fin[f].sup \/ terminated)

\* R7: a start that fails never rewrites a meeting it had not installed.
R7_FailedStartSparesOtherMeetings == ~hist.r7
\* R8: recording with an error recorded means a stop is under way.
R8_FailureStopsRecording ==
    (phase = "recording" /\ errorText) => (stopTask # 0 \/ \E k \in StopSlots : sp[k].pc \in {"join", "await"})
\* R9: the app never terminates while a meeting is still recording or finalizing on disk.
R9_QuitLeavesNothingRecording ==
    terminated => \A m \in MeetingIds : disk[m].status \notin {"recording", "finalizing"}

\* --- added for the current code: what the fixes might have introduced ---

\* R10: every start call returns, so `startClaimed` is always released.  (Liveness: it holds exactly as long as
\* every await inside start returns.)
R10_StartReturns ==
    \A i \in StartSlots : (st[i].pc \notin {"idle", "done"}) ~> (st[i].pc = "done" \/ terminated)

\* R11: a stop() only ever stops the session it was called on.  (Quit is exempt: it stops whatever records.)
R11_StopOnlyItsOwnSession == ~hist.r11

\* R12: the monitor's latch is never left set with nothing to show for it: a call in progress, not suppressed,
\* already "asked for", while nothing is recording or starting and nothing is on its way.
R12_AutoStartNotStuck ==
    ~(call /\ pol.req /\ ~pol.sup /\ phase \in {"ready", "error"} /\ ~StartInFlight /\ ~QuitStarted(S) /\ ~terminated)

\* R13: finishRecording runs at most once for a session.
R13_OneFinishPerSession == ~hist.r13

\* R14: every stop() call returns (the loop at 447-450 neither spins nor waits for ever).
R14_StopReturns ==
    \A k \in StopSlots : (sp[k].pc \in {"join", "await", "m_stop"}) ~> (sp[k].pc \in {"done", "q_tail"} \/ terminated)

\* R15: a stop that saved its meeting as "interrupted" does not end by calling the result "ready".
R15_InterruptedStopEndsInError == ~hist.r15

TypeOK ==
    /\ phase \in {"ready", "starting", "recording", "finalizing", "error"}
    /\ progress \in {0, 10, 35, 90, 100}
    /\ speech \in {"warm", "cold", "stalled"}
    /\ stopTask \in {0} \cup StopSlots /\ captureVar \in {0} \cup StartSlots
    /\ audioOwners \subseteq StartSlots
    /\ call \in BOOLEAN /\ pol \in [req : BOOLEAN, sup : BOOLEAN]
=============================================================================
