# WorkScribe's state machines, and what has been checked about them

WorkScribe has very few types that call themselves a state machine. Most of its behaviour over time lives in
combinations of flags, optionals, task handles and files on disk. This document lists those machines, says which
ones were given a formal check and what that check does and does not establish, and records the defects found.

Written against commit `edcaeba` (public main) plus the changes on branch `codex-backend`. A model keeps passing
after the code it describes has changed; when a file listed under "covers" changes, re-read the model before
trusting its result.

## How to run everything

```sh
brew install openjdk elan-init                      # a JVM for TLC, and the Lean toolchain manager
mkdir -p ~/Library/Caches/WorkScribe/formal && curl -fsSL -o ~/Library/Caches/WorkScribe/formal/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar

JOBS=4 formal/verify.sh          # everything below, in order; exits non-zero if any part does (JOBS = model
                                 # configurations checked at a time; roughly half an hour with 4)

formal/tla/check_codex.sh        # CodexSession: 3 runs that must pass, 6 mutations, 4 reachability checks
formal/tla/check_screen.sh       # ScreenWatch: 2 runs that must pass, 5 mutations, 3 reachability checks
JOBS=4 formal/tla/run.sh         # 243 configurations. Recording, Retention, NoteScheduler: 186 (formal/tla/README.md);
                                 # IndexPurge, VaultNote: 20 (formal/tla/IndexPurge-VaultNote.md); PluginNote: 37 (formal/tla/PluginNote.md)
(cd obsidian-plugin && npm test) # the plugin's replays; with WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe also against the real app
(cd formal/lean && lake build --wfail)   # every Lean theorem; no Mathlib, seconds once the toolchain is there

# the models and proofs, held against the real Swift:
swift test --filter 'CodexSessionTests|CodexAppServerTests|ScreenWatchTests|ScreenDayTests|ScreenWatcherTests|FormalConformanceTests|RecordingRaceTests|RetentionRaceTests|IndexPurgeTests|VaultStoreTests|LateResultsTests'
.build/debug/WorkScribe --verify-codex          # the real Codex, through the app's own code
.build/debug/WorkScribe --verify-screen 30      # the real screen (needs Accessibility or Screen Recording)
```

## What each kind of check means here

| Layer | Runs on | Covers | Rests on |
| --- | --- | --- | --- |
| TLA+ / TLC | a hand-written model of the design | every ordering of the modelled steps, up to the stated bound | the model matching the code, including what counts as one indivisible step; the bound being large enough; the environment doing only what the model lets it |
| Lean | a re-implementation of a pure function in Lean | every input, every length of history | the Lean definitions matching the Swift line for line; the theorem saying what you care about |
| Conformance tests | the real Swift | thousands of generated sequences | the generator reaching the bad case; the asserted property being the right one |
| Scripted tests, `--verify-*` | the real Swift / the real system | the paths walked | those paths being the ones that matter |

Two habits apply to every model in this folder. A property that has only ever passed proves nothing, so each
model has **mutations**: the same model with one rule removed, which must then fail (`check_*.sh` runs them and
fails if one unexpectedly passes). And a counterexample from a model is a hypothesis about the code until it is
replayed against the code; the "replayed" column below says whether that was done.

## The machines

Evidence for a hazard: **model** = TLC counterexample, **proof** = Lean theorem, **run** = reproduced by executing
the real code, **read** = confirmed by reading the cited lines, **hyp** = hypothesis not yet confirmed.

### Formally checked

| Machine | Code it covers | Check | Result |
| --- | --- | --- | --- |
| Codex text session | `Sources/WorkScribeCore/Codex/CodexSession.swift` | `tla/CodexSession.tla`; `CodexSessionTests` (scripted + 4,000 random orders on the real reducer); `CodexAppServerTests` (real process, real pipes); `--verify-codex` | Holds. See below. |
| Screen watch | `Sources/WorkScribeCore/ScreenWatch.swift` | `tla/ScreenWatch.tla`; `ScreenWatchTests` (scripted + 3,000 random orders) | Holds. See below. |
| Recording lifecycle | `Sources/WorkScribe/AppModel.swift` (`start`, `stop`, `finishRecording`, `fail`, resume, quit) | `tla/Recording.tla`; `RecordingRaceTests` | Defects found and fixed; see the table below and `tla/README.md`. |
| Retention and purge | `Sources/WorkScribe/MeetingRetention.swift`, `Sources/WorkScribeCore/Retention.swift`, store fences in `Meeting.swift` | `tla/Retention.tla`; `RetentionRaceTests` | Defects found and fixed; one left open. |
| Note enhancement scheduler | `Sources/WorkScribe/MeetingNotes.swift` (`NoteEnhancementScheduler`) | `tla/NoteScheduler.tla`; `RecordingRaceTests` | Defects found and fixed. |
| AI line lifecycle | `Sources/WorkScribeCore/Engine/Line.swift`, `Notes.swift`, and the places outside `Line` that write its state | `lean/Formal/Line.lean`; `FormalConformanceTests` | Two defects found and fixed; see `lean/README.md`. |
| Auto-record policy | `Sources/WorkScribeCore/AutoRecordPolicy.swift` | `lean/Formal/AutoRecord.lean`; `FormalConformanceTests` | A latch that could stick, fixed; one limitation by design. |
| Audio backlog accounting | `Sources/WorkScribeCore/AudioBacklog.swift` | `lean/Formal/Backlog.lean`; `FormalConformanceTests` | Holds: no invariant was false. |
| Recording pressure, resume, title policy | `AudioBacklog.swift`, `RecordingSession.swift`, `TitlePolicy.swift` | `lean/Formal/Small.lean` | Holds. |
| What the search index holds for a purged meeting | `Sources/WorkScribe/IndexService.swift` (`purgeMeeting`), `Search/SearchIndexVectors.swift` (`purge`), `Engine/Index.swift` (`apply`), `MeetingRetention.done`, `AttachmentIndexer` | `tla/IndexPurge.tla`; `IndexPurgeTests`, `RetentionRaceTests` | Three defects found and fixed; see below and `tla/IndexPurge-VaultNote.md`. |
| One vault note written by WorkScribe and by Obsidian | `Sources/WorkScribeCore/Vault/VaultStore.swift` (`exchange` behind `replace`, `removeMarkers`) | `tla/VaultNote.tla`; `VaultStoreTests` | Two defects found and fixed, and one in the first design of the fix; see below. |
| The plugin keeping a meeting's note in step with the app, and finalize | `obsidian-plugin/src/ui/note-editor.ts` (sync lane, `finalize`, `open`, the poll), `src/main.ts` (`meetingPurged`) | `tla/PluginNote.tla`; `obsidian-plugin/test/note-sync.test.ts`, `finalize-merge.test.ts` (the real `NoteEditor` with stand-ins for Obsidian and the app) | Seven groups of defects found and fixed; see below and `tla/PluginNote.md`. |

#### Defects the models and proofs found in existing code

"Replayed" means the model's trace was turned into a test on the real types, the test failed on the code as it was,
and passes now. "By construction" means the fix follows the model's validated fix but no test reproduces the
original failure (the reason is given in `tla/README.md`).

| # | What went wrong, as a user would meet it | Found by | Replayed on real code | Now |
| --- | --- | --- | --- | --- |
| R4 | Stop, Resume while notes are finishing, Stop again: the second Stop did nothing and the recording carried on. | TLC, 16 states | Yes: `RecordingRaceTests.testASecondStopAfterAResumeStopsTheResumedRecording` | Fixed |
| R5a | Resume at the very end of a Stop: the app showed "ready" while it was still recording, and a new Start then made a second capture nothing could stop. | TLC, 13 states | Yes: `…testTheTailOfAnOldStopDoesNotDeclareAResumedRecordingReady` | Fixed |
| R3 | Two starts close together with the transcript source on "auto" or "Zoom captions" both went through: two captures, or an orphaned meeting left "recording". | TLC, 5 states | No | Fixed by construction: a start claims the slot before it can suspend |
| R7 | A start that failed before it had a meeting of its own marked the *previous* meeting as failed. | TLC, 13 states | No | Fixed by construction |
| R8 | An audio source failing while screen capture was starting was forgotten; the recording carried on as if healthy. | TLC, 6 states | No | Fixed by construction |
| R9 | Quit during the same Stop/Resume window could exit with a meeting still "recording". | TLC, 12 states | No | Fixed by construction |
| T7, T5d | A meeting that was resumed and then cut off (the app died) was purged on the first Stop's deadline, deleting the second session before it reached the note; or was never finalized at all. | TLC, 6 states | Yes: `RetentionRaceTests.testAResumedThenInterruptedMeetingIsFinalizedAgainBeforeAnyPurge` | Fixed |
| T5a | A finalized meeting moved to the Trash was never purged, and its transcript stayed searchable. | TLC; also found by reading | Yes: `…testAFinalizedMeetingMovedToTheTrashIsStillPurgedAtItsDeadline`, `…testATrashedMeetingsRowsLeaveTheIndex` | Fixed |
| T4 | A Finalize arriving while Done was deleting wrote "finalized" over the "purging" journal entry. | TLC, 7 states | Yes: `…testFinalizeNeverOverwritesAPurgeInProgress` | Fixed |
| T6 | Done could mark a meeting "purging" after it had been resumed. | TLC, 6 states | No | Fixed by construction |
| T5c | With the search index unavailable, Done journalled "purging" and then failed every minute: shown as purged, transcript still on disk. | TLC | No | Fixed by construction: the index is checked before the journal is written |
| T5e | A meeting trashed before it was ever finalized leaves conversations scoped to it for ever. | TLC | No | **Open** |
| N4 | A final pass that found nothing to write settled the lines of a meeting that had just been resumed. | TLC, 8 states | Yes: `RecordingRaceTests.testAFinalPassThatFoundNothingDoesNotSettleAResumedMeeting` | Fixed |
| N1, N5 | A note edited during the final pass, with AI lines paused at Stop, stayed "dirty" with nothing scheduled, for good. | TLC, 11 states | No | Fixed by construction |
| N6 | A cancelled-and-replaced live pass took its replacement's slot; Stop then did not wait for the pass and the final lines failed to write. | TLC, 10 states | No | Fixed by construction |
| Line 1 | A late image caption or OCR result sent an already-answered line back to "listening", which is never drawn: the answer vanished. | Lean (`imagePublish_breaks_wf`) | By the conformance test's transcription of that site | Fixed: `Line.recheck()` keeps the answer and forgets the line's basis, so the engine takes the jot up again |
| Line 2 | Changing a note's pictures cleared its line without raising the revision and kept the history, so the same sentence could never be written again and the line stayed blank. | Lean (`docImagesChanged_clears_text_without_bump`, `…_blocks_previous_text`) | Yes, on the real `NoteDocument.notes(previous:)` | Fixed: the line is reset |
| Auto 1 | After one automatic start was asked for, the call was never asked for again, even if that start never began. | Lean (`stuck_latch`) | Yes, on the real `AutoRecordPolicy` | Fixed: `startDidNotBegin()` |
| Auto 2 | After a manual Stop, a different call that begins less than two minutes after the first ends is never auto-recorded. | Lean (`suppressed_until_long_absence`) | Yes | **By design**: with mute gaps tolerated, the app cannot tell a muted call from a new one |

#### Found when the models were run again, against the fixes

The fixes above were then modelled as they were actually written and the models run again. That found one defect
the fixes had introduced and several older or narrower ones. Each is now fixed in the code and modelled as written;
`tla/README.md`, "The code as fixed (current)", has the traces.

| # | What went wrong | Found by | Replayed on real code | Now |
| --- | --- | --- | --- | --- |
| R11 | Stop pressed twice, then Resume: once the first stop gave way to the resume, the second Stop ended the resumed recording. **Introduced by the fix for R4.** | TLC, 16 states | Yes: `RecordingRaceTests.testAStopPressedDuringTheFinalPassDoesNotEndARecordingResumedSince` | Fixed: a Stop only ends the session it was asked of (quit excepted) |
| R5d, R8 | A stop overtaken by a resume, whose last step then failed, wrote its error into the resumed recording: an error nobody acted on, or a resume that failed to start. | TLC, 13 and 17 states | No | Fixed by construction |
| R9 | With the transcript source on "auto" or "Zoom captions": Quit while a start was still reading Zoom's window let the app exit with a meeting "recording" on disk. | TLC, 5 states | No | Fixed by construction |
| R15 | A captions resume that was refused had already wiped the progress and the error of the stop still running. Also in the base commit. | TLC, 11 states | No | Fixed by construction |
| R10 | A start that failed kept the start slot for as long as closing the recognizer's streams took; if that never returned, no start was accepted until relaunch. | Reading, while modelling | No | Fixed: that wait is bounded. The slot is still held while it waits, so for up to 30 s after such a failure Start does nothing |
| T7 | Done on a meeting that was then resumed and stopped again (or whose finalize was undone) while its note was still being indexed: the purge went ahead on a note that did not hold the last session. Needs an index stuck for that long. | TLC, 6 to 9 states | No: the test harness has no slow index | Fixed by construction: Done looks again after its own finalize |
| T5, interrupted purge | A purge that was journalled and then cut short was turned away every minute if the note had been opened again meanwhile: the transcript stayed on disk under a "purging" receipt. **Introduced by the T7 fix in the row above.** | TLC | Yes, the state it leaves behind: `RetentionRaceTests.testAnInterruptedPurgeIsCarriedOutEvenIfTheNoteWasReopenedInMemory` | Fixed: a journalled purge is replayed as it stands |
| T5 (b″) | A resumed meeting whose second finalize failed and whose transcript then became unreadable on disk was skipped by the purge loop for as long as the app kept its copy in memory. | TLC | No | Fixed by construction: the loop judges by the copy on disk |
| N7 | A pass that gave up because the meeting was resumed dropped the jots it had taken; they waited for the next line of speech or the next edit. Also in the base commit. | TLC, 8 states | Yes: `RecordingRaceTests.testAPassThatGivesUpAtAResumeLeavesItsWorkToBeAskedForAgain` | Fixed |
| N5 | A resume that failed to start left the meeting's waiting notes unasked for up to a minute. | TLC | No | Fixed by construction |

Two of these rows were introduced by an earlier fix and caught only because the fixed code was modelled again.
That is the reason to keep doing it: after any change to `start`, `stop`, `finishRecording`, `done`, `recover` or
the scheduler's `run`, update the model and run `tla/run.sh`.

#### Found by the round that modelled the index purge and the vault note (2026-11-12)

Both machines had been on the "found by reading" list. Each fix was taken out again after it was written, and a
test failed each time. Details, step mappings and bounds: `tla/IndexPurge-VaultNote.md`.

| # | What went wrong, as a user would meet it | Found by | Replayed on real code | Now |
| --- | --- | --- | --- | --- |
| I1 | A file attached to a meeting that was still being read when Done was pressed stayed searchable after the meeting was purged, until the app was next launched. | TLC, 10 states | Yes: `IndexPurgeTests.testWordsAppliedAtAnyMomentOfAPurgeDoNotSurviveIt` (a real indexer thread; fails with the old order) | Fixed: fences, listing and deletion are one transaction |
| I2 | A question asked from a meeting's page while it was being purged: the conversation was deleted with the meeting, what had been indexed for it was not. | TLC, 10 states | Yes: `RetentionRaceTests.testAConversationStartedWhileTheIndexIsBeingPurgedGoesWithTheMeeting` | Fixed: the index is purged again until no conversation is new to it |
| I3 | With another program reading the index (the MCP server), a purge reported success while the deleted text was still in the index's files. | TLC, 8 states | Yes: `IndexPurgeTests.testAPurgeThatCannotClearTheFilesSaysSoAndClearsThemOnceItCan` | Fixed: the purge fails and is run again |
| V1 | Text saved in Obsidian in the instant WorkScribe was updating the same note was replaced by WorkScribe's version, which had never seen it. | TLC, 5 states | Yes: `VaultStoreTests.testASaveBetweenTheCompareAndTheReplacementIsNotLost` | Fixed: the files are exchanged and what came out is checked |
| V2 | The same, when a meeting was purged: the rewrite that takes WorkScribe's markers out of the note compared nothing. Also: a note that was not valid text stopped its meeting from ever being purged. | TLC, 4 states; the second by reading | Yes: `…testTakingTheMarkersOutBeforeAPurgeKeepsASaveThatLandsMeanwhile` | Fixed |
| V3 | **In the first design of the fix for V1**, before it was written: two more saves during the put-back, and the newest was deleted. | TLC, 12 states, on the model of the fix | Yes: `…testASaveWhileWorkScribesTextStandsInTheNotesPlaceIsTheOneThatStays` | The design was corrected before any code |
| P1 | In Obsidian: a line typed while Finalize was under way disappeared when the AI lines appeared (replaced by the copy on disk). | TLC, 7 states | Yes, in `note-sync.test.ts` | Fixed: the answer's insertions are merged into what the editor holds |
| P3 | Pressing Cmd+Return twice sent two finalize requests. | TLC, 3 states | Yes | Fixed: a second press joins the one in flight |
| P5 | Notes that are not meeting notes were sent to the app: on rename, when another program changed them, and by the two-second poll. A renamed note was sent again at every typing pause, with an error each time. | TLC, 2 to 4 states | Yes | Fixed: such notes are never queued, sent or polled |
| P6 | A sync that failed was not tried again until the next keystroke; and a note the app finalized while it was dirty left a timer rewriting the plugin's data file every 650 ms for the rest of the session. | TLC, 6 to 14 states | Yes | Fixed: retry with back-off; a finalized note is no longer dirty |
| P4 | The plugin kept sending a purged meeting's note: a sync in flight, and, the common case, a purge that happened while Obsidian was closed was never learned, so every typing pause showed an error. The app refused every such request, so nothing was recreated. | TLC, 8 to 11 states | Yes | Fixed: the poll and a 404 recognise a purged meeting |
| P2 | A jot, opening the live view or a resume replaced the plugin's copy of a note being typed in with the file's text, up to two seconds behind the editor; in one ordering the app then dropped a line it already had. | TLC, 19 states | Yes | Fixed: with an editor open, its text is the note |

Still open after these rounds:
- T5 (e) above. A decision, not an oversight: closing it means deleting someone's Ask conversations the moment
  they move a recording to the Trash.
- A transcript file that is damaged before its meeting was ever finalized is never purged (the store does not list
  it, so nothing finalizes it).
- Without a search index or a vault nothing is purged. By necessity: the purge needs both.
- A Done the user asked for that is turned away (the meeting changed under it, or search was unavailable) is not
  remembered; the meeting still fades at its deadline.
- In a recorder resume, notes that became due while AI lines were paused wait until the start's own awaits are
  over (seconds). It closes by itself.
- One corner of the deadline: the triple-fault meeting of T5 (b″) is purged on its first session's clock, after
  its last session has been written to the note.

#### Codex text session

One request is one ephemeral Codex thread and one turn, over `codex app-server`'s stdin and stdout. The reducer
takes events (a caller asks, cancels or times out; a line arrives; the process exits) and returns effects.

| Property | In plain words | Checked |
| --- | --- | --- |
| `ExactlyOnce` | A caller is resumed exactly once, whatever the order of cancel, timeout, process exit and replies. | TLC: 3,453,444 states (2 callers, 2 process starts). Random test on the real reducer. |
| `NoTextFromToolTurn` | Text is never handed over from a turn that showed a tool item or an approval request. | TLC, same run. Random test. `CodexAppServerTests` with a scripted server that uses a tool. |
| `PromptOnlyWhenVerified` | The prompt (`turn/start`) is only written to a connection that passed the isolation check. | TLC, same run. Random test. |
| `UnsafeIsQuiet` | After a tool is seen: nothing in flight, nothing more written, process dead. | TLC, same run. Random test; scripted server test confirms no second prompt is sent and no new process is started. |
| `NoOrphanWhenDown`, `NoStaleRoute` | With the process gone nobody is left waiting; a finished request has no route a late message could use. | TLC, same run. |
| `EveryRequestEnds` | Every request ends (text, error or the caller's cancel) even if the server stalls forever or dies at any point. | TLC with fairness only on the client: 1,308 states (1 caller, 2 starts) and 1,345,591 states (2 callers, 1 start). |

Mutations that must fail, and do: keep a route after abandoning a request; act on a thread reply without checking
the request is still wanted; ignore tool items; tell nobody when the process exits; no timeout; treat a failed
isolation check as passed. The same three kinds of breakage applied to the Swift file make the random test fail
(checked by hand while writing it: tool items ignored, callers kept waiting when unsafe, tool servers accepted).

One thing the model taught: starting threads before the isolation check has answered would **not** leak a prompt.
The pipe is first-in-first-out, so the reply to `thread/start` always arrives after the check's reply, and the
prompt is only sent on that reply. The guard on dispatch is a second line, not the first.

Not covered by the model: the account (signed in or out), starting the process ahead of a request, letting an
idle one go. These are covered by scripted tests only. The model's isolation check is one message; in the code it
is "no MCP servers listed", plus per thread "read-only sandbox, no network, approvals never, no instruction files".

Assumptions about Codex itself, each observed on codex-cli 0.162.1 on 11 Nov 2026 and not otherwise guaranteed:
- A thread in WorkScribe's own Codex home has no MCP servers and no instruction files. (In `~/.codex` the same
  request produced 11 MCP servers, `~/.codex/AGENTS.md`, and a thread that ran a shell command when asked.)
- With the launch flags in `CodexInstall`, forcing the remaining `exec` definition returns "code-mode host is
  disabled" and `request_user_input` returns "unavailable", and neither emits an item. A model told to create a
  file did not (the file did not exist afterwards).
- Codex refuses to start on an unknown feature name, so a later version that renames one fails loudly here.
- Codex writes `auth.json` in place (the symlink from WorkScribe's home to `~/.codex/auth.json` and the target's
  inode survive a credentials write). Checked for the write a login does; assumed for a token refresh.
- An ephemeral thread's prompt is not written anywhere under the Codex home (`--verify-codex` scans it).

#### Screen watch

Capture is driven by events: the window in front changes, the person types and then pauses, or nothing has
happened for a while. A read is always of one app's focused window (accessibility text, or a picture of that
window when the text is thin), never of the display.

| Property | In plain words | Checked |
| --- | --- | --- |
| `NothingFromDeniedApps` | Nothing from an app on the deny list is ever kept. | TLC: 11,245,617 states (3 apps, 3 moves, 3 controls, 1 lost read); an earlier version of the model passed at 109,592,023 states with 4 moves. Random test. |
| `NothingFromPrivateWindows` | Nothing read from a private browser window is kept, including when the reader gets there before the title-change notification. | TLC, same run. Random test. Scripted test. |
| `NothingReadWhileShut` | Nothing that was read while capture was paused, locked or stopped is kept, even if it returns after resuming. | TLC, same run. Random test. Scripted test for pause, lock and stop. |
| `OneLiveRead`, `ShutMeansNotWaiting` | At most one read that could still be kept is outstanding; a shut gate waits for nothing. | TLC, same run. |
| `EventuallyRead` | Once the person settles in a permitted window with capture on, that window is read and kept, even if one earlier read never came back. | TLC: 217,845 states. |

Mutations that must fail, and do: the reader takes the whole screen instead of the one window; a reading is judged
by the last notified title instead of its own; pause, lock and stop do not make earlier reads stale; a second read
while one is out; no read timeout.

Not covered: time. The settle delay, the gap between reads and the idle interval only postpone a read, so the
model lets a read happen whenever the gate allows. "Typing without a pause is still read within `maximumWait`" is
a scripted test on the reducer, not a model result. "Private" is a title heuristic (`ScreenPrivacy.isPrivateWindow`):
a private window whose browser shows nothing in its title is, to the model and to the code, an ordinary window.

**All day.** The same reducer runs whether the screen is read for the length of a recording or all day; reading
all day changed who starts and stops it, not what it decides, so the model above is unchanged. What is new sits
after the reducer and is checked by tests on the real code, not by a model:

| Rule | In plain words | Checked |
| --- | --- | --- |
| One home per reading (`ScreenRoute`) | What is read while a meeting records goes to that meeting and nowhere else; everything else goes to the day. A slow read that comes back after the meeting ended does not land in the day. | `ScreenDayTests`: scripted, and 2,000 random orders of begin, end and late readings (fails with the rule removed). |
| No trace of what may not be read | An app on the never-read list, a private window, and anything in front while paused leave nothing in the day: no text, no window title, no app name, no time. | `ScreenWatcherTests`: the real `ScreenWatcher`, queue and journal, with a stand-in for reading a window (fails when the app-in-front note ignores the reducer's verdict). |
| The day's journal | Written as it goes (a crash costs seconds), rolls over at midnight, survives a relaunch, and a cleared day or a forgotten app cannot be written back from memory. | `ScreenDayTests`. |
| Out of the index when deleted | A day whose journal is gone leaves search at the next sync; the meeting indexer never removes a day. | `ScreenDayTests`. |
| Text does not wait for the picture's vector (`LateResults`) | A look waits at most a second for the vector of the window's picture. A vector that comes later goes, once, to the next look at the same window; one about another window, an old one, or one that arrives after reading stopped goes to nobody. | `LateResultsTests`: gated work, with each of those rules broken in turn (every break fails a test). The reader that uses it is not under test: see below. |
| The day as rows (`DayTimeline`) | The popover's day view: a quick look elsewhere neither gets a row nor splits the app around it; what was in front during a meeting is the meeting's row; no time is lost or counted twice. | `DayTimelineTests`: scripted, and 300 random days. |

**On a real screen (2026-11-12).** The app was run on a real Mac for the first time with all-day reading on, and
its own journal was read back (application names and counts only, not the text). It read: seven stretches from a
game in the first two minutes, six from a picture of the window and one from accessibility text, each with a
vector; time by application, with categories. Two defects showed, neither of which any model or test had a way to
see, because both are about what the Mac does rather than what the reducer decides:

| Seen | Cause | Fix | Checked |
| --- | --- | --- | --- |
| The first window after launch (a browser, in front for 14 seconds) left nothing in the day. | The reader waited for the picture's vector before handing over the text, and the vision model was still loading. The reducer gives up on a look after `readTimeout` (8 s) and drops a reading that returns after the person has moved on, so until the model was warm every look was thrown away. | The text is handed over at once; the vector is waited for at most a second and otherwise follows (`LateResults`). | The mechanism by `LateResultsTests`. That the reader now keeps text during a cold start: by running the app again and reading its journal, not by a test. |
| macOS's alert process was listed as an application. | A system dialog came to the front and was treated like any app. | The Mac's own dialogs and overlays are neither read nor listed (`ScreenPrivacy.systemUIBundleIDs`): to the watcher nothing is in front. | The list by a unit test; the behaviour not replayed. |

**Still not run:** `--verify-screen` itself (day, then a meeting, then the day again, on a real screen), a real
recording with screen reading on, the lock screen, and a whole day. What an accessibility walk returns for a
given app is known for one game and nothing else.

### Found by reading, not formally checked

Ordered by what a defect would cost. "Fixed" means changed on this branch.

| Machine | Where | States (as found) | Worst hazard | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| Plaud Note Pro handoff | `experiments/plaud-macos/Sources/PlaudHandoffController.swift:12-252` | `phase` string: idle, signIn, signingIn, scanning, choose, connecting, saving, ready, releasing, releaseRetry, released, error | Release erases the device. The only erase call is dominated by `validate`, but nothing rechecks between the cloud unbind and the erase; "verified" compares files just written with themselves (the device's CRC is discarded); if the SDK pages the file list both inventories could agree on a partial list. | read; SDK behaviour hyp | Open. Optional build only (`WORKSCRIBE_PLAUD=1`). |
| Plugin: take over / hand back an AI line | `obsidian-plugin/src/ui/note-editor.ts` `handBack`, `takeOver` | per line: AI or Yours (`Block.owned`) | "Let AI rewrite" deleted a range remembered from before its request; an edit in between, or a second click, removed other text from the note. | read | **Fixed**: the range is found again by id after the request and removed only while it is still exactly the owned text (`ownedRange`, `test/handback.test.ts`); one hand-back per line at a time. |
| Plugin: finalize | `note-editor.ts` | Recording, Stopped, Ready, Finalizing, Finalized, Purged (derived from six fields) | Text typed between the finalize request and its response is replaced by the disk copy; a double ⌘↩ runs two finalizes. | read, then model | **Modelled and fixed** (P1, P3 above). |
| Vault note compare-and-swap | `Sources/WorkScribeCore/Vault/VaultStore.swift` | per note: none, open, committed, reopened, purged | The hash is checked, then the file renamed: an Obsidian save in between is overwritten. The purge-time rewrite has no compare at all. | read, then model | **Modelled and fixed** (V1, V2 above). The conflict copy is still written whole. |
| Vault frontmatter merge | `Vault/VaultWriter.swift:255-312` | per region: unedited, converged, edited, deleted | Updating one owned key re-serialises all frontmatter through a flat parser: YAML comments are dropped, nested maps become one string. | read | Open. |
| Index purge fence | `Search/SearchIndexVectors.swift`, `Sources/WorkScribe/IndexService.swift` | per source: unfenced, fenced with rows, fenced and clean | `purgeMeeting` lists what to purge before it sets the fences; an attachment indexed in between survives. The WAL checkpoint's result is ignored, so a blocked checkpoint looks like success. | read, then model | **Modelled and fixed** (I1, I3 above; the model also found I2). |
| Source revision and model space | `Engine/Index.swift:27-218` | chunk: absent, words only, vectorised | A new source is stamped with the current model before any vector exists, so interrupted embedding is never resumed. | read | Open. |
| Vector accelerator journal | `Search/VectorStore.swift:130-392` | cursor ≤ high, reset, recover | A crash inside compaction leaves a temp file nothing removes, which can hold vectors of meetings purged later. | read | Open. |
| Image embedder load and idle release | `Sources/WorkScribe/EmbeddingGemmaVision.swift`, `CoreMLEmbedder.swift` | unloaded, loading, loaded, loaded with idle timer | `release()` could run while `embed` was suspended in a prediction; on resume it force-unwrapped a nil model. A crash during a recording loses the speech in memory. | read | **Fixed**: `embed` holds the models in locals for the length of the call. |
| IndexService live and backlog coalescers | `Sources/WorkScribe/IndexService.swift:6-203` | live: idle, running, running with pending | A change arriving while `finishLive` awaits is stranded; the vault checkpoint can advance past paths whose pass threw. | read | Open. |
| Zoom caption stream | `Sources/WorkScribeCore/CaptionStream.swift:11-192` | per block: words, committed count, pending since | An utterance whose first word matches an earlier one by the same speaker that left the screen within 120 s is merged into it and partly or wholly never emitted. | run (standalone copy) | Open. |
| Echo filter | `Sources/WorkScribeCore/EchoFilter.swift:10-156` | segments, echo segments | Not order-independent: the same segments give a different result arriving one at a time than all at once. | run (standalone copy) | Open. |
| Voice identity | `Sources/WorkScribe/SpeakerNaming.swift`, `Voices.swift` | profile samples, per-meeting assignments, generation counters | Forget rewrites `voices.json`, then aborts at the first purged meeting, leaving older meetings pointing at the forgotten person. | read | Open. |
| Note Pro import queue | `Sources/WorkScribe/PlaudImport.swift:12-123` | queue, task, counters, all in memory | The queue is never persisted: quitting after Release with items pending leaves audio that never becomes a meeting. | read | Open (documented in the old README). |
| Quick ask | `Sources/WorkScribe/QuickAsk.swift`, `AskService.swift:144-164` | panel, conversation, `working`, `tasks[id]` | A second question cancels the first, whose cleanup then removed the second's bookkeeping, and the cut-off answer stayed "working". | read | **Fixed**: bookkeeping belongs to the newest answer (`AskTaskTests`, which fails on the old code). `close()` still does not cancel. |
| HTTP connection and event stream | `Sources/WorkScribe/LocalAPIServer.swift`, `LocalAPI.swift:294-476` | reading, dispatched, streaming, closed | No backpressure on the event stream; a client that stops reading grows the queue without bound. A dropped connection does not stop the handler, so non-idempotent POSTs can be applied without the client knowing. | read | Open. |
| Clip channel | `Sources/WorkScribeCore/Clip/ClipChannel.swift:66-165` | stopped, listening; per connection: accepted, checked, framed, replied | Probe-then-unlink of the socket file is a race between two instances; a slow main actor makes the browser retry and save the clip twice. | read | Open. |
| Vault watcher | `Vault/VaultWatcher.swift:10-196` | stopped, FSEvents, snapshot polling | The debounce has no maximum wait; per-file failures are swallowed and the checkpoint still advances. | read | Open. |
| Runtime doctor | `scripts/runtime-doctor.py:140-244` | per file: missing, evicted, wrong hash, present | Both directory swaps are two renames; a crash between them leaves no runtime until the next run. | read | Open. |
| Speech runtime readiness | `Sources/WorkScribe/Runtime.swift:6-135` | unloaded, loaded, warmed; app: warming, ready, failed, stalled | `warmUp` reports success on an unloaded engine if `stop()` lands between its two hops (quit path only). | read | Open. |
| Plugin: document sync lane | `note-editor.ts` | per note: clean, debouncing, in flight, dirty offline, finalized | Renaming or externally modifying an ordinary note queues it as if it were a meeting note. | read, then model | **Modelled and fixed** (P5, P6, P4, P2 above). Still open, seen while modelling: an editor opened on a meeting's note before the plugin had a session for it stays bound to an ordinary session, so its edits are not synced; and after Obsidian restarts, an unsynced note is not sent until it is opened or edited. |
| Plugin: connection | `obsidian-plugin/src/lib/connection.ts:21-91` | state, attempt, timer | No liveness timer: a hung app stays "online". | read | Open. |
| Plugin: ask streaming | `obsidian-plugin/src/ui/chat.ts:144-186` | busy, conversation, per-message streaming | After reset or purge mid-stream the aborted reply is appended again. | read | Open. |
| MCP session | `Sources/WorkScribeCore/MCP.swift:5-238` | uninitialised, initialised | None that break "no tool call before initialize". `semantic_search` writes to the shared index despite the read-only label. | read | Open (note only). |
| Embedding admission | `Search/IndexAdmission.swift:5-87` | waiting queue, occupied, pressure | None inside the actor. The spec says backlog embedding stops at 2 s of lag; the code gates only at 6 s. | read | Open (spec divergence). |
| Watch watermark | `Engine/Find.swift:21-104` | `seenThrough`, supporting ids | Assumes vectors land in sequence order; a lower chunk vectorised later is never seen as fresh. | hyp | Open. |
| Popover modes, replay clock, C speech bridge | `RecorderView.swift`, `Replay.swift`, `Sources/CNemo` | derived | Minor or none found. | read | n/a |

Hazards removed by deleting their machine on this branch: the resident llama model and its prefix cache
(`ResidentTextModel`, `ws_session_close` use-after-free on a second caller), the image-caption helper process, and
the screen recorder's frame stream, scene detector and lazy per-scene OCR.

## What is not claimed

- The fixes were written after the models. The recording, retention and scheduler fixes were then modelled as
  they were written (not as sketched in a model's `Fix…` switch) and the models run again, three times, until a
  round found nothing new; the Lean definitions were brought in line with `Line.swift` the same way. What each
  round found is in `tla/README.md` and `lean/README.md`. Read those before relying on a row that says "Fixed":
  "by construction" means the model of the fix holds and no test reproduces the original failure.
- The working tree is uncommitted, so no commit id names the code the "current" results are about.
- None of this shows the app is correct. Each check shows that a stated property holds for a stated artefact
  within a stated bound.
- The models were written by the same author as the Codex and screen code they describe, from one understanding.
  A misreading would appear in both and agree with itself. The properties above are written in plain words so that
  someone else can decide whether they are the right ones.
- The "found by reading" table is a list of leads with evidence levels, not a list of verified defects. Rows
  marked **read** were confirmed against the cited lines by the reader who found them; rows marked **hyp** were not.
