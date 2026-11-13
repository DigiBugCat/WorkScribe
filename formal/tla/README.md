# TLA+ models of three WorkScribe state machines

Three `@MainActor` state machines of the app, each cut into atomic steps exactly at its `await`s,
and checked with TLC so that every interleaving of those steps is tried.

| Spec | Machine |
|---|---|
| `Recording.tla` | recording lifecycle: `phase`, start / stop / resume / fail / quit, `stopTask`, the generation fence, the auto-record monitor |
| `Retention.tla` | retention journal and purge of one meeting, with crashes |
| `NoteScheduler.tla` | `NoteEnhancementScheduler` for one meeting, with the AppModel code that drives it |

## Which code

Each spec describes more than one version of the code, chosen by constants:

* **edcaebae** — git commit `edcaebae96a0f6a34ff891cbac2a0004c4f7ac7c` (branch `codex-backend`). The
  models were first written against it and found the defects listed below.
* **current** — the working tree on top of that commit, read on 2026-11-11. `git rev-parse HEAD`
  is still `edcaebae96a0f6a34ff891cbac2a0004c4f7ac7c`: **the fixes are uncommitted changes**, so
  there is no commit id that names the code the "current" results are about.
* **previous** — the working tree as it was when this follow-up started: the first round of
  fixes, without the later rounds that were written in answer to it (four changes in
  `AppModel.swift`; then `MeetingRetention.swift`, `MeetingNotes.swift` and two more places in
  `AppModel.swift`; then one more condition in `MeetingRetention.swift`).

**Since the models were last read against the code (12 November 2026): all-day screen reading.**
`MeetingRetention.swift` and `MeetingNotes.swift` are unchanged. `AppModel.swift` gained lines above
the code these models describe, so its line numbers in the specs and in this document are now low
by 17 (`busy`) to 23 (`start` and everything after it; 24 after `prepareToQuit`'s `await stop`).
`start`, `startCaptions`, `stop`, `finishRecording` and `fail` are otherwise as modelled. Two things
did change in what they call, and neither needs a new configuration:
* `startScreen()` suspends again (it awaits `ScreenWatcher.beginMeeting`). The current-code
  configurations already have `ScreenCapture = TRUE`, which was kept as the harder case; it is now
  simply the code, and the re-check after it (R8) is what makes that safe.
* `prepareToQuit` awaits `shutdownScreen()` between `stop` and the wait for the title jobs. No start
  can begin there (`quitting` is set), and the specs already treat the tail of quit as a step
  (`QuitTail = TRUE`).
`AppModel+Screen.swift` (`startScreen`, `stopScreen`) was rewritten; what it does to the recording
lifecycle is the two awaits above. The screen's own decisions are `ScreenWatch.tla`, unchanged.

**Later the same day: `MeetingRetention.done` changed**, so the sentence above about
`MeetingRetention.swift` no longer holds for that function. Between journalling "purging" and
`RetentionStore.purge` it now (a) takes WorkScribe's markers out of the note through
`VaultStore.removeMarkers`, which cannot throw, and (b) purges the index in a loop, each pass one
transaction, and that purge can now fail when a checkpoint is blocked. To `Retention.tla` this is the
step it already had there (the index purge, between the journal entry and the deletion of the files),
and a purge that fails at that step is the interrupted purge the model already replays (T5). No
configuration of `Retention.tla` was changed. The finer steps, and what they got wrong, are in
`IndexPurge.tla` and `VaultNote.tla` (`IndexPurge-VaultNote.md`). This equivalence is by reading: the
line numbers this document gives for `done` are stale.

The files the current models describe (working tree):

| Spec | Files the current model describes (working tree) |
|---|---|
| `Recording.tla` | `Sources/WorkScribe/AppModel.swift`, `AppModel+Screen.swift`, `RecordingQuit.swift`, `RecordingDeadline.swift`, `Entry.swift`, `LocalAPI.swift`, `RecorderView.swift`, `ZoomCaptions.swift`, `Runtime.swift`, `MeetingRetention.swift` (finalize); `Sources/WorkScribeCore/RecordingSession.swift`, `AutoRecordPolicy.swift` |
| `Retention.tla` | `Sources/WorkScribe/MeetingRetention.swift`, `AppModel.swift`, `MeetingNotes.swift`, `IndexService.swift`, `LocalAPI.swift`; `Sources/WorkScribeCore/Retention.swift`, `Meeting.swift`, `RecordingSession.swift`, `Search/MeetingIndexer.swift`, `Search/SearchIndexVectors.swift`, `Engine/Index.swift`, `Engine/Line.swift`, `Vault/VaultStore.swift` |
| `NoteScheduler.tla` | `Sources/WorkScribe/MeetingNotes.swift`, `AppModel.swift`, `MeetingRetention.swift`, `LocalAPI.swift`, `CurrentNoteEngine.swift`; `Sources/WorkScribeCore/Engine/Line.swift` |

Every action in the specs carries the Swift line range it stands for, **in the current files**; the
step tables below give the edcaebae lines next to them. If those lines move, re-read the action
before trusting a result.

**What was checked is the model, not the Swift.** A violation is a hypothesis about the app until
it is replayed in a test; each one says which lines to drive and how sure I am that the real app
can get there. A "holds" is a guarantee about the model inside the stated bound only. Ten of the
counterexamples (seven from edcaebae, three found by this follow-up) have since been replayed as
XCTest cases against the real classes (`Tests/WorkScribeTests/RecordingRaceTests.swift`,
`RetentionRaceTests.swift`); the tables say which. I read those tests; I did not run them (a build was not allowed while this was written).

## The code as fixed (current)

What the models say about the working tree as it stands now. The fixes came in four rounds, all
uncommitted on top of `edcaebae`: the first answered the edcaebae findings; the second (four
changes in `AppModel.swift`) and the third (`MeetingRetention.swift`, `MeetingNotes.swift`, two
more places in `AppModel.swift`) answered what this follow-up found on the first; the fourth (one
condition in `MeetingRetention.swift`) answered what it found on the third. "Previous" in a
configuration name is the first round alone. Line numbers are the current files'. "Real" means
every step of the trace is a straight reading of the Swift; "artifact" means the model allows
something the app cannot do.

Short form:

| | Fails on | Real or artifact | Fix | State |
|---|---|---|---|---|
| T5 (e) | current | real, no timing | (`deleteRecording` would have to remove scoped conversations) | **open on purpose**: a product decision |
| T5 (b′) | current | real given a damaged file | none small | open |
| T5 (c), (f) | current | by necessity / by design | – | open |
| T9, one corner | current | real, a triple fault | – | the accepted price of how T5 (b″) was closed |
| N1, N1s in a recorder resume | current | real, transient | – | open, closes by itself |
| N8, one trace | current | artifact: the model has no clock | none needed | – |
| T7, three traces | the first round | real; needed a slow index hop | re-check after `done`'s own finalize | found by this follow-up, **then fixed**; no replay (the test harness has no slow index) |
| T5 (b″) | the first round | real, a triple fault | stale skip judged on disk | found by this follow-up, **then fixed** |
| T5, an interrupted purge that was not replayed | the third round; introduced by its T7 re-check | real, needed two things at once | a receipt that already says "purging" skips `done`'s finalize branch | found by this follow-up, **then fixed**; **replayed**: `RetentionRaceTests.testAnInterruptedPurgeIsCarriedOutEvenIfTheNoteWasReopenedInMemory` |
| N1, N1s, N5 when a resumed start fails | the first round | real, low impact | `schedule` in start's catch | found by this follow-up, **then fixed** |
| N7 | the first round and edcaebae | real | `dirty.insert(id)` at the two "resumed?" returns | found by this follow-up, **then fixed**; **replayed**: `RecordingRaceTests.testAPassThatGivesUpAtAResumeLeavesItsWorkToBeAskedForAgain` |
| R11 | the first round | real; introduced by the R4 fix | `stop` remembers what it was asked of | found by this follow-up, **then fixed**; **replayed**: `RecordingRaceTests.testAStopPressedDuringTheFinalPassDoesNotEndARecordingResumedSince` |
| R5d, R8 | the first round | real, narrow | guard before the error is recorded | found by this follow-up, **then fixed** |
| R9 (`auto`, `zoom-captions`) | the first round | real, low frequency | `quitting` again after the read | found by this follow-up, **then fixed** |
| R15 | the first round and edcaebae | mechanism real; the modelled route an artifact | resets after the refusals | found by this follow-up, **then fixed** |
| (R10 with a recognizer queue that never answers) | the first two rounds | real | bounded wait for `closeStreams` | noted by this follow-up, **then fixed** |

The three replays were, as reported, seen to fail with the fix removed and pass with it. I read
the tests and did not run them.

### Still open

**T5 — what still keeps raw data past its deadline.** One
`Retention_current_T5_…__violates_T5_EventuallyPurged` configuration each; `Retention_current_T5__holds`
and its neighbours are the same environment without the hazard.
* **(e), not fixed, on purpose:** a meeting moved to the Trash before it was ever finalized leaves
  the conversations scoped to it (`AppModel.swift:758-769` leaves them, and with no receipt no
  purge ever runs). Real, no timing involved. Closing it means deleting someone's chat history
  when they trash a recording, which is a product decision left to the owner.
* **(b′), real given a damaged file:** a transcript that stops decoding before the meeting has a
  receipt is not listed (`Meeting.swift:144`), so it is never finalized and never purged.
* **(c), by necessity:** without an index nothing is purged. The message at
  `MeetingRetention.swift:72` no longer promises a retry on launch; a Done asked for while the
  index is missing is not remembered, and the meeting fades at its normal deadline.
* **(f), by design:** if `finalize` fails every time (no vault), a meeting that was never
  finalized, or whose receipt is stale, is never purged.

**T9, one corner — the price of how T5 (b″) was closed.** T9 is new: a purge that the 60 s loop
starts (not one asked for with Done) never starts before the 24 h deadline of the meeting's last
stop. It is the property the skip at `MeetingRetention.swift:146` exists for, and it holds
(`Retention_current_T5__holds`, `…_document__holds`, `…_note_opened_later__holds`,
`Retention_current_note_opened_later__holds`) with one exception, 12 states,
`Retention_current_unreadable_resumed_meeting_purged_on_first_clock__violates_T9_…`: stop
(finalized), resume, stop again with that stop's finalize failing, the first stop's deadline
passes, and the transcript on disk stops decoding while the meeting is still `model.meeting`. The
skip at 146 now reads the disk, finds nothing to read and does not skip; `done` sees the stale
receipt through the copy in memory (76), finalizes from it (81, which also rewrites the
transcript) and purges at once: on the first session's deadline, which is earlier than the
second's. Real, but it takes three faults at once, and the session is in the note before
anything is deleted (T7 holds). The alternative was the same meeting never being purged at all
(T5 (b″)); I would leave it.

**N1, N1s in a recorder resume — real, transient.** `start` resets the pressure at
`AppModel.swift:241` and calls `schedule` at 311 (or, since the third round, at 353 when it
fails), with the awaits of start in between (speech warm-up, connect, `capture.start`). In that
window a dirty meeting, or one with input that arrived while AI lines were paused, has no pass
queued (N1, 11 states; N1s, 7 states:
`NoteScheduler_current_start_awaits_…__violates_N1…` / `…N1s…`). It always closes by itself
now; with that window excused (`N1x`, `N1sx`) the properties hold. A captions resume has no such
window (384-403 is one step).

**N8, one trace — artifact.** N8 is the claim behind `MeetingNotes.swift:250`: the `schedule` call
at the tail of `finishRecording` (`AppModel.swift:553`) queues nothing the stop's own successful
final pass already read. It holds when no 3 s retry is pending
(`NoteScheduler_current_tail_schedule__holds`) and fails without line 250. One 22-state trace is
left (`…current_retry_fires_in_paused_final_pass__violates_N8…`): a retry (294-298) armed after an
earlier stop fires during the final pass of a later stop while AI lines are paused, resets
`inputs[id]`, and the tail queues one redundant pass. The model has no clock: in the app this
needs a resume, six seconds of recognition lag and a stop inside the retry's three seconds.

**R6** as literally asked still fails by design (a resume takes the meeting back to recording);
**N3** as literally asked still fails benignly (a jot rewritten after the final snapshot).

### Found by this follow-up on the first round of fixes, then fixed

Each is kept as a `…_previous_…__violates_…` configuration, and each fix is modelled as written.
"Against the sketch" compares the code with the switch I had proposed.

**T7 — `done` re-checked "recording now?", not "is what I finalized still the last stop?". Real;
it needed a slow index hop.** Three traces, one mechanism. The user asks for Done on a meeting
that sends `done` into its finalize branch (76: no receipt, a stale one, or an open document).
`done` finalizes (81) and waits inside `finalize` at `await index.indexFinalNote`
(`MeetingRetention.swift:64`). Then: *(note opened later, 9 states)* Resume, the plugin opens the
note (`LocalAPI.swift:110-116`), Stop, which does not finalize a meeting with a document and
moves the receipt's `endedAt` to the new stop (`AppModel.swift:535-540`); or *(failing finalize, 8
states)* Resume, Stop, and that stop's own finalize throws; or *(undo, 6 states)* the plugin
undoes the finalize (`LocalAPI.swift:122-135`). `done` woke, its re-check passed (the meeting had
an end and was idle again), and it journalled "purging": the purge deleted a session, or a
finalization, that the note did not hold.
*Fix as written* (`MeetingRetention.swift:83-89`): the first guard as before, now binding
`latest`; then `guard !Self.predates(try receipts.load(id), lastStopOf: latest),
latest.document?.finalized != false else { throw }`.
*Against the sketch* (`FixDoneRecheckStale`): **the same**, including a flaw I had not seen in
the sketch (the interrupted purge below, since fixed by the fourth round). It re-reads the receipt from disk and judges it against
the same snapshot the first guard used; an open document throws, no document or a finalized one
passes. T7 now holds with a failing finalize, an undone finalize and a note
opened later all allowed (`Retention_current_wide__holds`, `…_document__holds`,
`…_note_opened_later__holds`), and reverting just this guard brings it back
(`Retention_current_without_stale_recheck_in_done__violates_T7…`). One consequence to know: when
it throws for a Done the *user* asked for, nothing retries that Done; the meeting is finalized
again by the 60 s loop and fades at its deadline. For a Done the loop started, the loop retries.
No replay: the test harness builds `MeetingRetention` with `index: nil`, so `finalize` never
suspends there.

**T5 — an interrupted purge was not replayed while the note was open again in memory. Introduced
by the third round's re-check at `MeetingRetention.swift:87-89` (and my sketch for it had the same
flaw). Real, low probability.**
Trace (`Retention_current_without_replay_rule_document_interrupted_purge__violates_T5_EventuallyPurged`,
17 to 22 states, depending on where TLC's liveness check stops): a meeting with a plugin document
is stopped and finalized; the user asks for Done; `done` journals "purging" (96) and waits (107,
108); meanwhile the plugin undoes the finalize (`LocalAPI.swift:122-135`): the save is refused by
the store fence (`Meeting.swift:121`), but `mutateMeeting` has already put the changed copy in
`model.meeting` (`MeetingNotes.swift:35-36`), so in memory the document is open again; then the
index purge throws (108) and `done` leaves with the receipt at "purging". From then on, every
minute: the last loop of `recover` called `done`; the branch condition saw an open document and
sent it into the finalize branch; `finalize` returned at once because the receipt said purging
(34); the first re-check (83) passed; the second (87) found `latest.document?.finalized == false`
and threw. The transcript stayed on disk under a "purging" receipt until the app was relaunched
or another meeting became `model.meeting`. It needed a purge interrupted with the app still
running (the index purge at 108 or the note clean-up at 99-104 throwing) *and* the note re-opened
in memory while that purge was waiting (an undo as above; or the plugin opening the note of a
meeting that had no document, whose guard at `LocalAPI.swift:112` also reads the copy in memory).
The first-round code did not have it: its re-check passed and the purge was replayed
(`Retention_previous_document_interrupted_purge_note_reopened__holds`, the same environment).
*Fix as written* (`MeetingRetention.swift:76`): `known?.state != "purging"` now comes first in
the branch condition, so a purge that is already journalled never enters the finalize branch,
whichever of the three reasons would have sent it there.
*Against the sketch* (`FixReplaySkipsFinalize` guarded only the open-document reason): **the
same.** `known == nil` cannot be true of a purging receipt, and `predates` returns false unless
the receipt's state is "finalized" (117-120), so the open document was the only reason that could
apply. It also covers the `openDocument` variant, which I had only read: the condition does not
look at how the document came to be open. T5 holds again in that environment, failing index
purge included, with T6, T7 and T9 (`Retention_current_T5_document__holds`). A side effect in the
right direction: `finish` is no longer run on a meeting whose purge is being replayed.
**Replayed on the real code, fixed:**
`RetentionRaceTests.testAnInterruptedPurgeIsCarriedOutEvenIfTheNoteWasReopenedInMemory`. It sets
up what the interruption leaves behind (a "purging" receipt on disk, the meeting on screen with
an unfinalized document in memory), runs `recover()` and expects "purged" with the transcript
gone. It does not replay the index purge throwing.

**T5 (b″) — a resumed meeting, unreadable on disk while still in memory, was never purged. Real,
a triple fault.** Trace (11 states): stop (finalized), resume, stop with a failing finalize, the
transcript on disk stops decoding while the meeting is still `model.meeting`. The first loop saw
a "finalized" stand-in and left it alone; the last loop skipped the receipt because it predated
the copy in memory. For ever, until a relaunch or the next recording.
*Fix as written* (`MeetingRetention.swift:142-146`): "still recording" is still judged by the
snapshot (`if let snapshot = model.meetingSnapshot(receipt.id), snapshot.endedAt == nil
{ continue }`); the stale-receipt skip is judged by the copy on disk
(`predates(receipt, lastStopOf: try? model.store.load(receipt.id))`).
*Against the sketch:* I had offered "drop the skip, or apply it to the copy on disk"; this is the
second, **as proposed**. Checked: (b″) is closed
(`Retention_current_T5_unreadable_resumed_meeting_in_memory__holds`; the first-round code still
fails it, `Retention_previous_T5_…__violates_T5…`). Nothing else opens: T6 and T7 hold with the
skip reading the disk (`Retention_current_wide__holds`, `…_document__holds`,
`…_note_opened_later__holds`), because the "still recording" check still reads memory and `done`
applies the stale rule to the copy in memory at 76 whatever the loop decided. Your reason for
keeping the skip is what T9 states, and the model agrees: without the skip T7 still holds, but
T9 fails (`Retention_current_without_stale_rule_in_recover__violates_T9…`). The one place where
the skip now does not protect T9 is the (b″) meeting itself, above.

**N1, N1s, N5 when a resumed start failed — nobody called `schedule`. Real, low impact.** A
resumed start that failed in its catch never reached `AppModel.swift:311`, and the stop it had
interrupted had given up without its tail; a dirty meeting, or one with unseen input, stayed
that way until `recover`'s final pass within the minute
(`NoteScheduler_previous_resumed_start_fails__violates_N1x…`, `…N1sx…`, `…N5…`).
*Fix as written* (`AppModel.swift:350-353`): right after `phase = "error"`,
`if let id = meeting?.id { NoteEnhancementScheduler.shared.schedule(id, model: self) }`.
*Against the sketch* (`FixCatchSchedules`): **the same where the sketch applied, and stronger.**
Not being conditional on `installed`, it also covers a resume that fails *before* its meeting is
installed (a stalled recognizer throws at 193 after 241 has already taken a new generation and
reset the pressure); the model now has that step (`ResumeFailsEarly`) and N1x, N1sx, N5 hold with
both kinds of failure (`NoteScheduler_current_start_awaits__holds`, `…_liveness__holds`). The
other side of "not conditional": a *fresh* start that fails asks the scheduler about whatever
meeting is on screen, its own failed empty one or the previous one. That is a no-op unless that
meeting has unseen input, in which case a pass is what it needed. Harmless.

**N7 — a pass that gave up because of a resume dropped the work it had taken. Real; also at
edcaebae.** Trace (8 states): speech arrives and a pass starts (or Stop's final pass takes it
over); Stop; Resume; the pass returned at its "resumed?" guard; nothing marked the meeting dirty
again, and the `schedule` at `AppModel.swift:311` did nothing because the inputs had not changed.
The jots waited for the next transcript line or edit.
*Fix as written* (`MeetingNotes.swift:288`, 306): `dirty.insert(id)` before both `return false`.
*Against the sketch* (`FixRequeueSuperseded`): **the same.** N7 holds
(`NoteScheduler_current__holds`, `…_start_awaits__holds`); without it,
`NoteScheduler_current_without_requeue__violates_N7…`. Those two guards also fire when only
`endedAt` changed (a live pass still in flight when Stop arrives): the meeting is then left
dirty for the final pass, which clears it; nothing new opens (N2, N4, N5, N6, N8 hold).
**Replayed on the real code, fixed:**
`RecordingRaceTests.testAPassThatGivesUpAtAResumeLeavesItsWorkToBeAskedForAgain`.

**R11 — a Stop from before a Resume stopped the resumed recording. Real; introduced by the R4
fix.** Trace (16 states, `recorder`; 12 for captions): recording; Stop #1 creates the finish task;
Stop #2 arrives while that task is in flight and joins it; the first stop reaches its final pass;
Resume takes the meeting back to "recording" (session 2); the first stop gives up at its guard
(524); Stop #2 woke, went round the loop, found `phase == "recording"` (451), true of session 2
by then, and stopped it. It needed a second `stop()` issued before the Resume: two presses inside
one main-actor turn (the button is disabled outside "recording", `RecorderView.swift:282`), the
hotkey twice, `POST stop` twice (accepted while "finalizing", `LocalAPI.swift:89`), or the
monitor's `.stop` Task (188) behind a manual Stop.
*Fix as written* (`AppModel.swift:443`, 454, 686): `let asked = phase == "recording" ?
recordingGeneration : nil` on entry, and after the loop `guard whateverRecords || asked ==
recordingGeneration`; `prepareToQuit` passes `whateverRecords: true`.
*Against the sketch* (`FixStopOwnSession` compared meeting id and session index): **the same in
every reachable case.** Every start that commits takes a new generation in the same step (241,
387), and the only other writer of the generation (the stalled drain, 490) runs while the phase
is "finalizing"; so with the phase "recording", the same generation is the same session and the
other way round. `asked` is taken when `stop()` runs, which for the button, the hotkey and the
monitor's Task is one hop after the decision; nothing can be resumed in that hop.
**Replayed on the real code, fixed:**
`RecordingRaceTests.testAStopPressedDuringTheFinalPassDoesNotEndARecordingResumedSince`. It
replays the variant where the second Stop arrives while the first is finishing (`asked == nil`).
The variant where both Stops are asked of the same recording and the generation tells them apart
after the resume is checked by the model only: the tests' resume does not go through
`start(resuming:)` and so does not change the generation.

**R5d, R8 — an old stop wrote its error into the resumed session. Real, narrow.**
Trace (13 / 17 states): Stop; `finishRecording` passes its guard (524) and waits in the last wait
(529); its closure passes the generation check (531) and calls `finalize`; Resume (239
`errorText = nil`, 241, … 309 "recording"); the wait throws (no vault, `MeetingRetention.swift:52`;
a write failure, 60-61; or the wait's own 30 s watchdog, `RecordingDeadline.swift:30`); the `catch`
set `errorText` and only then the guard saw the resume. The resumed recording carried an error
with nobody stopping it: pressure stuck at `.transcriptDelayed` (743), saved "interrupted" at its
own Stop (509); or, if the error landed before 309, the resumed start failed on it (295 / 308).
*Fix as written* (526, 543-547): the catch keeps its text in a local; `errorText` is set from it
only after the guard at 546. *Against the sketch* (`FixCatchAfterGuard`): **the same.**

**R9 for `auto` and `zoom-captions` — Quit while a start was reading Zoom. Real, low frequency.**
Trace (5 states): `start()` passes 208-209, claims (210) and suspends in `ZoomCaptions.read()` (223,
or 380 in `startCaptions`), phase still "ready"; Quit is accepted (`RecordingQuit.swift:12` only
refuses while "starting"), `prepareToQuit` sets `quitting` (683), its `stop` finds nothing to stop,
688 waits for the title jobs; the read returns and the start committed without looking at
`quitting`; the app terminated with a meeting "recording" on disk. Not for `recorder` (no await
between the guard and "starting").
*Fix as written* (225, 381): `guard !quitting else { return }` after each read. *Against the sketch*
(`FixQuitRecheck`): **the same, one order differs:** in `startCaptions` the refusal for "Zoom isn’t
in a meeting" (380) comes before the quit check, so a start caught by a quit that also finds Zoom
out of a meeting still shows its refusal and suppresses the call. Harmless.

**R15 — a refused captions resume wiped the error of the stop in progress. Mechanism real; the
modelled route an artifact. Also at edcaebae.**
Trace (11 states): a captions meeting is stopped and its stop records an error (saved
"interrupted", 509); Resume entered `startCaptions`, whose first line reset
`finalizationProgress` and `errorText` before the read; Zoom was not in a meeting, the start was
refused; the stop's tail (554) said "ready", "Recording saved on this Mac". The reset before the
await was a straight reading. The error in TLC's trace comes from a stalled drain, which a
captions meeting cannot have in the app (it has no pumps): that part is an artifact of a model
that lets any meeting stall; the error the app could lose was the failed save at 512. The same
line also hid the Resume button until the stop set 0.9.
*Fix as written* (384): the two resets moved to after both refusals and the quit check.
*Against the sketch* (`FixCaptionsResetLate`): **the same.** They sit before `await pauseImports()`
(386) and the new generation (387); in a Plaud build with an import running that await suspends
between the two, which the model does not have.

**`startClaimed` held by a `closeStreams` that never answers. Real; not a property failure before,
because R10 is stated for awaits that return.** The catch of `start` awaited
`runtime.closeStreams()` with the claim still held and the phase already "error". That call
queues behind the recognizer (`Runtime.swift:43-51`), and a stalled recognizer is how a start
gets into that catch; if it never answered, no start was accepted until relaunch.
*Fix as written* (`AppModel.swift:354-356`): `try? await RecordingDeadline.wait(stall:
stallTimeout) { await self.runtime.closeStreams() }`.
*Against what I suggested* (release the claim before that await): **different, and weaker in one
respect.** The start now returns whatever `closeStreams` does: with `closeStreams` never answering,
R10 holds (`Recording_current_mutation_close_streams_hangs__holds`), and without the wrap it
fails (`Recording_current_without_bounded_close_mutation_close_streams_hangs__violates_R10…`).
But the claim is still held while it waits, so for up to `stallTimeout` (30 s) after such a
failed start, Start is offered and does nothing. R10 still depends on the other awaits in
`start` returning (`ZoomCaptions.read()`: `Recording_current_mutation_read_hangs_auto__violates_R10…`).

With all of this in, the current-code configurations have no failing property in Recording
except R6 as literally asked (`Recording_current_recorder__holds` 1,230,347 / 43,
`…auto…` 3,106,984 / 46, `…captions…` 36,952 / 34, each
with every safety property R1 to R15, and the three `…_liveness__holds`), none in Retention
except T5's four open hazards ((e), (b′), (c), (f)) and the T9 corner, and none in NoteScheduler except the transient
N1 / N1s window, the N8 artifact and N3 as literally asked.

### Fixes that hold as written

| Finding | Fix in the code | Result on the current-code model |
|---|---|---|
| R3 double start | `startClaimed`, `AppModel.swift:208-210` | holds for `auto` and `zoom-captions` (and R1, R2 with it) |
| R4 swallowed Stop | the loop in `stop`, 447-459 | holds |
| R5a old stop sets the phase | guard at 546 | holds |
| R5b old stop finalizes | generation check at 531 | holds, cold speech engine included |
| R5d, R8 old stop's error | local at 526, 543-547 | hold |
| R7 failed start marks another meeting failed | `installed`, 246 / 349 | holds |
| R8 failure during `startScreen` | re-check at 308 | holds (and `startScreen` no longer suspends) |
| R9 quit over a recording | `quitting`, 208 / 683, with the R4 fix; 225 / 381 | holds, all three sources |
| R10 with a silent recognizer queue | bounded wait, 354-356 | holds |
| R11 stale Stop | `asked`, 443 / 454 | holds |
| R15 refused captions resume | resets at 384 | holds |
| stuck auto-record latch | `startDidNotBegin`, 185 | holds (R12), all three sources |
| T1, T3, T4 Finalize overwrites "purging" | receipt check, `MeetingRetention.swift:34` | hold |
| T5 (a) trashed finalized meeting, (b) unreadable transcript with a receipt | last loop of `recover`, 142 | hold |
| T5 (b″) | stale skip on disk, 146 | holds |
| T5 replay of an interrupted purge | `known?.state != "purging"`, 76 | holds |
| T5 (d) resume then crash | `retention == "live"` in the first loop, 124 | holds |
| T5 (c) "purging" journalled without an index | index check first, 72 | the journal no longer lies; the purge still waits for an index, by necessity |
| index rows of a trashed meeting | `MeetingIndexer.swift:49`, `AppModel.swift:767` | holds (T8) |
| T6 purged while recording | re-check at 83 | holds |
| T7 purge on a stale receipt | `predates`, 76 and 146; re-check at 87-89 | holds |
| N4 final pass settles a resumed meeting | guard at `MeetingNotes.swift:286-288` | holds |
| N5 `draining` left set | `draining.remove` before the guard, 186 | holds |
| N6 untracked live pass | token, 154-156 | holds |
| N7 abandoned work | `dirty.insert`, 288 / 306 | holds |
| N1 / N5 pressure reset without schedule (tail) | `AppModel.swift:553` | holds |
| N1s pressure reset without schedule (resume) | `AppModel.swift:311`, 403; in the catch, 353 | holds, apart from the transient window above |

### Where the code is weaker or stronger than the switch it implements

| Code | Against the sketch | |
|---|---|---|
| `startClaimed` (208-210) | `FixRecheckBusy` re-checked the guard after the awaits | **Different mechanism.** *Weaker:* after 223 / 380 only `quitting` is looked at again. *Stronger:* while one start is anywhere between its guard and its return, every other start, a Resume included, returns at 208 without a word, including during the wait for `closeStreams` at 356, when the phase is already "error" and Start is offered (bounded at 30 s since the third round). The sketch also moved the resets in `startCaptions`; the code now does too (384) |
| `quitting` (208, 683; 225, 381) | `FixQuitBlocksStart` refused while a quit waited in `stop()` | *Stronger:* covers the whole of `prepareToQuit`, and since the second round a start already past 208 |
| loop in `stop` (447-459), `asked` (443, 454) | `FixStopJoin`; `FixStopOwnSession` | **Same.** A joiner also clears `stopTask` when it is still the task it joined (449), so it is not only the owner that clears it; harmless (R13, R14 hold). The loop neither spins nor deadlocks, and `finishRecording` never runs twice for one session. `asked` compares generations where the sketch compared sessions: the same in every reachable case |
| generation check in the closure (531) | `FixRecheckAfterFinalize` used the full guard there | **Same in the model:** a resume changes the generation in the step in which it commits (241, 387) |
| guard at 546, local at 526 / 547 | `FixRecheckAfterFinalize`; `FixCatchAfterGuard` | **Same** |
| re-check at 308; `installed` | `FixFailRecheck`; `FixCatchOwn` | **Same** |
| `refuse` (371-375) | part of `FixRecheckBusy` | **Same for the phase; more:** an automatic start that is refused suppresses the call, so an automatic `zoom-captions` start that finds Zoom not yet in a meeting is not tried again for that call |
| bounded `closeStreams` (354-356) | I suggested releasing the claim first | **Different; weaker in one respect** (Start does nothing for up to 30 s), see above |
| `schedule` in the catch (353) | `FixCatchSchedules` | **Same, and stronger:** not conditional on `installed`, so it also covers a resume that fails before installing |
| `finalize` receipt check (34) | `FixFinalizeChecksReceipt` | **Same.** It does not break "Done finalizes first": `done` only reaches `finalize` with a "purging" receipt when replaying an interrupted purge, and then goes on to purge |
| index check at 72 | T5 (c) | **Stronger for the journal;** an explicit Done is not remembered across a relaunch, and the message now says so |
| re-check at 83 | `FixDoneRecheck` re-checked right before the journal, on every path | **Same for T6** (the other path has no await). It also throws for a meeting that cannot be read, with the "Recording resumed" message |
| re-check at 87-89 | `FixDoneRecheckStale` | **Same.** The flaw it shared with the sketch (it refused the replay of a purge already journalled when the document in memory was open) is ended by the rule at 76 |
| `known?.state != "purging"` (76) | `FixReplaySkipsFinalize` guarded only the open-document reason | **Same:** the other two reasons cannot apply to a purging receipt |
| `predates` in `done` (76) | none | **New; closes the reported T7** |
| `predates` in `recover`, on disk (146) | I offered "drop it, or judge it on disk" | **As proposed (the second).** Not needed for T7 (76 covers it); needed for T9, which it keeps except for the (b″) meeting |
| `retention == "live"` (124); last loop (142) | `FixRecoverLive`; `FixL116` | **Same** |
| nil-branch guard (`MeetingNotes.swift:286-288`) | `FixNilBranchFence` | **Same, and stricter:** it returns before the 3 s retry is armed |
| `dirty.insert` at 288 / 306 | `FixRequeueSuperseded` | **Same** |
| `draining.remove` first (186); token (154-156) | `FixFinishDraining`; `FixNoSteal` | **Same** |
| `schedule` at `AppModel.swift:553` | `FixUnpauseSchedules` | **Same** |
| `schedule` at `AppModel.swift:311`, 403 | `FixUnpauseSchedules` scheduled where the pressure is reset (241) | **Weaker for a recorder resume** only in the transient window above |
| final run records its inputs (250) | none | **New.** Does what it is for (N8) |

## Every property, three ways

"edcaebae" and "current" are model results. "Replayed" is about the real code: *replayed, fixed*
means an XCTest drives the counterexample on the real classes and, as reported by its author,
failed on the old code the way the trace said and passes now. *Fixed following the model, not
replayed* means the code was changed because of the trace and only the model says it is closed;
the phrase after it is what a replay would need.

| | Property | at edcaebae | in the current code | replayed on the real code |
|---|---|---|---|---|
| R1 | One capture owner; one meeting "recording" on disk | violated | **holds** | no (a consequence of R3 and R5a) |
| R2 | Idle phase ⇒ nothing saved as recording / finalizing | violated | **holds** | no (same) |
| R3 | A start only commits while its own guard still holds | violated (`auto`, `zoom-captions`) | **holds** | fixed following the model, **not replayed**: needs two `start()` calls inside one `ZoomCaptions.read()`, a real Accessibility read of Zoom that suspends |
| R4 | A `stop()` does not return while the recording it was called on continues | violated | **holds** | **replayed, fixed**: `RecordingRaceTests.testASecondStopAfterAResumeStopsTheResumedRecording` |
| R5a | A superseded `finishRecording` never sets `phase` | violated | **holds** | **replayed, fixed**: `RecordingRaceTests.testTheTailOfAnOldStopDoesNotDeclareAResumedRecordingReady` (the test skips itself when its window is not hit) |
| R5b | … never finalizes retention | violated (corner cases) | **holds** | not replayed: needs a resume suspended in a cold speech engine's warm-up |
| R5c | … never overwrites the resumed meeting's status | holds | holds | – |
| R5d | … never writes `errorText` (added) | violated (inside R5a) | **holds** (violated after the first round; found here, then fixed) | no |
| R6 | Every accepted stop reaches ready or error | violated by design; `R6r` holds | the same | open by design |
| R7 | A start that fails never rewrites a meeting it had not installed | violated | **holds** | fixed following the model, **not replayed**: needs `prepareSpeech()` to throw (the speech engine failing to warm, or a stalled recognizer) while another meeting is on screen |
| R8 | Recording with an error recorded ⇒ a stop is under way | violated | **holds** (after the first round: violated through R5d; found here, then fixed) | fixed following the model, **not replayed**: needs a capture failure while `startScreen` is suspended, and in the working tree `startScreen` no longer suspends |
| R9 | The app never terminates with a meeting recording on disk | violated | **holds** (after the first round: only for `recorder`; found here, then fixed) | fixed following the model, **not replayed**: needs the terminate path (`applicationShouldTerminate`, `RecordingQuit`) on top of the R4 situation; the join it went through is what the R4 test replays |
| R10 | Every `start()` returns, so `startClaimed` is released (added) | holds | holds, as long as every await inside start returns; the wait for `closeStreams` in the catch now always does | – |
| R11 | A `stop()` only stops the session it was called on (added) | holds | **holds** (violated after the first round, introduced by the R4 fix; found here, then fixed) | **replayed, fixed**: `RecordingRaceTests.testAStopPressedDuringTheFinalPassDoesNotEndARecordingResumedSince` |
| R12 | The auto-record latch is never left set with nothing to show for it (added) | violated | **holds** | no (a Lean lemma covers the policy alone: `formal/lean/Formal/AutoRecord.lean`) |
| R13 | `finishRecording` runs at most once per session (added) | not kept as a configuration (an exploratory run found it violated only through the R5a defect, 30 states deep) | holds | – |
| R14 | Every `stop()` returns (added) | holds | holds | – |
| R15 | A stop that saved "interrupted" does not end in "ready" (added) | violated (`zoom-captions`) | **holds** (violated after the first round; found here, then fixed) | no |
| T1 | Nothing is deleted unless the receipt says purging | violated (through T4) | **holds** | through the T4 test |
| T2 | Receipt purged ⇒ no folder, no index rows, no scoped conversation | holds | holds | – |
| T3 | Once purging, a deleted folder and fenced index rows do not come back | violated (through T4) | **holds** | through the T4 test |
| T4 | The receipt never goes from purging back to finalized | violated | **holds** | **replayed, fixed**: `RetentionRaceTests.testFinalizeNeverOverwritesAPurgeInProgress` (skips itself when its window is not hit) |
| T5 | After the deadline the raw data is eventually gone | violated by (a) to (e) | (a), (b), (b″), (d): **holds**, and so does the replay of an interrupted purge (broken by the third round's T7 re-check; found here, then fixed). (c): the journal no longer lies; the purge still waits for an index. **(e): still violated, not fixed, on purpose.** Also (b′) and, by design, (f) | (a) **replayed, fixed**: `RetentionRaceTests.testAFinalizedMeetingMovedToTheTrashIsStillPurgedAtItsDeadline`; (d) **replayed, fixed** with T7; the interrupted purge **replayed, fixed**: `RetentionRaceTests.testAnInterruptedPurgeIsCarriedOutEvenIfTheNoteWasReopenedInMemory` (from the state the interruption leaves; not the index purge throwing); (b), (b″), (c) fixed following the model, not replayed (need a transcript that does not decode; an app launched without an index); **(e) open** |
| T6 | A meeting being recorded is never purging or purged | violated | **holds** | fixed following the model, **not replayed**: needs `finalize` to suspend inside `done`, which only a real `IndexService` makes it do (the tests build `MeetingRetention` with `index: nil`) |
| T7 | A purge never starts while the transcript records a stop the note does not hold | violated | **holds** (after the first round: three traces left, with a resumed session or an undo inside `done`'s own finalize; found here, then fixed) | the reported trace **replayed, fixed** (with T5 (d)): `RetentionRaceTests.testAResumedThenInterruptedMeetingIsFinalizedAgainBeforeAnyPurge`; the three later traces fixed following the model, **not replayed** (the test harness has no slow index) |
| T8 | The index rows of a meeting whose folder is gone do not stay (added; "the index-rows part of T5 (a)") | violated | **holds** | **replayed, fixed**: `RetentionRaceTests.testATrashedMeetingsRowsLeaveTheIndex` |
| T9 | A purge the 60 s loop starts never starts before the deadline of the meeting's last stop (added) | violated (it is T7's trace) | **holds**, except for a resumed meeting that is unreadable on disk and still in memory (the price of closing T5 (b″)) | no |
| N1 | Dirty and nothing paused, draining or finalizing ⇒ a pass is queued or running | violated | **holds** when a resume is one step; in the exact model of a recorder resume, violated transiently between `AppModel` 241 and 311 (after the first round also for good when that start failed; found here, then fixed) | fixed following the model, **not replayed**: needs AI lines paused at the moment of Stop (recognition 6 s behind a running capture) and a jot edit while the final pass is suspended; the end state is the absence of a later pass |
| N1s | The same for an input the scheduler never marked dirty | violated | as N1 | fixed following the model, **not replayed**: needs the same pause and then a Resume through `start(resuming:)`, i.e. a capture and a speech connection that reach "recording" |
| N2 | At most one `run` in flight | holds | holds | – |
| N3 | `finish` returning true (no resume) ⇒ no line listening or found | violated benignly; `N3e` holds | the same | – |
| N4 | A pass from before a resume never changes a line | violated | **holds** | **replayed, fixed**: `RecordingRaceTests.testAFinalPassThatFoundNothingDoesNotSettleAResumedMeeting` |
| N5 | A dirty meeting is eventually processed or paused | violated | **holds** (after the first round: not when a resumed start failed; found here, then fixed) | fixed following the model, **not replayed** (as N1) |
| N6 | The final pass is never skipped because another run is in flight | violated | **holds** | fixed following the model, **not replayed**: needs `schedule`, `yieldLive`, `schedule` to run before the first task's body gets its turn, then Stop while the untracked pass is in flight |
| N7 | Work a pass had taken and then dropped because of a resume is picked up again (added) | violated | **holds** (violated after the first round too; found here, then fixed) | **replayed, fixed**: `RecordingRaceTests.testAPassThatGivesUpAtAResumeLeavesItsWorkToBeAskedForAgain` |
| N8 | The `schedule` call at the tail of `finishRecording` queues a pass only for input the final pass did not read (added) | not applicable (no such call) | holds, apart from one trace that needs a 3 s timer to outlast a resume and a stop | – |

Four notes on the replays, from reading the tests:

* `RecordingRaceTests` resumes by calling `Meeting.resume()` and setting the phase, without audio
  and without going through `start(resuming:)`, so `recordingGeneration` does not change in them.
  The old stop therefore gives up on the `endedAt` (and session) half of its guards; the
  generation half is exercised only by the model.
* Two tests (`testTheTailOfAnOldStopDoesNotDeclareAResumedRecordingReady`,
  `testFinalizeNeverOverwritesAPurgeInProgress`) depend on hitting a window between two task hops
  and call `XCTSkipUnless` when they miss it. A run that reports them as skipped has not replayed
  the trace.
* `RetentionRaceTests` builds `MeetingRetention` with `index: nil, requiresIndex: false`. That is
  why T6 and the three later T7 traces cannot be replayed with it: they need `finalize` to
  suspend. For the same reason the interrupted-purge test does not replay the interruption (the
  index purge throwing with the app still running); it starts from what the interruption leaves.
* The R11 replay is the variant in which the second Stop arrives while the first is finishing
  (`asked == nil`). The variant in which both Stops are asked of the same recording, and only the
  generation tells the resumed session from the first, is checked by the model alone (see the
  first note).

## Re-running

```sh
cd formal/tla
./run.sh                    # every configuration, one at a time: the 186 described here, and the 57 of the
                            # three later specs (IndexPurge-VaultNote.md, PluginNote.md)
JOBS=4 ./run.sh             # four at a time: under half an hour on a 14-core Apple Silicon Mac
./run.sh Retention          # one spec
./run.sh Recording_current  # any name prefix
./run.sh -l                 # list configurations
```

`run.sh` only runs the three specs described here (other specs in this directory have their own
scripts). It uses `/opt/homebrew/opt/openjdk/bin/java` and
`~/Library/Caches/WorkScribe/formal/tla2tools.jar` (TLA+ tools 1.8.0, sha256
`e1f11b75…bcd7f`; override with `JAVA=` / `TLA_JAR=`). TLC's state files go to a temporary
directory outside the repository. One configuration by hand:

```sh
java -XX:+UseParallelGC -cp ~/Library/Caches/WorkScribe/formal/tla2tools.jar tlc2.TLC \
  -workers 1 -noGenerateSpecTE -metadir "$(mktemp -d)" \
  -config Retention_current_without_replay_rule_document_interrupted_purge__violates_T5_EventuallyPurged.cfg Retention.tla
```

The file name says which code and what to expect:

* `<Spec>_edcaebae_…` — the code at edcaebae, exactly as it was first modelled. The 74 original
  configurations are all still here under this prefix or the next, with the verdicts recorded
  then; 71 of them have exactly the distinct-state count recorded then (see "Every run" for the
  other three).
* `<Spec>_candidate_…` — edcaebae plus the fix *sketches* its findings were first checked against.
  They are not the code and never were.
* `<Spec>_previous_…` — the first round of fixes only: the traces this follow-up found on it,
  which the later rounds then fixed.
* `<Spec>_current_…` — the working tree: the fixes as they were actually written.
  `current_without_<fix>` reverts one of them, `current_mutation_<what>` breaks one thing, and
  `current_plus_candidate(s)` adds sketches for what is still open.
* `…__holds.cfg` must pass; `…__violates_<Property>.cfg` must produce a violation of exactly that
  property. `run.sh` exits 0 only when every configuration behaves as its name says. A property
  that fails on the current code is recorded as a `current_…__violates_…` configuration.

Counterexamples are written to `traces/<cfg>.txt` (expected violations run with one worker, so
breadth-first search returns the same shortest trace every time).

Each spec has three kinds of constant. All of them `FALSE` (and the environment refinements off)
is the code at edcaebae.

* **Fixes as written** — what is in the working tree, modelled the way it was written, including
  where that differs from the sketch it came from.
* **Sketches** — not in the code: the ones from the edcaebae round, and a few for what the
  current code leaves open. They show that a small change would close a finding in the model;
  they are not reviewed patches.
* `Mut…` — a deliberately broken variant, used to show a passing property is able to fail.

## How the code is cut into steps

A `@MainActor` method runs uninterrupted until it really suspends. An `await` on same-actor code
that returns without suspending is not a step boundary, so the models only split where the callee
can suspend, and say when that depends on the environment (`prepareSpeech` suspends only when the
engine is cold; `pauseImports` only in a Plaud build with an import running, which is not
modelled). `Task { … }` bodies are separate steps from the code that creates them. TLC does not
know that the main actor usually runs jobs in arrival order, or how long anything takes, so some
traces need an ordering or a duration that is unlikely in practice; the confidence notes say so
where it matters.

One boundary changed with the code: `await startScreen()` (`AppModel.swift:306`) suspended at
edcaebae (`ScreenRecorder.start` was async). In the working tree the screen recorder has been
replaced by `ScreenWatcher`, whose `start()` is synchronous, so that await no longer suspends. The
current-code configurations keep the suspension (`ScreenCapture = TRUE`): it is the harder case,
and everything that holds with it holds without it.

---

# Machine 1 — recording lifecycle (`Recording.tla`)

## Code covered

Current line numbers. `Sources/WorkScribe/AppModel.swift`: `busy` 127, `checkCall` 165-191,
`prepareSpeech` 192-206, `start` 207-365, `startCaptions` 368-430, `stop` 441-460, `finishRecording`
461-563, `fail` 590-594, `prepareToQuit` 682-694, `save` 726. `Sources/WorkScribe/RecordingQuit.swift`
8-16. `Sources/WorkScribe/LocalAPI.swift` 76-91. `Sources/WorkScribe/Entry.swift` 395-398, 429-442.
`Sources/WorkScribe/RecorderView.swift` 122, 276-282, 283-290, 392. `Sources/WorkScribeCore/RecordingSession.swift`
20-38. `Sources/WorkScribeCore/AutoRecordPolicy.swift` 5-43. `Sources/WorkScribe/MeetingRetention.swift`
31-65 as called from `AppModel.swift:532`. `Sources/WorkScribe/AppModel+Screen.swift` 20-59.
`Sources/WorkScribe/RecordingDeadline.swift` 7-34. `Sources/WorkScribe/ZoomCaptions.swift` 24-31, 92-104.
`Sources/WorkScribe/Runtime.swift` 43-51.

## Step-to-code mapping

| Action in the spec | Swift, current | at edcaebae |
|---|---|---|
| `CallStart(rid)` (`Enter`) | `start` 208-223 (guard 208-209, `startClaimed = true` 210); suspends at 223 only for source `auto` | 198-207 |
| `StartAfterRead` | 223 continuation, the `quitting` check at 225, 227-229 | 207, 208-209 |
| `RecorderBegin` | 230-244 (`phase = "starting"` 239, new generation 241) | 211-225 (220, 222) |
| `StartAfterPrep` | 244 continuation when the speech engine had to warm up | 225 |
| `RecorderCreate` | 245-266 (`meeting = resumed ?? Meeting(…)` 245, `installed = true` 246, `save()` 250) | 226-246 |
| `StartAfterConnect` | 266-294 (`self.capture = capture` 290, `capture.start` 294) | 247-274 |
| `StartAfterCapture` | 294-306 (`if let errorText { throw }` 295) | 274-286 |
| `StartAfterScreen` | 306 continuation, the re-check at 308, 309 `phase = "recording"` | 286, 287 |
| `CatchBegin` / `StartCatchFinish` | 342-345 / 345-356 (`if installed` 349) | 318-321 / 321-327 |
| `StartCatchClosed` | 356 continuation (`await runtime.closeStreams()`), 358-364 | 327-333, not a step then |
| `CaptionsEnter` | `startCaptions` 368-380 | 339-344 (with the resets at 339) |
| `StartCaptionsRead` | 380 continuation through 430: `refuse` 371-375, the `quitting` check 381, the resets 384, new generation 387, `phase = "recording"` 402 | 344-389 |
| `CaptionTick` | the caption loop's fence at 412 and 415 | 371, 374 |
| `CallStop("stop" / "fail" / "quit")` | `stop` 441-458 (`asked` 443, the loop 447-450, the guards 451 and 454); `fail` 590-593; `prepareToQuit` 682-686 after `RecordingQuit.request` | 399-404; 524-527; 616-619 |
| `StopJoinReturn` | 448-449, then round the loop | 400 `await stopTask.value; return` |
| `StopAwaitReturn` | 458-459 | 404-405 |
| `QuitFinish` | `prepareToQuit` 687-693, then `Entry.swift:437-441` | 620-626, `Entry.swift:446-449`, not a step then |
| `FinBegin` | `finishRecording` 461-475 | 407-421 |
| `FinCaptureStopped` | 475 and 477 continuations | 421, 423 |
| `FinDrained` | 478-519 (stall branch 487-492, status at 509, progress 0.35 at 514) | 424-465 |
| `FinNotesDone` | 519-529 (the guard at 524) | 466-474 (470) |
| `FinFinalizeSync` | the closure 530-532 and `MeetingRetention.finalize` 31-63 | `finalize` 31-60 inside the await at 474 |
| `FinFinalizeReturned` | the catch 543, the guard 546, `errorText` 547, 549-563 | 486-497 |
| `CallBegins`, `MonitorAsks`, `MonitorTaskRuns`, `CallEnds`, `MonitorStopRuns` | `checkCall` 165-191 (the `.start` Task 181-186 with line 185, the `.stop` Task 188); `AutoRecordPolicy.swift` 14-42 | 163-181 (177, 178), not modelled then |

## Abstractions

* Audio, speech and files are reduced to: the in-memory `meeting` (id, status, endedAt, session
  count, captions or not, automatic or not), the same record on disk as last written by `save()`,
  the `capture` and `captionTask` variables, and the set of capture owners actually alive.
* `endedAt` values are distinct stamps; `recordingGeneration` is a counter.
* `startClaimed` (96) and `quitting` (98) are not variables of the model. The first is set right
  after the guard and reset by a `defer`, so it is true exactly while a start call is between its
  guard and its return; the second is set at 683 and never reset. Both are read off the call
  records (`Claimed`, `QuitStarted`). `asked` (443) is kept per stop call.
* `canResume()` is reduced to "has an endedAt and status is complete or interrupted"; the
  ten-minute window, retention state and `document.finalized` are left to `Retention.tla`.
* The two `connect()` awaits (microphone, system) are one. `stopScreen` is folded into the
  capture-stop step. Notifications, titles, levels, voice tasks and imports are left out; so
  `await pauseImports()` (242, 386) is not a step, which in a Plaud build with an import running
  it would be. `save()` never throws here (so the failed save at 512 and `refuse` after a failed
  save at 401 are not in the model).
* Source `auto` means "auto with Accessibility trusted" (otherwise line 223 does not suspend and
  `auto` behaves like `recorder`). `phase == "preview"` (QA demo) is left out.
* `fail()` is only called while an `AudioCapture` exists (its three callers need one). A drain may
  stall for any meeting, although a captions meeting in the app has nothing to drain (this is what
  makes the R15 trace partly an artifact).
* The last wait of `finishRecording` (529) may throw only when `finalize` was really entered: no
  vault, a receipt or transcript that cannot be written, or its 30 s watchdog.
* A caption loop from an older generation is not counted as a capture owner: it is fenced at 412
  and 415 and ends within one 250 ms poll. `AudioCapture` objects are never fenced, so all count.
* The auto-record policy keeps its two flags (`requestedStart`, `suppressed`); its settle and grace
  timers are things the environment decides. One call at a time, one call name. The monitor's
  start is always a fresh start: the trigger-based pick-up of an interrupted call (217-219) is
  covered by the explicit resume, as before. `autoRecordCalls` being switched off is not modelled.
* Quit: `prepareToQuit`'s wait for the title jobs (688) is a step; the app terminates after it.
  Relaunch recovery is in `Retention.tla`.

## Bound

2 fresh starts, 1 resume, 2 stops, 1 capture failure, 1 quit, 1 throwing start step, 1 stalled
drain, 1 throwing finalize; screen capture on. The three liveness properties are checked with 1
fresh start for `recorder`, and with 1 fresh start, no capture failure and no stall for `auto`
(TLC's liveness check costs about ten seconds per 100,000 states and property). The monitor
configurations: 2 automatic starts, 1 manual start, 1 resume, 1 stop, 1 quit, 1 throwing start
step, with 2 calls and 1 capture failure for `zoom-captions`, 1 call and none for the other two.
Every trace found is 5 to 17 steps.

## Results

Sizes are distinct states / search depth, from the run recorded under "Every run".

| | Property | At edcaebae | In the current code |
|---|---|---|---|
| R1 | At most one capture owner; at most one meeting "recording" on disk | **violated** for every source (recorder: only through R5; auto / captions: through R3) | holds |
| R2 | When phase is ready or error and nothing is in flight, no saved meeting is recording or finalizing | **violated** for every source (same causes) | holds |
| R3 | A start only commits while the `!busy \|\| …` part of its own guard still holds | holds for `recorder`; **violated** for `auto` and `zoom-captions` | holds |
| R4 | A `stop()` called on a recording does not return while that recording continues | **violated** | holds |
| R5a | A superseded `finishRecording` never sets `phase` | **violated** (holds for meetings with a plugin document) | holds |
| R5b | … never finalizes retention | **violated** only in corner cases (cold speech engine with `auto`, or a resume that itself fails) | holds |
| R5c | … never overwrites the resumed meeting's status | holds for `recorder` | holds |
| R5d | … never writes `errorText` | **violated** (it was part of R5a) | holds; *previous:* **violated** |
| R6 | Every accepted stop reaches ready or error | as literally stated: **violated by design**. With that one exception (`R6r`): holds | the same; `R6r` holds for all three sources |
| R7 | A start that fails never rewrites a meeting it had not installed | **violated** | holds |
| R8 | Recording with an error recorded means a stop is under way | **violated** | holds; *previous:* **violated** through R5d |
| R9 | The app never terminates with a meeting still recording on disk | **violated** | holds; *previous:* **violated** for `auto` and `zoom-captions` |
| R10 | Every `start()` returns | holds | holds, also with a `closeStreams` that never answers |
| R11 | A `stop()` only stops the session it was called on | holds (239,984 / 30) | holds; *previous:* **violated** |
| R12 | The auto-record latch is not left set with nothing recording, starting or on its way | **violated** | holds (`recorder` 67,081 / 43, `auto` 390,982 / 48, `zoom-captions` 2,573,129 / 51) |
| R13 | `finishRecording` runs at most once per session | not kept (see the table above) | holds |
| R14 | Every `stop()` returns | holds | holds |
| R15 | A stop that saved its meeting as "interrupted" does not end in "ready" | **violated** for `zoom-captions` | holds; *previous:* **violated** for `zoom-captions` and `auto` |

Current code, every safety property in one configuration per source: `recorder`
1,230,347 / 43, `auto` 3,106,984 / 46, `zoom-captions`
36,952 / 34. Liveness (R6r, R10, R14): `recorder`
149,776 / 33, `auto` 12,764 / 32,
`zoom-captions` 36,952 / 34.

The four "previous" failures, their traces and how the fixes as written compare with the
sketches are in "The code as fixed (current)" above; the configurations are
`Recording_previous_…__violates_R11…`, `…R5d…`, `…R8…`, `…R9…` and `…R15…`.

One correction to the model itself: R3's check used to count a captions start's *own* reset of
`finalizationProgress` as a sign that something had got in between its guard and its commit. It
no longer does. The verdicts recorded at edcaebae are unchanged (the two-start traces are shorter
and are still the ones TLC returns).

### R10 — can `startClaimed` be left set?

Not while every await inside `start` returns (`R10_StartReturns` holds; the `defer` at 210 runs on
every path). If one never returns (the wait at 356 always does, since the third round), the claim is held for ever and every later `start()` returns at
208 with no message, the phase unchanged and Start still offered. What changed against edcaebae:

* 223 / 380 `ZoomCaptions.read()`: at edcaebae the phase was still "ready" here and a second Start
  went ahead (that was R3). Now it is refused until the read returns. Each Accessibility call is
  capped at half a second (`ZoomCaptions.swift:31`); the OCR path (`ZoomCaptions.swift:98`) is not.
  `Recording_current_mutation_read_hangs_auto__violates_R10…`.
* 356, the wait for `runtime.closeStreams()` at the end of the catch: the phase is already "error"
  (350), so at edcaebae another Start was accepted here; now it is refused until this returns.
  `closeStreams` queues on the speech runtime's serial queue (`Runtime.swift:43-51`); if that queue
  is stuck inside the recognizer, which is the situation `recognizerStalled` describes and the
  reason a start ends up in this catch (193), it never answers. Up to the second round that was a
  bare `await`, and no start was accepted until relaunch. The third round waits for it inside
  `RecordingDeadline.wait` (354-356), so the catch goes on after `stallTimeout` whatever
  `closeStreams` does: `Recording_current_mutation_close_streams_hangs__holds`, and without the
  wrap `Recording_current_without_bounded_close_mutation_close_streams_hangs__violates_R10…`. What
  is left: for up to `stallTimeout` (30 s) after such a failed start, Start is offered and does
  nothing.
* 242, 244, 266, 294 (imports, warm-up, connect, "Waiting for audio permissions…"): the phase is
  "starting", which refused other starts at edcaebae too. No change.

### R12, R13, R14 — the explicit checks

* **The `while let running = stopTask` loop** (R14) neither spins nor deadlocks: each trip waits
  for one task and then either clears `stopTask` or finds a different task in it, and nothing
  `finishRecording` awaits ever calls `stop()`. It returns whenever the tasks it joins do;
  `Recording_current_mutation_final_pass_hangs__violates_R14…` is the case where one does not.
* **`finishRecording` twice for one session** (R13): no. A second task is only created at 455 while
  the phase is "recording", and the first sets "finalizing" in its first step; in between, the
  second Stop finds `stopTask` set and joins. `Recording_current_mutation_no_stop_join__violates_R13…`
  drops the join.
* **`startDidNotBegin`** (R12): holds for the three sources, with the monitor asking twice. It is
  needed more than before: the claim gives the monitor's start a new way to be refused.
  `traces/Recording_current_monitor_without_start_did_not_begin__violates_R12_AutoStartNotStuck.txt`:
  a manual start fails and is waiting at 356, phase "error"; a call begins; the policy asks
  (nothing is busy); the monitor's start returns at 208 because of the claim; without line 185 the
  latch stays set and the call is never recorded. One thing by design: `refuse` suppresses the
  call (374), so an automatic `zoom-captions` start that finds Zoom not yet in a meeting is not
  tried again for that call. The outcome is what the latch did at edcaebae; it is now deliberate.

## Findings at edcaebae

Kept as they were written against edcaebae; line numbers in this section are that commit's. Each
starts with what became of it.

### R3 — double start. Affected: `auto` and `zoom-captions`. Not affected: `recorder`.

*Now:* holds (`startClaimed`). *Replay:* not written; it needs two `start()` calls inside one
`ZoomCaptions.read()`, a real Accessibility read of Zoom that suspends.

`traces/Recording_edcaebae_auto_two_starts__violates_R3_NoDoubleStart.txt` (5 states) and
`…edcaebae_captions_two_starts…` (5 states).

1. `start()` A passes `guard !busy` at **198**. Nothing has changed state yet.
   * `auto`: A suspends at **207** `await ZoomCaptions.read()`.
   * `zoom-captions`: A goes through 208-209 into `startCaptions`, which sets only
     `finalizationProgress` and `errorText` (339) and suspends at **344**.
   `phase` is still `"ready"`.
2. `start()` B passes the same guard at 198 and suspends at the same line.
3. A resumes. No line looks at `busy` or `phase` again. `auto`: 220 `phase = "starting"`, 222 new
   generation, 226 `meeting = M1`, 230 saved as recording. Captions: 347, 360-362.
4. B resumes and does the same: `meeting = M2`. M1 is left on disk with status `"recording"`.

For `recorder` there is no suspension between 198 and 220, so the second call sees `busy`
(`Recording_edcaebae_recorder__holds`).

What follows, from the model:
* `auto`, Zoom not in a meeting (`…edcaebae_auto_two_starts__violates_R1a…`, 7 states): both calls reach
  270 and overwrite `capture`; two `AudioCapture` objects are live and only the second can ever be
  stopped (419 takes the variable).
* Captions (`…edcaebae_captions_two_starts__violates_R1b…`, `…then_stop__violates_R2…`): the first caption
  loop notices the new generation and ends, but M1 stays `"recording"` on disk after everything
  has settled, until the next launch turns it into `"interrupted"`.

Confidence that the app could do this: **high**. It needed two `start()` calls inside one
`ZoomCaptions.read()`: a double click on Start, the hotkey twice, a user start landing on the
auto-record monitor's start (177), or `POST start` racing either. For `auto` it also needed
Accessibility to be trusted.

### R4 — a Stop that does nothing

*Now:* holds (the loop in `stop`). *Replay:* **replayed on the real code, fixed** —
`RecordingRaceTests.testASecondStopAfterAResumeStopsTheResumedRecording`.

`traces/Recording_edcaebae_recorder_stop_resume_stop__violates_R4_StopNotSwallowed.txt` (16 states).

1. Recording. `stop()` #1: **402-404** creates task T1, `stopTask = T1`, awaits it.
2. T1 = `finishRecording`: 409-421, drain, 455 status complete, 460 progress 0.35, and suspends
   at **465** in the final note pass.
3. Resume: `start(resuming:)` passes **198** (finalizing, progress ≥ 0.35, same meeting,
   `canResume`), 220-222, 226, … 287 `phase = "recording"`. T1 is still suspended at 465, so
   `stopTask` is still T1.
4. `stop()` #2 on the resumed recording: **400** `if let stopTask { await stopTask.value; return }`.
5. T1 resumes, fails the guard at **470**, returns.
6. `stop()` #2 returns at 400. Phase is `"recording"`, the capture is live, nothing was stopped.

Confidence: **high**; it was a straight reading of 400 and 470. With Quit instead of the second
Stop this is R9.

### R5a — the old stop sets `phase = "ready"` over a resumed recording (and R1, R2 for `recorder`)

*Now:* holds (the guard after the last wait). *Replay:* **replayed on the real code, fixed** —
`RecordingRaceTests.testTheTailOfAnOldStopDoesNotDeclareAResumedRecordingReady`.

`traces/Recording_edcaebae_recorder_resume_in_final_pass__violates_R5a_SupersededNeverSetsPhase.txt`
(13 states); consequences in `…__violates_R2_NoOrphan.txt` (17) and
`Recording_edcaebae_recorder_resume_then_start__violates_R1a_OneCaptureOwner.txt` (16).

1. Stop. `finishRecording` reaches 465, the final pass ends, the guard at **470** passes,
   471 progress 0.9.
2. It suspends at **474** `await RecordingDeadline.wait { finalize(id) }`. Phase is still
   `"finalizing"` and progress is 0.9, so the Resume button (RecorderView 283-290) and the API
   route are live.
3. Resume during that await: 198 passes, 220 `phase = "starting"`, 222 new generation, 226
   `meeting = resumed`, …, 287 `phase = "recording"`.
4. `finishRecording` resumes after 474 and runs **486-488** with no second look at the guard:
   `phase = "ready"`.

Now the app shows idle while an `AudioCapture` is running and the meeting is `"recording"` on
disk (R2). `stop()` refuses at 401 because phase is not `"recording"`. A new Start passes 198 and
270 overwrites `capture`: two capture owners, the first unstoppable (R1a), two meetings recording
on disk (R1b).

Confidence that the interleaving was permitted: **high**. It did not exist for meetings with a
plugin document (476-482 has no await; `Recording_edcaebae_recorder_document_meetings__holds`).

### R5b — the old stop finalizes retention after the resume committed

*Now:* holds (the generation check inside the last wait's closure). *Replay:* not written; it
needs a resume suspended in a cold speech engine's warm-up.

`traces/Recording_edcaebae_auto_cold_speech_resume__violates_R5b_SupersededNeverFinalizes.txt` (12 states).
It needs the resume to be suspended between 222 and 226 (in `prepareSpeech`, 225), so that
`meeting` still shows the old `endedAt` when `finalize` runs its guard (MeetingRetention.swift:32).
That takes a cold speech engine at resume time (a captions meeting resumed down the recorder path
under `auto`), or a resume that then fails. Effect: a receipt with the first stop's deadline for a
meeting that is recording again. Confidence the app could reach it: **low to medium**; impact small
on its own, but see T7.

### R6 — as asked it fails by design

*Now:* the same. Open by design.

`traces/Recording_edcaebae_recorder_resume__violates_R6_AcceptedStopSettles.txt` (and
`…current_recorder_resume…`): stop, resume, and the meeting records forever. That is the feature.
`R6r` adds "or a resume superseded this stop" and holds. It is not vacuous:
`…mutation_final_pass_hangs__violates_R6r…` (the final pass never returning) breaks it.

### R7 — a start that fails marks the previous meeting failed

*Now:* holds (`installed`). *Replay:* not written; it needs `prepareSpeech()` to throw, i.e. the
speech engine failing to warm or a stalled recognizer, with a previous meeting still on screen.

`traces/Recording_edcaebae_recorder_stall_then_start__violates_R7_FailedStartSparesOtherMeetings.txt` (13).

1. A recording is stopped and its drain stalls: **433-436** `recognizerStalled = true`; 455 status
   `"interrupted"`; phase ends `"error"`. `model.meeting` is still that meeting.
2. Start (the button is enabled in `"error"`, RecorderView 134; so are `POST start`, LocalAPI 80,
   and the monitor when the source is not `recorder`): 198 passes, 220 `phase = "starting"`.
3. **225** `try await prepareSpeech()` throws at 183. Line 226 has not run, so `meeting` is still
   the previous meeting.
4. catch, **325-326**: `meeting?.status = "failed"; meeting?.endedAt = Date(); try? save()`.

The interrupted meeting was rewritten as failed with a new `endedAt` (it could no longer be
resumed, and its end time moved each time Start was pressed). The same lines hit a healthy
completed captions meeting if the next recorder start failed to warm the engine.
Confidence: **high** (no interleaving needed).

### R8 — a capture failure during `startScreen` is forgotten

*Now:* holds (the re-check after `startScreen`, and `startScreen` no longer suspends). *Replay:*
not written; it needs a capture failure while `startScreen` is suspended, which the working tree
can no longer produce.

`traces/Recording_edcaebae_recorder_failure_during_screen_start__violates_R8_FailureStopsRecording.txt` (6).

1. `start` passes **275** (`errorText` nil) and suspends at **286** `await startScreen()`
   (AppModel+Screen.swift:47).
2. A capture, track or pump failure calls `fail()`: 525 passes (phase `"starting"`), **526** sets
   `errorText`, **527** does not stop because phase is not `"recording"`.
3. `start` resumes at **287**: `phase = "recording"` with `errorText` set and nobody stopping.

Confidence: **medium**. The same invariant was also broken through R4 (a `fail()` whose `stop()`
joined a stale task).

### R9 — Quit ends the app while a resumed recording is running

*Now:* holds. *Replay:* not written; it needs the terminate path (`applicationShouldTerminate`,
`RecordingQuit`) on top of the R4 situation. The join it went through is the one the R4 test
replays.

`traces/Recording_edcaebae_recorder_quit_after_resume__violates_R9_QuitLeavesNothingRecording.txt` (12):
Quit while recording, the final pass starts, Resume, the old `finishRecording` returns at 470,
`prepareToQuit` continues past **619** and the app terminates (Entry.swift:449) with the meeting
`"recording"` on disk. The more likely order was Stop, Resume, then Quit while the first final pass
is still running: Quit's `stop()` joined the stale task exactly as in R4. Confidence: **high** for
the second order. A second, simpler route at edcaebae, not seen in the first round because the
model then ended at 619: nothing stopped any start behind a quit
(`Recording_edcaebae_recorder_start_during_quit__violates_R9…`).

### Smaller observations

* `finalizationProgress >= 0.35` in the start guard is implied by `canResume()`: status becomes
  complete/interrupted five lines before progress becomes 0.35, with no suspension between.
  Dropping it changes nothing (`Recording_edcaebae_mutation_resume_any_progress__holds`).
* `startCaptions` set `phase = "error"` at 344 without looking at what owned the phase. Fixed by
  `refuse`; the resets on the line before it were R15.

## Showing the passing properties can fail

Every property that holds on the current-code configurations, with the current code changed in
one place:

| Property | Change | Result |
|---|---|---|
| R1a | `MutNoCaptureHandoff` (drop 473-475) | violated, 11 states |
| R1b, R2 | `MutFinishKeepsStatus` (drop 464, 509) | violated, 13 states each |
| R3 | without `FixStartClaim` (`auto`, `zoom-captions`); `MutNoBusyGuard` (`recorder`) | violated, 5, 5 and 6 states |
| R4 | without `FixStopLoop` | violated, 16 states |
| R5a | without `FixTailGuard` | violated, 13 states |
| R5b | without `FixInnerGenCheck` (`auto`, cold speech engine) | violated, 12 states |
| R5c | `MutStatusAfterFinalPass` | violated, 11 states |
| R5d | without `FixCatchAfterGuard` | violated, 13 states |
| R6r, R14 | `MutFinalPassHangs` | violated |
| R7 | without `FixCatchOwn` | violated, 10 states |
| R8 | without `FixFailRecheck` | violated, 6 states |
| R9 | without `FixQuitFlag` (`recorder`); without `FixQuitRecheck` (`auto`) | violated, 4 and 5 states |
| R10 | `MutReadHangs`; `MutCloseHangs` without `FixCloseBounded` | violated |
| R11 | without `FixStopOwnSession` | violated, 16 states |
| R12 | without `FixStartDidNotBegin` | violated, 7 states |
| R13 | `MutNoStopJoin` (drop 447-450) | violated, 7 states |
| R15 | without `FixCaptionsResetLate` (`zoom-captions`) | violated, 11 states |

The edcaebae round's own table is reproduced by the `Recording_candidate_mutation_…` and
`Recording_edcaebae_mutation_…` configurations.

---

# Machine 2 — retention and purge (`Retention.tla`)

## Code covered

Current line numbers. `Sources/WorkScribe/MeetingRetention.swift`: loop 22-29, `finalize` 31-65,
`done` 66-114, `predates` 117-120, `recover` 121-150. `Sources/WorkScribeCore/Retention.swift`:
receipt 5-25, `RetentionStore.purge` 51-92. `Sources/WorkScribeCore/Meeting.swift`: `save` 120-133,
`load` 134-141, `list` 142-147, `hasTranscript` 150-153, `recoverInterruptedRecordings` 156-164.
`Sources/WorkScribe/AppModel.swift`: `deleteRecording` 758-769, resume in `start` 230-250 and its
catch 342-350, `finishRecording` 464-465, 509-512, 519-554. `Sources/WorkScribeCore/RecordingSession.swift`
20-38. `Sources/WorkScribe/MeetingNotes.swift` 24-47. `Sources/WorkScribe/IndexService.swift`
`purgeMeeting` 187-198. `Sources/WorkScribeCore/Search/SearchIndexVectors.swift` `purge` 85-102.
`Sources/WorkScribeCore/Engine/Index.swift` 37-38, 172-173 and `Engine/Line.swift` 178 (the
`purged:` fence). `Sources/WorkScribeCore/Search/MeetingIndexer.swift` 43-69.
`Sources/WorkScribe/LocalAPI.swift` 110-153. `Sources/WorkScribeCore/Vault/VaultStore.swift` 243-273,
284-288.

## Step-to-code mapping

| Action in the spec | Swift, current | at edcaebae |
|---|---|---|
| `Finalize(s)` (used by several actions) | `finalize` 31-63: the receipt check 34, the guard on `meetingSnapshot` 35-36, the vault write 42-56, the receipt write 60, `mutateMeeting` 61 | 31-60 (32-33, 57, 58) |
| `UserDone` → `DoneEnter` | LocalAPI 148-152 or RecorderView 361, then `done` 67-79 (index check 72, the branch at 76, which a "purging" receipt never enters) | 64-70 |
| `DoneFinishDone` | 80-81 after `await finish(id)`; `finalize` runs and suspends at its line 64 | 71-72 |
| `DoneIndexReturned` → `DoneAfterFinalize` → `DoneJournal` | the re-checks at 83 and 87-89, then 91-107: 96 writes `"purging"`, suspends at 107 | 74-91 (79; 81 threw without an index) |
| `DoneClearReturned` | 108, the hop to the `IndexService` actor | 92 |
| `IndexPurgeFence`, `IndexPurgeRows` | IndexService 195-196, then 197 → SearchIndexVectors 85-102 | the same |
| `DonePurgeBegin`, `DonePurgeConvs`, `DonePurgeFolder`, `DonePurgeMark` | Retention.swift 53-57, 67-89, 90, 91, then MeetingRetention 110-113 | 94-97 |
| `RecoverFires` | `recover` 124 (the `where` over `store.list()`), or straight on | 100 |
| `RecoverFinishDone`, `RecoverIndexReturned` | 126-129 and the continuation of `finalize` | 103-104 |
| `RecoverLoop2`, `RecoverDocReturned` | 131-138, the 23 h loop for meetings with a plugin document | 107-114, not modelled then |
| `RecoverLoop3` | 139-149, with the checks at **142** (still recording? the snapshot) and **146** (a stale receipt? the copy on disk) | 115-119 (116) |
| `PluginFinalize`, `PluginFinalizeRun` | LocalAPI 141-144 and 144-146 | the same |
| `OpenDoc`, `UndoFinalize` | LocalAPI 110-116; 122-135 | not modelled then |
| `Stop`, `StopNotesDone`, `StopIndexReturned` | AppModel 464-465 + 509-512, 519-541 (document branch 535-540), 546-554 | 410-411 + 455-458, 466-474, 486-488 |
| `Resume` | AppModel 208-209, 235, 250, and 342-350 when `save()` hits the store fence | 198, 216, 230, 318-326 |
| `Trash` | `deleteRecording` 758-769 | 691-700 |
| `Crash(up)`, `TornFinalize(up)` | process death (the second: between lines 60 and 61 of `finalize`), then `recoverInterruptedRecordings` at launch | `Crash` only |
| `IndexerSync` | `MeetingIndexer.sync` 43-69 (`hasTranscript` at 49) | 43-67 |
| `LateStoreSave`, `LateIndexWrite` | any holder of a stale copy calling `store.save` / an index write | the same |
| `Displace` | `model.meeting` moves on to another meeting | the same |
| `Tick` | the 24 h deadline of the oldest unexpired stop passes | the same |

## Abstractions

* One meeting. State kept: receipt state and which stop its `endedAt` / `purgeAt` belong to; the
  folder (`ok` / `unreadable` / `gone`); `endedAt`, `retention`, `status` and the plugin document
  (none / open / finalized) in `transcript.json`; the same in memory when `model.meeting` is this
  meeting; index rows present or not; the index fence; whether an `IndexService` exists this
  session; a scoped conversation holding answers drawn from the meeting; time.
* `fEpoch`, "the stop whose finalization the note holds", is a variable the app does not have. T7
  is stated with it: `finalize` sets it, the plugin's undo clears it. Without a document it always
  equals the receipt's stop, and T7 is what it was at edcaebae.
* Time is a count of stops (`epoch`) and how many of their deadlines have passed (`now`). A day
  only passes while nothing is being recorded or finalized. Resume is allowed until the deadline
  (the ten-minute window is inside that). `predates` allows one second (117-120, because receipts
  keep whole seconds); stops here are whole stamps, so a second stop within a second of the first
  is not modelled.
* The 23 h loop is modelled as firing when the meeting's 24 h deadline has passed; the same call
  of `recover` then goes on to the last loop, as in the code.
* "Index rows" lumps transcript chunks, vectors and the `lines` table. Screen files, meeting
  attachments, voice samples and the vault note's content are not modelled. The post-purge check
  at MeetingIndexer.swift:64 is not modelled.
* `finalize` either fails before it writes anything (`MaxFinalizeFail`, or `VaultDown` for every
  time) or writes receipt and transcript together; the process dying between the two writes is
  `TornFinalize`. `RetentionStore.purge` never throws half-way; a crash inside it is modelled
  instead (its file operations are separate steps that only `Crash` can interleave).
* The recording lifecycle is assumed correct here (the guards at AppModel 524 and 546), so nothing
  below is a consequence of Machine 1.
* `AllowLate` writers are stronger than any I found in the code: they may save or index at any
  time with a stale copy. The fences are what is being tested.
* `TrashOnlyFinalized` and `CorruptOnlyFinalized` split the environment so that the T5 hazards
  that are fixed can be told from the ones that are not: each open hazard has a configuration
  that differs from a passing one only in allowing it.

## Bound

One meeting; 2 resumes, 2 crashes, 1 death inside finalize, 1 Move to Trash, 1 unreadable
transcript, 2 Done calls, 1 plugin Finalize, 1 throwing index purge; late writers, scoped
conversations, the index possibly missing after a relaunch, 1 failing finalize; where stated, the
note opened later and 1 undone finalize. (The widest runs have 1 crash beside the death inside
finalize; the configurations say.) Liveness runs use smaller environments (each `.cfg` says
which), so their traces are 6 to 11 states.

## Results

| | Property | At edcaebae | In the current code |
|---|---|---|---|
| T1 | The purge deletes nothing unless the receipt on disk says purging at that moment | **violated**, only through T4 | holds |
| T2 | Receipt purged ⇒ no folder, no index rows, no scoped conversation | holds | holds |
| T3 | Once purging/purged, a deleted folder is not recreated and fenced index rows do not reappear | **violated**, only through T4 | holds |
| T4 | The receipt never goes from purging back to finalized | **violated** | holds |
| T5 | After the deadline, raw data is eventually gone and the receipt says purged | holds with crashes only, or resumes only; **violated** by each of (a) trash, (b) unreadable transcript, (c) index unavailable, (d) resume then crash, (e) trash before finalize with a conversation | holds with (a), (b), (b″), (d) and everything else in the bound (224,183 / 29; document 220,647 / 37; (b) 143,144 / 28; (b″) 266 / 20), an interrupted purge with the note re-opened in memory included (it is in the document configuration). **Violated** by (e), (b′), (c), (f). *Previous:* also by (b″). *The third round alone:* also by the interrupted purge |
| T6 | A meeting being recorded is never purging or purged | **violated** through a Done | holds |
| T7 | A purge never starts while the transcript records a stop the note does not hold | **violated**; held without resume | holds, with a failing finalize, an undone finalize and a note opened later all allowed (4,199,578 / 36; document 1,926,658 / 41; note opened later 1,058,439 / 35). *Previous:* **violated** in three traces |
| T8 | The index rows of a meeting whose folder is gone do not stay | **violated** | holds |
| T9 | A purge the 60 s loop starts never starts before the deadline of the meeting's last stop | **violated** (T7's trace) | holds, except for the (b″) meeting (see the top) |

T1, T2, T3, T4 and T6 hold in every `Retention_current_…__holds` configuration above.

The explicit questions:

* **Does the stale-receipt rule close T7 on every path?** With the re-check at 87-89: yes, within
  the bound: for a meeting with a plugin document and one without, with a crash at any step
  including between `finalize`'s two writes, with trash, with the plugin's Finalize, with a
  failing finalize, an undone finalize and a note opened later.
* **Does skipping a stale receipt in `recover`'s last loop leave a meeting that is never purged?**
  A document meeting: no, the 23 h loop finalizes it and the same call then purges
  (`Retention_current_T5_document__holds`). A meeting whose `finish` keeps failing: no, the first
  loop finalizes it once it has expired. A meeting whose `finalize` keeps failing (no vault): yes,
  by design (`…T5_vault_unavailable__violates_T5…`). The (b″) corner: no longer, the skip reads the
  disk now.
* **Does `finalize` refusing on a purging receipt break "Done finalizes first"?** Not for a Done
  that starts with a "finalized" receipt or with none. Together with the third round's re-check
  at 87-89 it did break the *replay* of a purge that was already journalled, when the document in
  memory was open: `finalize` was a no-op (34) and the re-check then threw, every time
  (`Retention_current_without_replay_rule_document_interrupted_purge__violates_T5…`). The rule at
  76 ends that: a "purging" receipt no longer reaches `finalize` from `done` at all.

## Findings at edcaebae

Kept as they were written against edcaebae; line numbers in this section are that commit's. What
became of each: **T4** (and T1, T3 through it): holds now, replayed on the real code and fixed
(`RetentionRaceTests.testFinalizeNeverOverwritesAPurgeInProgress`). **T6**: holds now, fixed
following the model, not replayed (needs `finalize` to suspend inside `done`, which takes a real
`IndexService`). **T5 (a)**: holds now, replayed and fixed
(`testAFinalizedMeetingMovedToTheTrashIsStillPurgedAtItsDeadline`; the index rows:
`testATrashedMeetingsRowsLeaveTheIndex`). **T5 (b)**: holds now for a meeting that has a receipt,
not replayed. **T5 (c)**: the journal no longer lies; not replayed. **T5 (d)** and **T7**: the
reported trace holds now, replayed and fixed
(`testAResumedThenInterruptedMeetingIsFinalizedAgainBeforeAnyPurge`). **T5 (e)**: not fixed, open.

### T4 — Finalize overwrites "purging". Confirmed.

`traces/Retention_edcaebae_done_then_plugin_finalize__violates_T4_NoRegression.txt` (7 states).

1. A meeting is stopped and finalized: receipt `finalized`; `model.meeting` is still this meeting
   and its in-memory `retention` is `"finalized"`.
2. Done: `done` loads the receipt, **79** writes `"purging"`, then suspends at **91**
   (`await NoteImageUnderstanding.shared.clear()`) and again at **92** (index purge). It does not
   touch `model.meeting` until 96.
3. Finalize arrives (LocalAPI 140-146): `finalize(id)` guards on `model.meetingSnapshot(id)`
   (**32-33**), which is the in-memory copy saying `"finalized"`, and line **57** writes a fresh
   receipt with state `"finalized"`.

If `done` then carries on, `RetentionStore.purge` re-journals at Retention.swift:57 and the purge
completes, so the regression is brief. In between, the index purge deletes rows while the receipt
says `finalized` (T1, `…__violates_T1_JournalFirst.txt`, 10 states). If `done` does not carry on —
index unavailable (81), index purge throws, or the process dies — the receipt stays `finalized`,
the user's Done is forgotten until `purgeAt`, the store fence at Meeting.swift:121 is open again,
and a stale writer can put back a folder the user has since trashed
(`traces/Retention_edcaebae_regression_then_trash_and_late_save__violates_T3_NoResurrection.txt`, 8 states).

A second route to the same overwrite needs no plugin Finalize: `finishRecording`'s own
`finalize` at AppModel 474 after a resume that slipped past `done` (the T6 trace continued).

Confidence: **high** that line 57 can overwrite; it only needs the meeting to be the one in
`model.meeting` (the last one recorded) and a `finalize(id)` during `done`'s awaits at 91-92.
Not reachable when the meeting is not in memory: `store.load` then answers from the receipt
(Meeting.swift:135) and the guard at 33 stops it.
Replay: `MeetingRetention` with an index whose `purgeMeeting` can be held; `model.meeting` set to
a finalized meeting; start `done(id)`, wait for the receipt to read `purging`, call
`finalize(id)`, read the receipt.

### T6 — purged while recording

`traces/Retention_edcaebae_done_without_receipt_then_resume__violates_T6_NotPurgedWhileRecording.txt` (6).

1. An ended meeting has no receipt (here: interrupted by a crash; also a stop whose finalize
   could not run).
2. Done: receipt is nil, so **70** `await finish(id)`, then the guard at **71** passes, **72**
   `finalize(id)` writes the receipt and suspends at its line 61 (index of the final note).
3. Resume (within ten minutes; `canResume` allows `retention == "finalized"` for a meeting with no
   document): the meeting is recording again.
4. `done` resumes at **74-79** without a second look at 71 and writes `"purging"`; 93 then deletes
   the folder of a meeting that is being recorded. `consume` reports "Transcript could not be
   saved" from then on.

A second route goes through T4: once the receipt is back to `finalized`, a resume during
`done`'s awaits at 91-92 saves successfully.
Confidence: **medium** for the interleaving, **low** for frequency: it needs Done on a
non-document meeting that has no receipt, an index (otherwise `finalize` does not suspend), and a
resume during that await. The 60 s loop alone cannot do it: line 116 protects it
(`Retention_edcaebae_no_user_done__holds`; removing 116 breaks it,
`Retention_edcaebae_mutation_no_L116_check…`).

### T5 — when the purge never happens

All four reported hazards were confirmed, and there was a fifth.

**(a) A finalized meeting moved to the Trash** —
`traces/Retention_edcaebae_T5_trashed_finalized_meeting__violates_T5_EventuallyPurged.txt`.
`deleteRecording` (695) trashes the folder and leaves the receipt. Every minute `recover` reaches
**116**: `model.meetingSnapshot(id)` is nil (the receipt is `finalized`, so `load` reads
`transcript.json`, which is gone), `nil?.endedAt == nil` is true, `continue`. The receipt stays
`finalized` for ever. The index rows stay too: `MeetingIndexer.sync` only removes sources that are
not in `store.list()`, and `list()` adds a stand-in for every receipt without a folder
(Meeting.swift:145). Scoped conversations stay. Confidence: **high**. No timing is involved.
Replay: finalize a meeting, call `deleteRecording`, set the receipt's `purgeAt` in the past, run
`recover()`, then search the index for the meeting's words.

**(b) An unreadable transcript** — `traces/Retention_edcaebae_T5_unreadable_transcript__…`. Same line, same
reason: any `store.load` failure is read as "still recording". It applies once the meeting is no
longer `model.meeting` (after a relaunch or the next recording). Confidence: **high** given a
transcript that does not decode. With no receipt at all such a meeting cannot even be finalized;
that case is not fixed by `FixL116`.

**(c) Index unavailable** — `traces/Retention_edcaebae_T5_index_unavailable__…`. `done` writes `"purging"`
at 79 and throws at 81. `index` is fixed when `MeetingRetention` is built (Entry.swift:305), so
this repeats every minute for the whole session; the folder and conversations stay while the UI
already says "Only your notes remain". Confidence: **high** given `IndexService.make` returned
nil.

**(d) Resume, then an abnormal end** —
`traces/Retention_edcaebae_T5_resume_then_crash__violates_T5_EventuallyPurged.txt`.

1. Stop, then Resume during the final pass (before AppModel 474, so there is no receipt yet).
   `resume()` sets `retention = "live"` (RecordingSession.swift:34) and it is saved.
2. The process dies during the resumed session (or after its Stop, before its finalize).
3. Launch: `recoverInterruptedRecordings` sets status and `endedAt` but leaves `retention`.
4. `recover` loop 1 (**100**) only takes meetings whose `retention == nil`. Loop 3 only walks
   receipts. Nothing ever finalizes or purges this meeting.

Confidence: **high** that the state is never picked up (no timing after the crash). It needs a
meeting resumed before its first finalize and then a crash, kill or power loss; R4/R9 above give
a route with no crash at all (Stop, Resume, Quit joins the stale stop and the app exits while
recording). The same lines also strand a resume whose start fails (325 marks it failed with
`retention` still `"live"`).
Replay: save a meeting with `retention = "live"`, `status = "interrupted"`, an old `endedAt` and
no receipt; run `recover()`; assert a receipt exists.

**(e) A meeting trashed before it was ever finalized** leaves its scoped conversations for
ever (`traces/Retention_candidate_all_fixes_trash_before_finalize_with_conversation__…`): no receipt, so no
purge ever deletes them. Confidence: **medium**; whether that matters depends on whether those
answers count as raw material (the purge itself treats them so, Retention.swift:67-70).

### T7 — purged on the first stop's deadline, without the last session in the note

`traces/Retention_edcaebae_resume_crash_done__violates_T7_PurgeOnlyFinalizedSession.txt` (6 states).

1. Stop and finalize: receipt `finalized`, deadline from stop 1.
2. Resume from the review view; the receipt is untouched.
3. The resumed session ends abnormally (as in (d)); at launch the meeting is `"interrupted"`.
4. Done, or the 60 s loop once stop 1's deadline passes: a receipt exists, so `done` skips its
   finalize branch (**67**) and purges. The second session's transcript is deleted without ever
   having been written into the note.

This is the other half of (d): with no earlier receipt the resumed meeting is never purged, with
one it is purged early and unfinalized. Confidence: **high** given the abnormal end.

## Showing the passing properties can fail

Every property that holds on the current-code configurations, with the current code changed in
one place:

| Property | Change | Result |
|---|---|---|
| T1 | `MutNoJournal` | violated, 7 states |
| T2 | `MutPurgeSkipsIndex` (drop MeetingRetention 108) | violated, 8 states |
| T3 | `MutNoStoreFence` (drop Meeting.swift:121); `MutNoIndexFence` | violated, 6 and 8 states |
| T4 | without `FixFinalizeChecksReceipt` | violated, 7 states |
| T5 | without `FixL116` (trashed meeting); without `FixRecoverLive` (resume then crash); the first-round skip in memory ((b″), `Retention_previous_T5_…`); without the replay rule at 76 (`FixReplaySkipsFinalize`, the interrupted purge) | violated |
| T6 | without `FixDoneRecheckAfter`; `MutNoL116` with no Done calls | violated, 6 and 8 states |
| T7 | without `predates` in `done` (`MutNoStaleInDone`); without the re-check at 87-89 (`FixDoneRecheckStale`) | violated, 6 and 8 states |
| T8 | without `FixSyncDropsTrashed` | violated |
| T9 | without `predates` in `recover` (`MutNoStaleInRecover`) | violated, 10 states (T7 still holds without it) |

The edcaebae round's own table is reproduced by the `Retention_candidate_mutation_…` and
`Retention_edcaebae_mutation_…` configurations.

---

# Machine 3 — note enhancement scheduler (`NoteScheduler.tla`)

## Code covered

Current line numbers. `Sources/WorkScribe/MeetingNotes.swift`: note edits 49-105, `schedule` 138-161,
`signature` 163-165, `cancelSynthesis` 166-169, `yieldLive` 172-176, `beginStop` 178-182, `finish`
183-240, `run` 241-324. `Sources/WorkScribe/AppModel.swift`: `start` 208-209, 235-241, 309-311,
342-353, `startCaptions` 387, 402-403, `finishRecording` 461-468, 509-524, 546-554, `consume`
613-616, `updateRecordingPressure` 740-755. Other callers of `finish`: `MeetingRetention.swift` 79,
126 and `LocalAPI.swift` 144. `Sources/WorkScribeCore/Engine/Line.swift` 23, 32.
`Sources/WorkScribe/CurrentNoteEngine.swift` 23-46.

## Step-to-code mapping

| Action in the spec | Swift, current | at edcaebae |
|---|---|---|
| `Speech`, `Edit` | `consume` 613-616; `addNote` / `editNote` 58-67, 75-81; each ends in `Schedule` (138-161) | 547-550; 137-155 |
| `PressureUp`, `PressureDown` | `updateRecordingPressure` 746 + 754 (`yieldLive` 172-176) and 746 + 752 | 679 + 687 (162-166), 679 + 685 |
| `Stop` | `finishRecording` 461-468 (`beginStop` 178-182) | 409-414 (168-172) |
| `StopDrained` | 509-519, entering `finish` 186-196 | 455-465; 174-184 |
| `StopAfterFinish` | 519-524 and 546-554 (`recordingPressure = .normal` at 550, `schedule` at 553) | 466-470, 486-488 (487; no schedule) |
| `Resume` | `start` 208-209, 235-241 (`recordingPressure = .normal` at 241), `Line.resume` | 198, 216-222 (222) |
| `StartDone` | `start` 309-311 (`schedule` at 311); for a captions resume, 387-403 in one step with `Resume` | 287; no schedule |
| `StartFails`, `ResumeFailsEarly` | the catch of `start`, 342-353 (`schedule` at 353), after the meeting was installed at 245 or before it | 318-326, not modelled then |
| `OtherFinish` | `finish` called by recover, done or the plugin's Finalize | the same |
| `LiveTaskRuns(t)` | the task body 149-159 (token 154-156) and `run` 242-257 | 148-152; 230-238 |
| `PatchArrives(r)` | the `didProduce` callback 263-275 | 248-260 |
| `EnhanceReturns(r)` | 262 continuation: 277, 278-281, 304-316 (`dirty.insert` at 306), or the catch 317-323; then the defer 254-257 | 247; 262, 263-266, 282-294, 295-301; 239-242 |
| `SearchedReturns(r)` | 281 continuation through 302 (the guard at 286-288, with `dirty.insert`) | 266-280, no guard |
| `RetryFires` | the task of 294-298 | 272-276 |
| `FinishLiveDone`, `FinishImagesDone` | 196 and 201 continuations (guards at 198, 203) | 184, 189 (186, 191) |
| `FinishRunStarts` | 209, `run(final: true)` 242-257 (line 250 records the inputs) | 197; 230-238 |
| `FinishRunDone` | 215-240 and the defer 188-191 | 203-228; 176-179 |

## Abstractions

* One meeting, so `pending`, `running`, `finalizing`, `draining`, `dirty`, `inputs`, `live` are
  single values. One note line with states listening / found / answered / quiet / settled.
* The inputs hash (`signature`, 163-165) is a version counter bumped by each transcript line or
  jot edit. It does not change on a resume, as in the code (`Line.resume` only changes the state).
* `enhance` is a black box that may deliver the plan patch and one outcome patch, then returns a
  result, nil, or throws. A jot edit after a run's snapshot stands for "apply reported a stale
  note" (272).
* A resume is one step (`StartAwaits = FALSE`: what a captions resume is, 384-403, and how every
  resume was modelled at edcaebae) or two (`TRUE`: line 241, then 309-311 after the awaits of
  start, or the catch). The meeting installed at 245 is taken to be installed at 241 (a warm
  speech engine).
* Not modelled: the synthesis job (217-238) and `cancelSynthesis`; the stall watchdog around the
  final pass (207-214), which returns false and leaves the stalled run in flight; `Task.isCancelled`
  at 197-198; the retention part of the guard at 243; `revalidate` 244-247; `lastRun`; debounce
  (0 s in the code). There is no clock: the 3 s of the retry at 295 can outlast anything.
* Live-pass tasks use 5 reusable slots. `SlotsSuffice` checks that the model never needed a
  sixth.

## Bound

2 input changes, 1 pressure rise (any number of falls), 2 stops, 1 resume, 1 other `finish`
caller, 1 `enhance` failure, 1 partial live pass, 1 unsearched index, 1 failing resumed start
(before or after its meeting is installed). N5 on the current code is checked without the `enhance` failure and the unsearched
index.

## Results

| | Property | At edcaebae | In the current code |
|---|---|---|---|
| N1 | Dirty, and nothing paused, draining or finalizing ⇒ a pass is queued or running | **violated** | holds with resume as one step (2,478,469 / 41). With resume as two steps: **violated** between AppModel 241 and 311 / 353, transiently; with that window excused (`N1x`) holds, a failing start included (3,746,646 / 42). *Previous:* `N1x` **violated** when the resumed start failed |
| N1s | The same for an input the scheduler never marked dirty | **violated** | as N1 (`N1sx`) |
| N2 | At most one `run` in flight; final and live never overlap | holds | holds |
| N3 | When `finish` returns true and no resume happened, no line is listening or found | as literally stated: **violated**, benignly. For lines not rewritten since the snapshot (`N3e`): holds | the same |
| N4 | A pass from before a resume never changes a line | **violated** | holds |
| N5 | A dirty meeting is eventually processed or paused | **violated** | holds (406,965 / 38; two-step resume 634,063 / 39). *Previous:* **violated** when a resumed start failed |
| N6 | The final pass is never skipped because another run is still in flight | **violated** | holds |
| N7 | Work a pass dropped because of a resume is picked up again | **violated** | holds. *Previous:* **violated** |
| N8 | The `schedule` call at the tail of `finishRecording` queues a pass only for input the final pass did not read | not applicable | holds when no 3 s retry is pending (867,464 / 38); one trace with a stale retry, which needs the timer to outlast a resume and a stop |

What is still open, what was found on the first round and how each fix compares with its sketch
are in "The code as fixed (current)" at the top. Two observations that are not failures:

* The guard `!running.contains(id)` at 242 is redundant in the current code: with the token fix
  `finish` always waits for the live pass, and dropping the guard alone no longer breaks N2
  (seen in an exploratory run on the first-round code; the configuration kept drops the token as
  well).
* The nil-branch guard at 286-288 also returns before the 3 s retry is armed and restores
  `lastRun`, which the sketch (`FixNilBranchFence`) did not.

## Findings at edcaebae

Kept as they were written against edcaebae; line numbers in this section are that commit's. What
became of each: **N1 / N5** (tail): holds now, fixed following the model, not replayed (needs AI
lines paused at the moment of Stop and a jot edit during the suspended final pass). **N1s**:
holds now, apart from a transient window in a recorder resume; not replayed (needs a Resume
through `start(resuming:)`). **N3**: unchanged, benign. **N4**: holds
now, replayed on the real code and fixed
(`RecordingRaceTests.testAFinalPassThatFoundNothingDoesNotSettleAResumedMeeting`). **N6**: holds
now, fixed following the model, not replayed (needs `schedule`, `yieldLive`, `schedule` before the
first task body runs). **N5 again** (`draining`): holds now.

### N1 / N5 — pressure is reset without telling the scheduler

`traces/NoteScheduler_edcaebae_paused_at_stop_edit_in_final_pass__violates_N1_NoLostWakeup.txt` (11 states)
and `…__violates_N5_DirtyEventuallyRuns.txt`.

1. Recognition falls behind: `updateRecordingPressure` sets pressure to `.aiPaused` (679) and
   calls `yieldLive` (687). `liveAIPaused` is now true.
2. Stop. `updateRecordingPressure` does nothing outside `"recording"` (674), so the pressure stays
   where it was for the whole final pass.
3. The final pass starts (`run(final: true)`, 238 clears `dirty`).
4. The user rewrites a jot. `editNote` calls `schedule`, which returns at **138** because AI is
   paused: nothing is recorded.
5. A patch from the final pass finds the jot changed: **257** `dirty.insert(id)`.
6. The run's defer (**241**) and `finish`'s defer (**178**) both call `schedule`; both return at
   138 again.
7. `finishRecording` line **487**: `recordingPressure = .normal`. No `schedule` call. The meeting
   is dirty, nothing is paused, and no pass is queued. Nothing ever wakes it; the rewritten jot
   keeps the line the final pass settled for the old wording until the user edits again.

The same hole is at `start` line 222 for a resume.
Confidence: **high** for the mechanism; it needs AI paused at the moment of Stop (lag ≥ 6 s, a
busy Mac) and a jot edit during the final pass.
Replay: `lagProbe` returning 7 while recording, `stop()` with a suspended enhancer, `editNote`
during it, release, then check that a pass runs for the edited jot.

### N1s — speech that arrives while paused

`traces/NoteScheduler_edcaebae_paused_speech_then_resume__violates_N1s_NoUnseenInput.txt` (7 states):
paused, a transcript line arrives (`schedule` returns at 138), Stop, Resume during the final pass
(222 un-pauses without scheduling; `finish` returns false at 186/191 and is not dirty). The line
is not looked at until the next transcript event. Low impact: speech normally continues after a
resume. Confidence: **high**.

### N3 — literal reading fails benignly

`traces/NoteScheduler_edcaebae_edit_after_final_snapshot__violates_N3_FinishSettles.txt` (8 states): the
final run settles the line, the user rewrites the jot before `finish` returns, `finish` returns
true with the line listening, and its defer (178) queues a post-stop pass that handles it. `N3e`
excludes lines rewritten after the final snapshot and holds; `MutNoSettle` breaks it.

### N4 — the final pass settles the lines of a meeting that is recording again

`traces/NoteScheduler_edcaebae_resume_in_final_pass__violates_N4_SupersededNeverApplies.txt` (8 states).

1. Stop; `finish` starts `run(final: true)`, which takes its generation at 236 and suspends at
   **247** in `enhance`.
2. Resume: new generation, new session, `Line.resume()` turns quiet/settled lines back to
   listening/answered.
3. `enhance` returns nil (no jot had anything new to answer). The `guard prepared != nil else`
   block (**263-281**) runs: 266 `await enhancer.searched(id)`, then **267-269**
   `if final … { settle every line }`. The generation / session / endedAt guard is at **282**,
   after this block, so it is never consulted.
4. Every line of the live, resumed meeting is settled; the run returns true.

The existing test `testFinalPassFromEarlierCaptureCannotOverwriteResumedNote` covers the branch
where `enhance` returns a result (guard at 282); this is the other branch. A post-stop live pass
(`stopped && searched`) has the same hole.
Confidence: **high**; it is straight-line code and needs only a resume during a final pass that
finds nothing new, which is the usual case when the jots were already answered live.
Replay: the same test with an enhancer that returns `nil` after being released, and a note whose
line is `.listening`; assert its state after the resume.

### N6 — a running live pass that the scheduler has lost track of

`traces/NoteScheduler_edcaebae_pressure_flap_then_stop__violates_N6_FinalPassNotSkipped.txt` (10 states).

1. A transcript line: `schedule` creates task P1, `pending = P1` (147-154). P1 has not run yet.
2. Pressure rises: `yieldLive` (164) removes P1 from `pending` and cancels it.
3. Pressure falls: `schedule` creates P2, `pending = P2`.
4. P1's body runs: **149** `live[id] = pending.removeValue(forKey: id)` takes **P2** out of
   `pending`; 151 P1 is cancelled; the defer at **150** sets `live[id] = nil`. P2 is now in
   neither map.
5. P2 runs its pass with `live[id]` nil. `yieldLive` can no longer cancel it, `beginStop` and
   `finish` (171, 182, 192) cannot cancel it, and `finish` does not wait for it at **184**.
6. Stop while P2 is running: `finish` goes straight to `run(final: true)`, whose guard at **230**
   fails on `running.contains(id)`. `success = false`: "the final lines couldn't be written".

Confidence: **medium**. It needs `schedule`, `yieldLive`, `schedule` to happen before P1's body
gets its turn, i.e. inside one main-actor job or in jobs already queued ahead of it. `consume`
and `updateRecordingPressure` run in the same pump job (AppModel 259-261), and the second pump or
the 100 ms level timer can supply the fall, so lag hovering around the 6 s threshold is the
condition to look for. The trace TLC prints has P2 start after Stop; P2 already running when Stop
arrives gives the same end state and is the likelier order.
Replay: with a test scheduler, call `schedule`, `yieldLive`, `schedule` synchronously, yield
until the enhancer is entered, then `finish` and assert it returns true.

### N5 again — `draining` left set

`traces/NoteScheduler_candidate_all_fixes_but_finish_draining__violates_N5_DirtyEventuallyRuns.txt`
(18 states). When a `finish` is already in flight, a second `finish` returns at **174** before
`draining.remove(id)` at 175. If that second call is the one `finishRecording` made right after
`beginStop` inserted `draining`, nothing removes it: every later `schedule` for the meeting
returns at 144 until some other `finish` runs. Today the usual way to get two overlapping
`finish` calls (Stop, Resume, Stop) is blocked by the R4 defect, which swallows the second Stop;
fixing R4 on its own would expose this. Recover's or the plugin's `finish` overlapping a quick
resume-and-stop reaches it now. Confidence: **medium** for reachability, **low** for frequency.

## Showing the passing properties can fail

Every property that holds on the current-code configurations, with the current code changed in
one place:

| Property | Change | Result |
|---|---|---|
| N1 | without `FixTailSchedules`; `MutYieldKeepsInputs` | violated, 11 and 4 states |
| N1s, N1sx | without `FixStartSchedules` | violated, 7 and 8 states |
| N1x, N1sx | without `FixCatchSchedules` (a failing resumed start) | violated, 8 states; and the `NoteScheduler_previous_resumed_start_fails__…` configurations |
| N2 | without `FixToken` and `MutNoRunningGuard` | violated, 8 states |
| N3e | `MutNoSettle` | violated, 7 states |
| N4 | without `FixNilGuard`; `MutNoPatchFence` | violated, 8 and 7 states |
| N5 | without `FixFinishDraining`; `MutNoDeferSchedule` | violated |
| N6 | without `FixToken` | violated, 10 states |
| N7 | without `FixRequeueSuperseded` | violated, 8 states |
| N8 | without `FixFinalRecordsInputs` (line 250) | violated, 8 states |

The edcaebae round's own table is reproduced by the `NoteScheduler_candidate_mutation_…` and
`NoteScheduler_edcaebae_mutation_…` configurations.

---

# Every run

186 configurations. **Not one run of the whole suite.** The rows marked `**` (28) were run in the
final round, after the fourth round of fixes: every `Retention_current_…` configuration
(`JOBS=4 ./run.sh Retention_current`). The rows marked `*` (39) were run one round earlier, after the
third round of fixes: `Retention_previous_…`, `NoteScheduler_current_…`, `NoteScheduler_previous_…`,
the two about `closeStreams`, and a few old ones as a check that the specs still give the recorded
counts. The unmarked rows are from the one full run before that (`JOBS=4 ./run.sh`, 183
configurations, all as recorded, 26 min 28 s on a 14-core Apple Silicon Mac); what changed for
them since is only constants that are off, or that act only together with a mutation they do not
have. Every row behaves as its name says. A fresh `JOBS=4 ./run.sh` is the way to confirm the
unmarked and single-starred rows against the specs as they are now.

`states` = distinct states, `depth` = how deep the search went, `trace` = states in the
counterexample, `seconds` = wall time with other configurations running beside it. Safety
runs reproduce these numbers exactly. For the liveness violations (`T5`, `T8`, `N5`, `R6`, `R6r`,
`R10`, `R14`) TLC stops at whichever periodic liveness check first finds a cycle, so the state
count and the trace it prints can differ slightly between runs; the verdict does not. `depth` of a
run that holds can differ by one or two with the number of workers.

The 74 configurations recorded at edcaebae are the `…_edcaebae_…` and `…_candidate_…` rows that
are not listed as added below. All 74 give the verdict recorded then, with the specs as they were
at the full run, and 71 the same distinct-state count. The three that differ: two liveness
violations (`NoteScheduler_candidate_all_fixes_but_finish_draining…` and
`…candidate_mutation_no_defer_schedule…`, where TLC stops at a different periodic check), and
`Recording_edcaebae_captions__holds`, 202,961 states where 217,424 were recorded: the correction
to R3's check described under Machine 1 removed a history flag that used to split states. Added
since for the edcaebae column: `Recording_edcaebae_recorder_stop_only_its_own_session`,
`…_calls_return`, `…_start_during_quit`, `…_finalize_fails_after_resume`,
`Recording_edcaebae_captions_refused_resume_forgets_error`, `Recording_edcaebae_monitor_refused_start`,
`Retention_edcaebae_trashed_meeting_stays_searchable`, `Retention_edcaebae_document_resume_crash_done`,
`Retention_edcaebae_resume_crash_then_deadline`, `NoteScheduler_edcaebae_pass_superseded_by_resume`.

```
configuration                                                                                                result        states  depth  trace seconds
Recording_candidate_auto_all_fixes__holds                                                                    holds        4924352     45      -     203
Recording_candidate_captions_all_fixes__holds                                                                holds          56344     33      -      31
Recording_candidate_mutation_final_pass_hangs__violates_R6r_AcceptedStopSettlesUnlessResumed                 violated        2028     20     16       1
Recording_candidate_mutation_finish_keeps_status__violates_R1b_OneRecordingOnDisk                            violated         968     13     13       0
Recording_candidate_mutation_finish_keeps_status__violates_R2_NoOrphan                                       violated         970     13     13       1
Recording_candidate_mutation_no_busy_guard__violates_R3_NoDoubleStart                                        violated           4      3      3       1
Recording_candidate_mutation_no_capture_handoff__violates_R1a_OneCaptureOwner                                violated         401     11     11       1
Recording_candidate_mutation_no_generation_fence__violates_R5a_SupersededNeverSetsPhase                      violated        1208     13     13       0
Recording_candidate_recorder_all_fixes__holds                                                                holds         470378     42      -     398
Recording_candidate_recorder_fix_catch_only__holds                                                           holds        1221758     39      -      30
Recording_candidate_recorder_fix_recheck_after_finalize_only__holds                                          holds         274967     39      -       4
Recording_candidate_recorder_fix_stop_join_and_recheck__holds                                                holds        3505962     43      -     130
Recording_candidate_recorder_fix_stop_join_recheck_and_fail_recheck__holds                                   holds        3304129     43      -     127
Recording_candidate_recorder_fix_stop_join_recheck_and_quit_block__holds                                     holds         496710     42      -      12
Recording_current_auto__holds                                                                                holds        3106984     46      -     100
Recording_current_auto_liveness__holds                                                                       holds          12764     32      -       9
Recording_current_captions__holds                                                                            holds          36952     34      -       1 *
Recording_current_captions_liveness__holds                                                                   holds          36952     34      -      29
Recording_current_monitor_auto__holds                                                                        holds         390982     48      -       8
Recording_current_monitor_captions__holds                                                                    holds        2573129     51      -      84
Recording_current_monitor_recorder__holds                                                                    holds          67081     43      -       3
Recording_current_monitor_without_start_did_not_begin__violates_R12_AutoStartNotStuck                        violated         128      7      7       0
Recording_current_mutation_close_streams_hangs__holds                                                        holds         149776     33      -      15 *
Recording_current_mutation_final_pass_hangs__violates_R14_StopReturns                                        violated        2279     22     17       2
Recording_current_mutation_final_pass_hangs__violates_R6r_AcceptedStopSettlesUnlessResumed                   violated        2279     22     16       1
Recording_current_mutation_finish_keeps_status__violates_R1b_OneRecordingOnDisk                              violated         825     13     13       1
Recording_current_mutation_finish_keeps_status__violates_R2_NoOrphan                                         violated         826     13     13       1
Recording_current_mutation_no_busy_guard_recorder__violates_R3_NoDoubleStart                                 violated          25      6      6       1
Recording_current_mutation_no_capture_handoff__violates_R1a_OneCaptureOwner                                  violated         351     11     11       0
Recording_current_mutation_no_stop_join__violates_R13_OneFinishPerSession                                    violated          36      7      7       1
Recording_current_mutation_read_hangs_auto__violates_R10_StartReturns                                        violated           6      4      3       0
Recording_current_mutation_status_after_final_pass__violates_R5c_SupersededNeverWritesStatus                 violated         352     11     11       1
Recording_current_recorder__holds                                                                            holds        1230347     43      -      44
Recording_current_recorder_liveness__holds                                                                   holds         149776     33      -     194
Recording_current_recorder_resume__violates_R6_AcceptedStopSettles                                           violated          41     17     16       0
Recording_current_without_bounded_close_mutation_close_streams_hangs__violates_R10_StartReturns              violated        7522     17      4       4 *
Recording_current_without_catch_local__violates_R5d_SupersededNeverSetsError                                 violated        1067     13     13       1
Recording_current_without_catch_own__violates_R7_FailedStartSparesOtherMeetings                              violated         206     10     10       1
Recording_current_without_fail_recheck__violates_R8_FailureStopsRecording                                    violated          28      6      6       0
Recording_current_without_inner_generation_check_auto_cold_speech__violates_R5b_SupersededNeverFinalizes     violated         777     12     12       1
Recording_current_without_late_reset_captions__violates_R15_InterruptedStopEndsInError                       violated         445     11     11       1
Recording_current_without_quit_flag_recorder__violates_R9_QuitLeavesNothingRecording                         violated          14      4      4       0
Recording_current_without_quit_recheck_auto__violates_R9_QuitLeavesNothingRecording                          violated          27      5      5       1
Recording_current_without_start_claim_auto__violates_R3_NoDoubleStart                                        violated          21      5      5       1
Recording_current_without_start_claim_captions__violates_R3_NoDoubleStart                                    violated          24      5      5       0
Recording_current_without_stop_asked__violates_R11_StopOnlyItsOwnSession                                     violated        5168     16     16       1
Recording_current_without_stop_loop__violates_R4_StopNotSwallowed                                            violated        6176     16     16       1
Recording_current_without_tail_guard__violates_R5a_SupersededNeverSetsPhase                                  violated        1065     13     13       1
Recording_edcaebae_auto_cold_speech_resume__violates_R5b_SupersededNeverFinalizes                            violated          44     12     12       1
Recording_edcaebae_auto_two_starts__violates_R1a_OneCaptureOwner                                             violated          17      7      7       0
Recording_edcaebae_auto_two_starts__violates_R3_NoDoubleStart                                                violated          13      5      5       1
Recording_edcaebae_captions__holds                                                                           holds         202961     31      -       4
Recording_edcaebae_captions_refused_resume_forgets_error__violates_R15_InterruptedStopEndsInError            violated        3803     11     11       1
Recording_edcaebae_captions_two_starts__violates_R1b_OneRecordingOnDisk                                      violated           7      5      5       1
Recording_edcaebae_captions_two_starts__violates_R3_NoDoubleStart                                            violated          14      5      5       0
Recording_edcaebae_captions_two_starts_then_stop__violates_R2_NoOrphan                                       violated         106     13     13       1
Recording_edcaebae_monitor_refused_start__violates_R12_AutoStartNotStuck                                     violated         251      7      7       1
Recording_edcaebae_mutation_resume_any_progress__holds                                                       holds        1220867     39      -      24
Recording_edcaebae_mutation_status_after_final_pass__violates_R5c_SupersededNeverWritesStatus                violated         468     11     11       1
Recording_edcaebae_recorder__holds                                                                           holds        1220867     39      -     925
Recording_edcaebae_recorder_calls_return__holds                                                              holds         239984     30      -     207
Recording_edcaebae_recorder_document_meetings__holds                                                         holds         231783     33      -       4
Recording_edcaebae_recorder_failure_during_screen_start__violates_R8_FailureStopsRecording                   violated          10      6      6       1
Recording_edcaebae_recorder_finalize_fails_after_resume__violates_R5d_SupersededNeverSetsError               violated        3187     13     13       0
Recording_edcaebae_recorder_quit_after_resume__violates_R9_QuitLeavesNothingRecording                        violated          73     12     12       1
Recording_edcaebae_recorder_resume__violates_R6_AcceptedStopSettles                                          violated          51     17     16       1
Recording_edcaebae_recorder_resume_in_final_pass__violates_R2_NoOrphan                                       violated          49     17     17       0
Recording_edcaebae_recorder_resume_in_final_pass__violates_R5a_SupersededNeverSetsPhase                      violated          27     13     13       1
Recording_edcaebae_recorder_resume_then_start__violates_R1a_OneCaptureOwner                                  violated          57     16     16       1
Recording_edcaebae_recorder_resume_then_start__violates_R1b_OneRecordingOnDisk                               violated          36     14     14       0
Recording_edcaebae_recorder_stall_then_start__violates_R7_FailedStartSparesOtherMeetings                     violated          19     13     13       1
Recording_edcaebae_recorder_start_during_quit__violates_R9_QuitLeavesNothingRecording                        violated           9      4      4       1
Recording_edcaebae_recorder_stop_only_its_own_session__holds                                                 holds         239984     30      -       4
Recording_edcaebae_recorder_stop_resume_stop__violates_R4_StopNotSwallowed                                   violated         152     16     16       1
Recording_previous_auto_quit_while_start_reads_zoom__violates_R9_QuitLeavesNothingRecording                  violated          27      5      5       1
Recording_previous_auto_refused_resume_forgets_error__violates_R15_InterruptedStopEndsInError                violated        2015     13     13       0
Recording_previous_captions_quit_while_start_reads_zoom__violates_R9_QuitLeavesNothingRecording              violated          24      5      5       1
Recording_previous_captions_refused_resume_forgets_error__violates_R15_InterruptedStopEndsInError            violated         526     11     11       1
Recording_previous_captions_stop_twice_then_resume__violates_R11_StopOnlyItsOwnSession                       violated         683     12     12       0
Recording_previous_recorder_finalize_fails_after_resume__violates_R5d_SupersededNeverSetsError               violated        1067     13     13       1
Recording_previous_recorder_finalize_fails_after_resume__violates_R8_FailureStopsRecording                   violated       11147     17     17       1
Recording_previous_recorder_stop_twice_then_resume__violates_R11_StopOnlyItsOwnSession                       violated        5170     16     16       1
Retention_candidate_all_fixes_T5__holds                                                                      holds         248365     33      -      69
Retention_candidate_all_fixes_resume_crash_done__violates_T7_PurgeOnlyFinalizedSession                       violated         935      6      6       1
Retention_candidate_all_fixes_trash_before_finalize_with_conversation__violates_T5_EventuallyPurged          violated         292     19      7       1
Retention_candidate_all_fixes_wide__holds                                                                    holds        1346281     34      -      71
Retention_candidate_fix_finalize_checks_receipt_only__holds                                                  holds        2044542     33      -     101
Retention_candidate_mutation_no_index_fence__violates_T3_NoResurrection                                      violated       18259      9      9       2
Retention_candidate_mutation_no_journal__violates_T1_JournalFirst                                            violated        7961      8      8       1
Retention_candidate_mutation_no_store_fence__violates_T3_NoResurrection                                      violated        1304      6      6       1
Retention_current_T5__holds                                                                                  holds         224183     29      -      77 **
Retention_current_T5_document__holds                                                                         holds         220647     37      -      93 **
Retention_current_T5_index_unavailable__violates_T5_EventuallyPurged                                         violated           6      5      6       1 **
Retention_current_T5_note_opened_later__holds                                                                holds         119256     30      -      35 **
Retention_current_T5_trash_before_finalize_no_conversation__holds                                            holds         127824     29      -      63 **
Retention_current_T5_trash_before_finalize_with_conversation__violates_T5_EventuallyPurged                   violated         342     19      7       1 **
Retention_current_T5_unreadable_before_finalize__violates_T5_EventuallyPurged                                violated         181     20      6       1 **
Retention_current_T5_unreadable_finalized_transcript__holds                                                  holds         143144     28      -      35 **
Retention_current_T5_unreadable_resumed_meeting_in_memory__holds                                             holds            266     20      -       0 **
Retention_current_T5_vault_unavailable__violates_T5_EventuallyPurged                                         violated          10      6      7       1 **
Retention_current_document__holds                                                                            holds        1926658     41      -      68 **
Retention_current_mutation_no_L116_check__violates_T6_NotPurgedWhileRecording                                violated        5173      8      8       1 **
Retention_current_mutation_no_index_fence__violates_T3_NoResurrection                                        violated       11017      8      8       2 **
Retention_current_mutation_no_journal__violates_T1_JournalFirst                                              violated        3974      7      7       1 **
Retention_current_mutation_no_store_fence__violates_T3_NoResurrection                                        violated        1182      6      6       1 **
Retention_current_mutation_purge_skips_index__violates_T2_PurgedMeansGone                                    violated       10983      8      8       1 **
Retention_current_note_opened_later__holds                                                                   holds        1058439     35      -      46 **
Retention_current_unreadable_resumed_meeting_purged_on_first_clock__violates_T9_LoopPurgesOnTheLastStopsClock violated         164     12     12       0 **
Retention_current_wide__holds                                                                                holds        4199578     36      -     120 **
Retention_current_without_L116_fix_trashed_meeting__violates_T5_EventuallyPurged                             violated          38     14      8       1 **
Retention_current_without_done_recheck__violates_T6_NotPurgedWhileRecording                                  violated        2247      6      6       0 **
Retention_current_without_finalize_receipt_check__violates_T4_NoRegression                                   violated        5264      7      7       1 **
Retention_current_without_indexer_fix__violates_T8_TrashedLeavesIndex                                        violated          33     14      6       1 **
Retention_current_without_recover_live_resume_then_crash__violates_T5_EventuallyPurged                       violated         203     23      9       1 **
Retention_current_without_replay_rule_document_interrupted_purge__violates_T5_EventuallyPurged               violated      152226     20     17      64 **
Retention_current_without_stale_recheck_in_done__violates_T7_PurgeOnlyFinalizedSession                       violated       18206      8      8       3 **
Retention_current_without_stale_rule_in_done__violates_T7_PurgeOnlyFinalizedSession                          violated         882      6      6       0 **
Retention_current_without_stale_rule_in_recover__violates_T9_LoopPurgesOnTheLastStopsClock                   violated         132     10     10       1 **
Retention_edcaebae_T5_index_unavailable__violates_T5_EventuallyPurged                                        violated           8      6      7       0
Retention_edcaebae_T5_no_hazards__holds                                                                      holds            160     19      -       0
Retention_edcaebae_T5_resume_no_crash__holds                                                                 holds             89     22      -       1
Retention_edcaebae_T5_resume_then_crash__violates_T5_EventuallyPurged                                        violated         235     23      7       1
Retention_edcaebae_T5_trashed_finalized_meeting__violates_T5_EventuallyPurged                                violated          33     14      7       1
Retention_edcaebae_T5_unreadable_transcript__violates_T5_EventuallyPurged                                    violated          43     15      8       1
Retention_edcaebae_document_resume_crash_done__violates_T7_PurgeOnlyFinalizedSession                         violated        1520      6      6       1
Retention_edcaebae_done_then_plugin_finalize__violates_T1_JournalFirst                                       violated          96     10     10       1
Retention_edcaebae_done_then_plugin_finalize__violates_T4_NoRegression                                       violated          20      7      7       0
Retention_edcaebae_done_without_receipt_then_resume__violates_T6_NotPurgedWhileRecording                     violated          99      6      6       1
Retention_edcaebae_mutation_no_L116_check__violates_T6_NotPurgedWhileRecording                               violated        3648      8      8       1
Retention_edcaebae_mutation_purge_skips_index__violates_T2_PurgedMeansGone                                   violated       16307      9      9       2
Retention_edcaebae_no_plugin_finalize_no_resume__holds                                                       holds          29501     24      -       2
Retention_edcaebae_no_user_done__holds                                                                       holds         124668     34      -       2 *
Retention_edcaebae_regression_then_trash_and_late_save__violates_T3_NoResurrection                           violated          62      8      8       1
Retention_edcaebae_resume_crash_done__violates_T7_PurgeOnlyFinalizedSession                                  violated          70      6      6       1
Retention_edcaebae_resume_crash_then_deadline__violates_T9_LoopPurgesOnTheLastStopsClock                     violated          59      7      7       0 *
Retention_edcaebae_trashed_meeting_stays_searchable__violates_T8_TrashedLeavesIndex                          violated          33     14      7       1
Retention_edcaebae_wide__holds                                                                               holds        2926433     38      -     217
Retention_previous_T5_unreadable_resumed_meeting_in_memory__violates_T5_EventuallyPurged                     violated         246     19     11       0 *
Retention_previous_document_done_then_undo__violates_T7_PurgeOnlyFinalizedSession                            violated        1168      6      6       1 *
Retention_previous_document_interrupted_purge_note_reopened__holds                                           holds         274339     37      -      25 *
Retention_previous_done_then_resume_and_failing_finalize__violates_T7_PurgeOnlyFinalizedSession              violated       18206      8      8       1 *
Retention_previous_done_then_resume_and_note_opened__violates_T7_PurgeOnlyFinalizedSession                   violated       19877      9      9       2 *
NoteScheduler_candidate_all_fixes__holds                                                                     holds        2184742     40      -     527
NoteScheduler_candidate_all_fixes_but_finish_draining__violates_N5_DirtyEventuallyRuns                       violated      209559     17     17      66
NoteScheduler_candidate_mutation_no_defer_schedule__violates_N5_DirtyEventuallyRuns                          violated       15759     12      7       4
NoteScheduler_candidate_mutation_no_patch_fence__violates_N4_SupersededNeverApplies                          violated         589      7      7       0
NoteScheduler_candidate_mutation_no_steal_fix__violates_N6_FinalPassNotSkipped                               violated        5133     10     10       1 *
NoteScheduler_candidate_mutation_yield_keeps_inputs__violates_N1_NoLostWakeup                                violated          18      4      4       1
NoteScheduler_current__holds                                                                                 holds        2478469     41      -     107 *
NoteScheduler_current_edit_after_final_snapshot__violates_N3_FinishSettles                                   violated         237      8      8       1 *
NoteScheduler_current_liveness__holds                                                                        holds         406965     38      -     123 *
NoteScheduler_current_mutation_no_defer_schedule__violates_N5_DirtyEventuallyRuns                            violated       17971     13      9       3 *
NoteScheduler_current_mutation_no_patch_fence__violates_N4_SupersededNeverApplies                            violated         659      7      7       0 *
NoteScheduler_current_mutation_no_settle__violates_N3e_FinishSettlesUneditedLines                            violated         994      7      7       1 *
NoteScheduler_current_mutation_yield_keeps_inputs__violates_N1_NoLostWakeup                                  violated          18      4      4       0 *
NoteScheduler_current_retry_fires_in_paused_final_pass__violates_N8_TailScheduleOnlyForNewInput              violated     1247740     22     22     115 *
NoteScheduler_current_start_awaits__holds                                                                    holds        3746646     42      -     140 *
NoteScheduler_current_start_awaits_dirty_before_schedule__violates_N1_NoLostWakeup                           violated       24805     11     11       1 *
NoteScheduler_current_start_awaits_liveness__holds                                                           holds         634063     39      -      71 *
NoteScheduler_current_start_awaits_mutation_no_start_schedule__violates_N1sx_NoUnseenInputOutsideStart       violated        2085      8      8       1 *
NoteScheduler_current_start_awaits_unseen_before_schedule__violates_N1s_NoUnseenInput                        violated         839      7      7       0 *
NoteScheduler_current_tail_schedule__holds                                                                   holds         867464     38      -      21 *
NoteScheduler_current_without_catch_schedule__violates_N1sx_NoUnseenInputOutsideStart                        violated        2113      8      8       1 *
NoteScheduler_current_without_final_inputs__violates_N8_TailScheduleOnlyForNewInput                          violated        2286      8      8       0 *
NoteScheduler_current_without_finish_draining__violates_N5_DirtyEventuallyRuns                               violated      236608     21     20      65 *
NoteScheduler_current_without_nil_branch_guard__violates_N4_SupersededNeverApplies                           violated        2374      8      8       0 *
NoteScheduler_current_without_requeue__violates_N7_AbandonedWorkRequeued                                     violated        1663      8      8       1 *
NoteScheduler_current_without_start_schedule__violates_N1s_NoUnseenInput                                     violated         821      7      7       0 *
NoteScheduler_current_without_tail_schedule__violates_N1_NoLostWakeup                                        violated       19437     11     11       1 *
NoteScheduler_current_without_token__violates_N6_FinalPassNotSkipped                                         violated        6642     10     10       1 *
NoteScheduler_current_without_token_mutation_no_running_guard__violates_N2_OneRun                            violated        1207      8      8       0 *
NoteScheduler_edcaebae__holds                                                                                holds        3822570     42      -      87
NoteScheduler_edcaebae_edit_after_final_snapshot__violates_N3_FinishSettles                                  violated          77      8      8       1
NoteScheduler_edcaebae_mutation_no_running_guard__violates_N2_OneRun                                         violated        1042      8      8       0
NoteScheduler_edcaebae_mutation_no_settle__violates_N3e_FinishSettlesUneditedLines                           violated         876      7      7       1
NoteScheduler_edcaebae_pass_superseded_by_resume__violates_N7_AbandonedWorkRequeued                          violated        1557      8      8       0
NoteScheduler_edcaebae_paused_at_stop_edit_in_final_pass__violates_N1_NoLostWakeup                           violated         713     11     11       1
NoteScheduler_edcaebae_paused_at_stop_edit_in_final_pass__violates_N5_DirtyEventuallyRuns                    violated        1129     19     13       1
NoteScheduler_edcaebae_paused_speech_then_resume__violates_N1s_NoUnseenInput                                 violated         235      7      7       0
NoteScheduler_edcaebae_pressure_flap_then_stop__violates_N6_FinalPassNotSkipped                              violated         481     10     10       0
NoteScheduler_edcaebae_resume_in_final_pass__violates_N4_SupersededNeverApplies                              violated          30      8      8       0 *
NoteScheduler_edcaebae_three_slots__violates_SlotsSuffice                                                    violated        4959     10     10       1
NoteScheduler_previous_pass_superseded_by_resume__violates_N7_AbandonedWorkRequeued                          violated        1495      8      8       0 *
NoteScheduler_previous_resumed_start_fails__violates_N1sx_NoUnseenInputOutsideStart                          violated        2123      8      8       0 *
NoteScheduler_previous_resumed_start_fails__violates_N1x_NoLostWakeupOutsideStart                            violated       25626     11     11       1 *
NoteScheduler_previous_resumed_start_fails__violates_N5_DirtyEventuallyRuns                                  violated      386916     22     15      66 *
```

The constants of each run are in its `.cfg`, with a comment line saying what it is for.
