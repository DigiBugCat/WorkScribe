# Machine 6 — the Obsidian plugin's note sync and finalize (`PluginNote.tla`)

One note open in Obsidian, the plugin's sync lane and finalize for it, and the WorkScribe app as the
other party over the local HTTP API. Written on 12 November 2026.

The spec describes two versions of the plugin, chosen by constants:

* **found** — `obsidian-plugin/src/ui/note-editor.ts` as it was in the working tree before this work
  (git `HEAD` `edcaebae` plus the uncommitted hand-back fix). All `Fix*` constants `FALSE`.
* **fixed** — the working tree now: `note-editor.ts`, the new `src/lib/finalize-merge.ts`, and small
  changes in `src/main.ts` and `src/lib/editor-extension.ts`. All `Fix*` constants `TRUE`.

Nothing is committed, so no commit id names either version.

**What was checked is the model, not the TypeScript.** A "holds" is a statement about the model inside
the stated bound. A violation is a hypothesis about the plugin until it is replayed on the real class;
here every one was, and the section on each finding names the test. The replays drive the real
`NoteEditor` with a real CodeMirror state, but Obsidian and the app are stand-ins (see "How the replays
run"), so they show what the plugin's own code does, not what Obsidian does around it.

## Result in one table

| | Property, in plain words | Found | Fixed |
|---|---|---|---|
| P1 | Every character the person typed is still in the editor, or in the document the app holds | **violated** (7 states) | holds |
| P1e | Stronger: it is still in the editor | **violated** (same trace) | holds |
| P2 | The app never replaces its document with one that lacks text it already had | holds without `open()`; **violated** when `open()` runs during a save (19 states) | holds |
| P3 | A finalize request is never sent while another is waiting for its answer | **violated** (3 states) | holds |
| P3b | When no finalize is in flight, nothing stops the next press | true by absence of any guard | holds |
| P4 | After the plugin has handled a purge it sends no document request for that meeting | **violated** (8 states) | holds |
| P4b | … and keeps no saved ledger of it | **violated** (10 states) | holds |
| P4c | A purge is eventually learned: the plugin ends up with no live session for the meeting | **violated** (11 states) | holds |
| P5 | An ordinary note's text is never sent to the app | **violated** (3 and 4 states) | holds |
| P5b | The app is never asked about an ordinary note | **violated** (2 states) | holds |
| P5c | An ordinary note is never copied into the plugin's saved data | **violated** (2 states) | holds |
| P6a | Nothing is left unsaved with nothing scheduled | **violated** (6 and 10 states) | holds |
| P6 | With the app reachable the note is eventually saved, stays saved, and the save timer stops | **violated** (14 states) | holds |

Every property was seen to fail at least once: all but P3b on the found code, P3b under a mutation.
Each fix was also switched off alone on the fixed code, and the property it is there for failed again
(`fixed_without_…` configurations), so none of the passes is empty.

Two rounds of modelling the fixes found nothing new: the configurations kept here, and six wider ones
that were run once and not kept (3 keystrokes with 2 reopens; 2 presses with 2 failures and a drop;
liveness with a reopen and two presses; liveness with purge and reopen; the app finalizing with two
presses; a closed note with liveness), between 217,147 and 2,232,870 states each, all without error.

## Code covered

Current line numbers (the fixed files).

`obsidian-plugin/src/ui/note-editor.ts`: the constructor's subscribers 64 (Cmd+Return), 75 (connection),
77-79 (vault `modify`), 82-87 (rename), 88-90 (the poll); `session` 103-115; the Finalize button 298;
`open` 303-308, `openInner` 309-339; `changed` 340-348; `queue` 349-361; `arm` 363-366; `syncFailed`
369-372; `flush` 373-433; `diskChanged` 439-450; `purgedMeanwhile` 453-459; `checkFinalized` 460-480;
`markFinalized` 496-503; `finalize` 507-515; `finalizeOnce` 516-576; `append` 636-644; `purge` 645-652.
`obsidian-plugin/src/lib/finalize-merge.ts` (all of it). `obsidian-plugin/src/main.ts`: the connection
callback 56-60, `handleEvent` 278-282, `meetingPurged` 313-326. `obsidian-plugin/src/lib/editor-extension.ts`
150-155 (the view plugin that calls `changed`).

The app, read only: `Sources/WorkScribe/LocalAPI.swift` 130-136 (POST document), 137-159 (PATCH
document), 160-167 (POST finalize), 168-173 (done); `Sources/WorkScribe/MeetingRetention.swift` 31-65
(`finalize`), 66-114 (`done`), 121-138 (`recover`); `Sources/WorkScribeCore/Vault/VaultStore.swift`
243-274 (`openDocument`), 284-306 (`finalizeDocument`); `Sources/WorkScribeCore/NoteDocument.swift`
118-168; `docs/api/local-api.md` "Native meeting documents".

`handBack` / `takeOver` are not in the model. They do not touch `dirty`, the lane or `finalize`; they
change the editor's text like typing does, which reaches the lane through `changed`.

## How the code is cut into steps

JavaScript runs one function at a time and gives way only at an `await` that really waits: a file
write, an HTTP answer. A continuation of something already resolved runs before any other event. So in
the spec "the flush body ends → `flush`'s tail → `finalize` continues → the next queued flush body
starts" is one step, and every wait for Obsidian or the app is a step boundary where a keystroke, an
event, a timer or another command can come first.

| Action in the spec | TypeScript, fixed | found |
|---|---|---|
| `Type` | a keystroke; `editor-extension.ts` 150-155 → `changed` 340-348 → `queue` 349-361 | 146-151; 320-328; 329-340 |
| `Autosave`, `Reload` | Obsidian saving the editor, and loading a file that changed under a clean editor (→ `changed`) | the same |
| `Press` | 64 or 298 → `finalize` 507-515 → `finalizeOnce` 517 → `flush` | 53 or 285 → `finalize` 433-435 |
| `TimerFires` | the timer of `arm` 365 → `flush` 373-376 and the body 377-391 up to `await v.save()` | 332; 341-353 |
| `SaveDone` | 390 returns; 392 (`gone()`, online); the PATCH is sent at 399 | 352; 354; 361 |
| `SyncResponse` | 399 returns: 400-404, or the catch 405-420 | 361: 362-364, or 365-373 |
| `StoreDone` | `await saveSettings()` 404 returns; the tail 422-432 | 364; 377 |
| `Open409Response` | `await openDocument` 411 returns: 412-414, 419 | 368: 369-372 |
| `GoneResponse` | `await purgedMeanwhile` 418 (453-459) returns | not in the found code |
| `FinalizeResponse(c)` | `await finalizeDocument` 524 returns; `finalizing.delete` | 442 |
| `FinalizeRead(c)` | `await adapter.read` 526 returns; 527-534 (beside the note), 535-564 (the editor), 565 | 444; 445-450; 451-469; 470 |
| `FinalizeSave(c)` | `await leaf.view.save()` 566 returns; 567 | 471; 472 |
| `EvFinalized` | `main.ts` 278 → `markFinalized` 496-503 | 278 → 424-431 |
| `EvPurged` | `main.ts` 279-282 → `meetingPurged` 313-326 → `purge` 645-652 | 279-292 → 539-543 |
| `ConnDrop`, `ConnUp` | `main.ts` 56-60 → the subscriber at 75 | 64 |
| `PollSend`, `PollResponse` | 88-90 → `checkFinalized` 460-480 | 77-79 → 396-406 |
| `ReopenSend`, `ReopenResponse`, `ReopenApply` | `open` 303 → `openInner`: 310 answered; 323-324 the text; 326, 330-331 | 290 → 297; 308; 310-311 |
| `Rename` | the handler 82-87 (`queue` guarded at 351) | 71-76 |
| `ExternalModify` | vault `modify` 77-79 → `diskChanged` 439-450 | 66-68 → 384-395 |
| `AppPatch`, `AppLatePatch` | `LocalAPI.swift` 137-159 | |
| `AppFinalizeStart(c)` | `LocalAPI.swift` 160-164, entering `NoteEnhancementScheduler.finish` | |
| `AppFinalizeCommit(c)` | `finish` returns; 165-166; `MeetingRetention.finalize` 31-63; `VaultStore.finalizeDocument` 284-306 | |
| `AppFinalizeIndexed(c)` | `await index.indexFinalNote` (`MeetingRetention.swift` 64) returns; the answer at `LocalAPI.swift` 167 | |
| `AppFinalizeSelf` | `MeetingRetention.recover` 131-137, or the first half of `done` 76-81 (`allowRebase`) | |
| `AppPurge` | `MeetingRetention.done` 91-113 | |
| `PatchFails` | the plugin's `syncDocument` rejects although the request may still reach the app | |

## Abstractions

* **Text is a set of tokens.** Each keystroke adds one new token; the person never deletes. "Lost" is
  then exact: a typed token that is in neither the editor nor the app's document. A separate bit says
  whether a copy of the text holds the finalize insertions. Block identities, offsets, ownership,
  images and undo history are not modelled.
* **The merge is modelled as exact.** `finalize-merge.ts` decides whether the editor already shows the
  finalized text by which of the two known texts needs the smaller single change. In the model that
  decision is simply right. The function has its own tests (`test/finalize-merge.test.ts`), one of
  which sweeps 4,000 single edits and checks that no character of the editor's text is ever dropped.
* **One note, one session, one lane.** A second editor pane on the same note, two meetings at once and
  two Obsidian windows are not modelled. After a purge the open editor gets a session keyed by its
  path; the model then follows only what is left of the meeting's own lane, and does not rename or
  modify the note again (`MaxExternal = 0` in purge scenarios). What happens to an ordinary note is
  checked in its own scenarios (`Meeting = FALSE`), which is the same code.
* **The meeting has ended.** Recording, Stop and Resume are not steps. What a resume does to this
  machine is call `open()`, which is the `Reopen` actions; Stop's `flush()` is one more caller of the
  lane. The plugin's belief about `recording` being out of date is not modelled.
* **The app answers in one step where the plugin cannot tell the difference**: POST document, GET
  meeting. PATCH and POST finalize are split into "the app acts" and "the plugin gets the answer",
  because things happen in between.
* **Obsidian.** `view.save()` writes the editor's text to the file. A file changed underneath a clean
  editor is loaded into it. A file changed underneath an editor with unsaved text is not merged: the
  next save overwrites it. This last one is an assumption; I did not check what Obsidian does there.
* **The app's own finalize** (`AppFinalizeSelf`) inserts into whatever the file holds (`allowRebase`),
  in one step. Undo of a finalize, and the PATCH that reopens a finalized document, are not modelled.
* **Failures** are counted, not timed: a request "fails" when the plugin gets an error for it. A PATCH
  that failed before the app saw it may still arrive later (`late`). There is no clock, so the back-off
  of the retry and the two-minute and thirty-second valves on the finalize guard and the poll are not
  in the model.
* Not modelled: IME composition (347 found, 382 fixed), `dispose`, a restart of Obsidian (sessions are
  rebuilt from the saved ledgers, `dirty` is not), `retitle`, `imageChanged` (it calls `queue` like
  the rename handler), `grabMoment`.

## Bound

One note. At most 2 keystrokes, 2 presses of Finalize, 2 failed requests of which one may arrive late,
1 drop of the events connection, 1 `open()` on a live session, 2 renames or outside modifications.
Each configuration states its own bound in its second line; none uses all of these at once. The
largest kept configuration explores 5,421,635 states.

## Results

Run on 12 November 2026 with TLA+ tools 1.8.0. "trace" is the number of states in the counterexample.

| Configuration | Result | States | Depth / trace |
|---|---|---|---|
| `found_typing_during_finalize__violates_P1_NothingTypedIsLost` | violated | 183 | 7 |
| `found_double_press__violates_P3_OneFinalizePerPress` | violated | 8 | 3 |
| `found_sync_error__violates_P6a_NothingStranded` | violated | 10 | 6 |
| `found_reopen__violates_P6a_NothingStranded` | violated | 96 | 10 |
| `found_reopen__violates_P2_NoRollback` | violated | 1,041 | 19 |
| `found_finalized_elsewhere__violates_P6_EventuallySavedAndQuiet` | violated | 2,187 | 14 |
| `found_purge_during_flush__violates_P4_QuietAfterPurge` | violated | 150 | 8 |
| `found_purge_during_flush__violates_P4b_NoLedgerAfterPurge` | violated | 327 | 10 |
| `found_purge_missed__violates_P4c_PurgeIsLearned` | violated | 638 | 11 |
| `found_ordinary_rename__violates_P5_OrdinaryNeverSent` | violated | 15 | 4 |
| `found_ordinary_rename__violates_P5c_OrdinaryNotInLedger` | violated | 3 | 2 |
| `found_ordinary_modified_outside__violates_P5_OrdinaryNeverSent` | violated | 4 | 3 |
| `found_ordinary_poll__violates_P5b_OrdinaryNeverAsked` | violated | 2 | 2 |
| `found_sync__holds` (P1, P1e, P2, P4, P4b, P5, P5b; no finalize, purge or reopen) | holds | 937 | 25 |
| `found_mutation_no_cas__violates_P2_NoRollback` | violated | 107 | 11 |
| `fixed_sync__holds` | holds | 67,394 | 44 |
| `fixed_finalize__holds` | holds | 80,292 | 38 |
| `fixed_finalize_reopen__holds` | holds | 264,596 | 42 |
| `fixed_purge__holds` | holds | 5,421,635 | 44 |
| `fixed_purge_typing__holds` | holds | 166,813 | 38 |
| `fixed_ordinary__holds` | holds | 52 | 7 |
| `fixed_ordinary_closed__holds` | holds | 5 | 3 |
| `fixed_closed_meeting__holds` | holds | 614,451 | 34 |
| `fixed_sync_liveness__holds` (P6) | holds | 20,100 | 34 |
| `fixed_finalize_liveness__holds` (P6, P4c) | holds | 371,153 | 37 |
| `fixed_without_keep_typed__violates_P1_NothingTypedIsLost` | violated | 183 | 7 |
| `fixed_without_one_finalize__violates_P3_OneFinalizePerPress` | violated | 8 | 3 |
| `fixed_without_retry__violates_P6a_NothingStranded` | violated | 10 | 6 |
| `fixed_without_reopen_editor__violates_P6a_NothingStranded` | violated | 95 | 10 |
| `fixed_without_drop_dirty__violates_P6_EventuallySavedAndQuiet` | violated | 2,187 | 10 |
| `fixed_without_fence__violates_P4_QuietAfterPurge` | violated | 150 | 8 |
| `fixed_without_fence__violates_P4b_NoLedgerAfterPurge` | violated | 343 | 10 |
| `fixed_without_learn_purge__violates_P4c_PurgeIsLearned` | violated | 396 | 9 |
| `fixed_without_meeting_only__violates_P5_OrdinaryNeverSent` | violated | 15 | 4 |
| `fixed_without_meeting_only__violates_P5b_OrdinaryNeverAsked` | violated | 2 | 2 |
| `fixed_mutation_no_cas__violates_P2_NoRollback` | violated | 196 | 11 |
| `fixed_mutation_guard_never_cleared__violates_P3b_FailedFinalizeCanBeRetried` | violated | 3 | 3 |

The `fixed_…__holds` safety configurations check all of TypeOK, P1, P1e, P2, P3, P3b, P4, P4b, P5,
P5b, P5c and P6a together. For a violation the state count is how far the search went before it found
the trace, not the size of the model.

## Findings

Each was found on the found code, replayed on the real `NoteEditor` in
`obsidian-plugin/test/note-sync.test.ts` (the test failed before the fix and passes after it), fixed,
and the fix modelled as written. Confidence is about whether a person can get there, not about the
mechanism, which the replay shows.

### 1. P1 — a line typed while Finalize is under way is replaced by the copy on disk

`traces/PluginNote_found_typing_during_finalize__violates_P1_NothingTypedIsLost.txt` (7 states).

1. Cmd+Return. The note is in step, so the request goes out at once (found 435-442).
2. The person types a line. It is in the editor only.
3. The app finalizes the text it has, writes the file, answers.
4. The plugin reads the file (444) and makes the editor equal to it (451-465): either the insertions
   happen to reproduce the file, or it replaces the differing stretch with the file's. The typed line
   is not in the file, so it goes. It is in the app's document neither.

What a person sees: the line they just typed disappears when the italic AI lines appear. It is in
Undo, as part of the finalize itself, so undoing it also undoes the finalize. The same happens when
Obsidian has already loaded the finalized file into the editor and the person types after that.

Confidence: **high**. The window is the whole finalize request: the final pass plus indexing the note,
seconds on a real meeting.

Tests: `P1: a line typed while Finalize is under way is still in the note afterwards`,
`P1: a line typed after Obsidian reloaded the finalized file, before the answer, is kept`.

Fix (`finalizeOnce` 535-564, `src/lib/finalize-merge.ts`): the answer carries the text the app
finalized and its insertions. They are placed into what the editor holds now: before the typing they
stay where they were, after it they move with the text, and a place the typing replaced takes its
insertion right after what was typed. If the editor already shows the insertions they are taken out
without history and put back as the one undoable change, so Undo still restores the pencil note. The
file's copy is no longer written into an editor that holds something else.

One path is kept from the found code: an app that changed the file and listed no insertions (the mock
server in `dev/` does this). Then, and only when the editor holds exactly the text that was finalized
or exactly the file's, the file's text is taken as before. If something was typed as well, the editor
is left as it is: the typed text stays, and the insertions of such an app do not reach the note.

### 2. P3 — two presses run two finalizes

`traces/PluginNote_found_double_press__violates_P3_OneFinalizePerPress.txt` (3 states): Press, Press.
The key handler (found 53) has no in-flight guard. The button disables itself (285) but every
`refresh` draws a new, enabled one (found 274-285).

What a person sees, by the Swift code as read (`LocalAPI.swift` 164): if the second request arrives
while the first is in its final pass, the app answers 409 and the plugin shows "Final notes could not
finish; the streaming transcript is saved" although the finalize is working. If it arrives later, the
app runs a second final pass and finalize; the plugin applies the second answer over the first, which
in the found code deletes anything typed in between (finding 1 again). I did not check the 409 against
the running app; the replay uses a stand-in that follows that line.

Confidence: **high** for the two requests (replayed), **medium** for which of the two outcomes.

Tests: `P3: Cmd+Return twice sends one finalize request and shows no error`, `P3: a second press after
the first finished its final pass does not run a second finalize`, `P3: a finalize that failed can be
pressed again` (this one passed before too; it guards the fix).

Fix (`finalize` 507-515): one run per meeting; a second press joins it and reports nothing itself.
The guard is cleared when the run ends, whichever way. It stops holding after two minutes without an
answer, so a request that never returns cannot disable Finalize for the session (not modelled: no
clock).

### 3. P5 — ordinary notes are sent to the app

The editor extension gives every Markdown editor a session (found 100-101), keyed by the note's path.
Three places then treated those like a meeting's:

* **Rename** (found 71-76): the handler queues every session whose path matches. 650 ms later the
  note's full text is PATCHed to `/v1/meetings/<its old path>/document`, and `queue` has already
  copied it into the plugin's `data.json` ledger. After the rename the session's id is no longer its
  path, so the guard in `changed` (found 324) stops working too: every pause in typing sends the note
  again. `traces/PluginNote_found_ordinary_rename__violates_P5_OrdinaryNeverSent.txt` (4 states),
  `…__violates_P5c_OrdinaryNotInLedger.txt` (2 states).
* **A change from outside while the note is closed** (found 384-395): a sync tool or another program
  writes the file; `diskChanged` queues it. `…_ordinary_modified_outside__…` (3 states). `imageChanged`
  (found 379-383) does the same when a picture the note embeds changes.
* **The poll** (found 396-406): every two seconds, for every note opened since Obsidian started, GET
  `/v1/meetings/<path>`. `…_ordinary_poll__violates_P5b_OrdinaryNeverAsked.txt` (2 states). The
  requests are made one after another and the next round starts regardless, so they pile up.

What a person sees: after renaming any note, "WorkScribe: PATCH … failed (404)" each time they stop
typing in it (the app refuses, so nothing is stored there); and a steady stream of requests to the
app that grows with every note opened.

Confidence: **high**.

Tests: `P5: renaming an ordinary note sends nothing to the app and saves no copy of it`, `P5: an
ordinary note changed by another program while closed is not sent`, `P5: the two-second poll does not
ask the app about ordinary notes`.

Fix: such a session is marked `ordinary` (114, `editor-extension.ts` 9-13). `queue` (351), `flush`
(381) and `checkFinalized` (465) leave it alone, and `changed` (344) tests the mark instead of
comparing id and path. The poll runs one round at a time (461-463). Ledgers that the old code saved
under a path are dropped when the plugin loads (52-57).

### 4. P6 — a sync that fails is not tried again

`traces/PluginNote_found_sync_error__violates_P6a_NothingStranded.txt` (6 states): Type, the timer,
the save, the PATCH fails, and the note is dirty with the app reachable and nothing scheduled. `flush`
re-queues only after a body that returned (found 377); one that threw skips that line. The comment at
the 409 branch says "adopt the revision, and retry"; the revision is adopted and nothing retries.

What a person sees: an error notice, and their last line is not in the app until they type again.
If they do not (it was the last line), Stop and Finalize each call `flush` and usually repair it; a
409 at that moment makes Finalize fail with the 409 instead.

Confidence: **high**. Any 5xx, a 503 "Vault is starting", or an answer that never arrives while the
events connection stays up.

Tests: `P6: a sync that failed while the app stays reachable is tried again without another
keystroke`, `P6: after a 409 the plugin adopts the app's revision and saves, without another keystroke
or an error`.

Fix (`flush` 422-431, `arm`, `syncFailed`): a failed flush with the note still dirty and the app
reachable arms the timer again: after 650 ms, doubling up to 30 s. The error is shown once per run of
failures, and a 409 that the next attempt resolves is not shown at all (the notices are not in the
model; `P6: a sync that keeps failing is retried quietly: its error is shown once` tests them).

### 5. P6 — a save timer that never stops

`traces/PluginNote_found_finalized_elsewhere__violates_P6_EventuallySavedAndQuiet.txt` (14 states).
The poll's GET is out; the person types (dirty, timer armed); the app has finalized the meeting on its
own; the answer marks the session finalized and leaves it dirty (found 401-403). From then on: the
timer fires, `flush` returns at once because the note is finalized (found 346), its tail sees "dirty
and online" and queues again (377). Every 650 ms, for the rest of the session, each round writing the
ledger and `data.json`.

The same loop is reached two more ways, read from the code and covered by the same fix, not replayed
separately: a finalize whose result landed beside the note (found 445-450 returns before `dirty` is
cleared at 472), and Undo then Redo of a finalize within 650 ms.

What a person sees: nothing, except a plugin that rewrites its data file every 650 ms.

Confidence: **medium**. It needs a keystroke in the few milliseconds a poll request is out while the
app has just finalized; or the other two ways.

Test: `P6: a note the app finalized while it was dirty does not leave the save timer running for
ever` (19 saves in 13 s before the fix, none after).

Fix: a note that is gone, finalized or ordinary is no longer dirty (`flush` 381); the poll (472) and
the beside-the-note branch of finalize (530) clear `dirty` and the timer themselves. The tail also
does nothing after `dispose` (432; not modelled).

### 6. P4 — the plugin keeps talking about a purged meeting

Three separate ways.

* **A sync that was under way** (`…_purge_during_flush__violates_P4_QuietAfterPurge.txt`, 8 states):
  `flush` is waiting for Obsidian's save when `meeting.purged` is handled; it then sends its PATCH
  anyway (found 354-361). The app refuses (404), so nothing is recreated; the person gets an error
  notice right after "Done now".
* **The ledger comes back** (`…__violates_P4b_NoLedgerAfterPurge.txt`, 10 states): the PATCH was
  answered before the purge and the answer is handled after it. `flush` writes its old session's
  document into `documentLedgers` and saves it (found 364). The ledger holds the note's text and its
  line identities, and at the next start it becomes a session for a meeting that no longer exists.
  This order needs the answer to be handled later than an event that was produced after it, which is
  unlikely on one machine. Confidence: **low** that it happens, high that the code allows it.
* **A purge nobody told the plugin about** (`…_purge_missed__violates_P4c_PurgeIsLearned.txt`, 11
  states): the purge happens while the events connection is down, or while Obsidian is closed, which
  is the usual case for the 24-hour deadline. Nothing ever removes the session: the poll asks GET
  meeting every two seconds and looks only at `document.finalized`, which a purged meeting does not
  have (found 399-403). Typing in the kept note sends its text to the app at every pause and shows
  the app's 404 each time. Confidence: **high**.

Tests: `P4: a sync that was under way when the meeting was purged sends nothing afterwards`, `P4: the
saved ledger of a purged meeting is not written again by a sync that was in flight`, `P4: a purge that
happened while disconnected is noticed, and the note is then left alone`, `P4: a 404 on sync for a
purged meeting ends the syncing instead of repeating it`.

Fix: after every wait `flush` checks that its session is still the registered one (`gone()`, 386, used
at 392, 400, 406, 412) and stops if not. `open()` stops if the meeting was purged while it waited
(326). `purge` clears the timer (649). The poll, and a 404 on sync, ask what became of the meeting and
handle `retention: purged` (or `purging`) exactly as the event (`purgedMeanwhile` 453-459, 468;
`main.ts` `meetingPurged` 313-326, which is the old event branch made callable).

### 7. P2 and P6 — `open()` on a note that is being typed in

`open()` runs again for a note that already has a session whenever a jot is sent, the live view is
opened or a recording resumes. It replaced the session with the file's text (found 308-310), and the
file is whatever Obsidian last saved, up to two seconds behind the editor.

* `traces/PluginNote_found_reopen__violates_P6a_NothingStranded.txt` (10 states): type, `open()`, the
  older text is synced, the note is "clean" and the app does not have the last line. If nothing more
  is typed, Stop runs the final pass without it, and Finalize finds the file different from the app's
  document and writes a " (WorkScribe).md" copy beside the note.
* `traces/PluginNote_found_reopen__violates_P2_NoRollback.txt` (19 states): a flush is saving when
  `open()` reads the file. The flush's PATCH reaches the app; the reopened session's older text is
  refused once (409, revision adopted) and accepted the next time. The app's document loses a line it
  had, and with it that line's AI line, until the next keystroke sends the editor's text again.

Confidence: **medium**. The P6a form needs `open()` within two seconds of typing and no typing after
it. The P2 form needs three flush calls queued, which the replay gets by typing twice more.

Tests: `P6: opening the note again while typing does not sync the older text of the file`, `P2: a
reopen during a save never makes the app drop a line it already had`.

Fix (`openInner` 320-331): when an editor is open on the note, the session takes the editor's text and
the editor's own ledger of line identities, not the file's. The flush that was running when the
session was replaced stops at its next `gone()` check, so it no longer clears the new session's
`dirty`.

## Showing the passing properties can fail

* P2 holds on the found code without `open()` only because of the app's compare-and-swap:
  `found_mutation_no_cas` and `fixed_mutation_no_cas` let the app accept any revision, and a PATCH the
  plugin gave up on arrives after a newer one and replaces it (11 states).
* P3b cannot fail on the found code, which has no guard. On the fixed code
  `fixed_mutation_guard_never_cleared` leaves the guard set after a failed run (3 states).
* Each `fixed_without_<fix>` configuration switches one fix off and gets back the trace that fix
  closed.

## How the replays run

`obsidian-plugin/test/support/note-editor-harness.ts` constructs the real `NoteEditor` with:

* a real CodeMirror `EditorState` carrying the plugin's own extension, and the extension's own view
  plugin told about each transaction, so `mounted`, `changed` and the key handler are the real ones;
* `test/support/obsidian.ts` in place of the `obsidian` module (the test build aliases it:
  `esbuild.config.mjs`), a vault that is a `Map`, and a DOM that absorbs every call;
* `AppDouble`, which follows the document routes of `LocalAPI.swift` and lets a test hold a request
  or its answer back; and node:test's mock clock for the timers.

So a replay shows that the plugin's code does what the trace says, given the answers the trace
assumes. It does not show what Obsidian does around the plugin (see the assumption about unsaved text
under "Abstractions"), and the stand-in for the app is my reading of the Swift, checked only where
`test/real-api.test.ts` runs the same calls against the real binary (document compare-and-swap,
finalize, purge: that test passes).

## Not covered, and still open

* **Not fixed, seen while reading, not modelled:** `session()` (103-115) returns the first session
  whose path matches. If an editor was already open on a meeting's note before the plugin had a
  session for that meeting (no saved ledger, and the meeting is not the live one), the editor stays
  bound to the ordinary session it was given, and edits to that note are never synced. This was so
  before; the `ordinary` mark does not change it.
* **Not fixed:** after Obsidian restarts with an unsynced ledger, nothing sends it until the note is
  opened or edited (`dirty` is not saved). A restart is not in the model.
* **By design, not a defect:** text typed during a finalize is kept in the note but is not in the
  finalized text the app wrote its AI lines from, and the app no longer accepts it. And if Obsidian
  saves that text to the file before the app compares the file with its document, the app writes the
  finalized version beside the note (`docs/api/local-api.md`: "preserves unsynced edits"). The plugin
  cannot prevent Obsidian's own save.
* **Undo after typing during a finalize** restores the note as it was, with the typed text, but the
  app will not reopen the document (it accepts only the exact text it finalized), so the pencil lines
  do not come back. Not modelled.
* **A 404 that is not a purge** (the app has no document for a meeting the plugin has a ledger for):
  the sync is retried every 30 s and the error shown once. The found code showed it at every pause.
* **Requests the person asks for after a purge** (opening the live view calls `open()`, which the app
  refuses with 409) are not counted by P4.
* **What Obsidian does** when a file changes under an editor with unsaved text.
* The two-minute valve on the finalize guard, the thirty-second valve on the poll, the retry back-off
  and the ledger clean-up at load are in the code and not in the model.

## Re-running

`run.sh` lists only the three specs of `README.md`; until `PluginNote` is added to its `SPECS`, run
these configurations through its single-configuration mode:

```sh
cd formal/tla
S="$(mktemp -d)"
for c in PluginNote_*.cfg; do JOBS=1 bash ./run.sh --one "$S" "$c"; done
ls "$S"/*.failed 2>/dev/null     # nothing: every configuration behaved as its name says
```

A few minutes on a 14-core Apple Silicon Mac; `fixed_purge__holds` and
`fixed_finalize_liveness__holds` take one to two minutes each, everything else seconds. Counterexamples go to
`traces/PluginNote_….txt`.

The replays: `cd obsidian-plugin && npm test` (137 tests; 2 are the opt-in real-API tests and are
skipped without `WORKSCRIBE_API_BINARY`).
