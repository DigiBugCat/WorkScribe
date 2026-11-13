// Replays of the counterexamples of formal/tla/PluginNote.tla on the real NoteEditor (src/ui/note-editor.ts),
// driven without Obsidian by test/support/note-editor-harness.ts. Each test names the configuration whose
// trace it follows; formal/tla/PluginNote.md has the traces in words.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Harness, MEETING, openMeetingNote, settle } from './support/note-editor-harness';

const AI = '*AI: what was said about it.*';

test('harness: a typed line reaches the app after the 650 ms debounce', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    editor.type('- budget\n');
    assert.equal(h.app.document!.source.includes('budget'), false);
    await h.tick(650);
    assert.equal(h.app.document!.source, editor.text);
    assert.deepEqual(h.errors, []);
  } finally { h.dispose(); }
});

// ---------------------------------------------------------------- P1: nothing typed is lost

// PluginNote_found_typing_during_finalize__violates_P1_NothingTypedIsLost (7 states):
// Press, Type, the app commits, the answer arrives, the file is read, the editor is made equal to the file.
test('P1: a line typed while Finalize is under way is still in the note afterwards', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    const answer = h.app.holdAnswer('finalize');
    h.pressFinalize(editor);
    await settle();
    assert.deepEqual(h.sent(/finalize/), ['POST /v1/meetings/meeting-1/finalize'], 'the request is out');
    editor.type('- one more thing\n');                 // the person keeps typing
    answer(); await settle();
    assert.ok(editor.text.includes('- one more thing'), 'the typed line was replaced by the copy on disk:\n' + editor.text);
    assert.ok(editor.text.includes(AI), 'the finalize insertions are in the note');
    assert.equal(editor.text.split(AI).length, 2, 'once');
    await h.tick(5000);
    assert.ok(h.disk(h.app.path).includes('- one more thing'), 'and in the file');
  } finally { h.dispose(); }
});

// The same with Obsidian having loaded the app's write into the editor first (Reload), and a line typed after.
test('P1: a line typed after Obsidian reloaded the finalized file, before the answer, is kept', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    const answer = h.app.holdAnswer('finalize');
    h.pressFinalize(editor);
    await settle();
    h.reload(editor);                                   // the app's atomic write reaches the editor first
    assert.ok(editor.text.includes(AI));
    editor.type('- typed after the reload\n');
    answer(); await settle();
    assert.ok(editor.text.includes('- typed after the reload'), 'the typed line was replaced by the copy on disk:\n' + editor.text);
    assert.equal(editor.text.split(AI).length, 2, 'the insertions are in the note exactly once:\n' + editor.text);
  } finally { h.dispose(); }
});

test('P1: with nothing typed, Finalize puts the app\'s insertions into the editor, and Undo takes them out', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    const before = editor.text;
    h.pressFinalize(editor);
    await settle();
    assert.equal(editor.text, h.app.finalizedText(before));
    assert.equal(h.notes.isFinalized(), true);
    assert.deepEqual(h.errors, []);
    const { undo } = await import('@codemirror/commands');
    assert.ok(undo({ state: editor.state, dispatch: tr => editor.dispatch(tr) }));
    assert.equal(editor.text, before, 'one undo restores the note as it was');
    assert.equal(h.notes.isFinalized(), false);
  } finally { h.dispose(); }
});

// ---------------------------------------------------------------- P3: one finalize per press

// PluginNote_found_double_press__violates_P3_OneFinalizePerPress (3 states): Press, Press.
test('P3: Cmd+Return twice sends one finalize request and shows no error', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    const pass = h.app.holdAnswer('finalize:pass');
    h.pressFinalize(editor);
    h.pressFinalize(editor);
    await settle();
    pass(); await settle();
    assert.equal(h.sent(/finalize/).length, 1, 'finalize requests: ' + h.sent(/finalize/).length);
    assert.deepEqual(h.errors, []);
    assert.equal(h.app.finalizeRuns, 1);
    assert.equal(editor.text.split(AI).length, 2);
  } finally { h.dispose(); }
});

test('P3: a second press after the first finished its final pass does not run a second finalize', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    const answer = h.app.holdAnswer('finalize');       // committed; the answer is still on its way
    h.pressFinalize(editor);
    await settle();
    h.pressFinalize(editor);
    await settle();
    answer(); await settle();
    assert.equal(h.app.finalizeRuns, 1, 'the app ran ' + h.app.finalizeRuns + ' finalizes');
  } finally { h.dispose(); }
});

test('P3: a finalize that failed can be pressed again', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    h.app.failNext('finalize', 409, 'Final notes could not finish; the streaming transcript is saved');
    h.pressFinalize(editor);
    await settle();
    assert.equal(h.errors.length, 1);
    assert.equal(h.notes.isFinalized(), false);
    h.pressFinalize(editor);
    await settle();
    assert.equal(h.sent(/finalize/).length, 2);
    assert.equal(h.notes.isFinalized(), true);
    assert.ok(editor.text.includes(AI));
  } finally { h.dispose(); }
});

// ---------------------------------------------------------------- P5: an ordinary note is never sent

async function ordinaryNote(): Promise<{ h: Harness; editor: ReturnType<Harness['edit']>; file: ReturnType<Harness['addFile']> }> {
  const h = new Harness();
  const file = h.addFile('Journal/Today.md', '# Today\n\n- went for a walk\n');
  const editor = h.edit(file);
  await settle();
  return { h, editor, file };
}

// PluginNote_found_ordinary_rename__violates_P5_OrdinaryNeverSent (4 states): Rename, TimerFires, SaveDone.
test('P5: renaming an ordinary note sends nothing to the app and saves no copy of it', async () => {
  const { h, editor, file } = await ordinaryNote();
  try {
    h.rename(file, 'Journal/Yesterday.md');
    await h.tick(650); await h.tick(650);
    assert.deepEqual(h.app.calls, [], 'sent: ' + h.app.calls.join(', '));
    assert.deepEqual(Object.keys(h.ledgers), [], 'the note was copied into the plugin\'s saved data');
    editor.type('- and typed after the rename\n');
    await h.tick(650); await h.tick(650);
    assert.deepEqual(h.app.calls, [], 'sent after typing: ' + h.app.calls.join(', '));
    assert.deepEqual(h.errors, []);
  } finally { h.dispose(); }
});

// PluginNote_found_ordinary_modified_outside__violates_P5_OrdinaryNeverSent (3 states): ExternalModify, TimerFires.
test('P5: an ordinary note changed by another program while closed is not sent', async () => {
  const { h, editor, file } = await ordinaryNote();
  try {
    editor.close(); h.leaves.length = 0;               // the tab is closed; the plugin still remembers the note
    h.write(file.path, '# Today\n\n- went for a walk\n- synced from the phone\n');
    await settle();
    await h.tick(650); await h.tick(650);
    assert.deepEqual(h.app.calls, [], 'sent: ' + h.app.calls.join(', '));
    assert.deepEqual(h.errors, []);
  } finally { h.dispose(); }
});

// PluginNote_found_ordinary_poll__violates_P5b_OrdinaryNeverAsked (2 states): PollSend.
test('P5: the two-second poll does not ask the app about ordinary notes', async () => {
  const { h } = await ordinaryNote();
  try {
    await h.poll();
    assert.deepEqual(h.app.calls, [], 'asked: ' + h.app.calls.join(', '));
  } finally { h.dispose(); }
});

// ---------------------------------------------------------------- P6: a dirty note is eventually saved

// PluginNote_found_sync_error__violates_P6a_NothingStranded (6 states): Type, TimerFires, SaveDone, PatchFails,
// SyncResponse: dirty, online, and nothing scheduled.
test('P6: a sync that failed while the app stays reachable is tried again without another keystroke', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    h.app.failNext('sync', 503, 'Vault is starting');
    editor.type('- budget\n');
    await h.tick(650);
    assert.notEqual(h.app.document!.source, editor.text, 'the first attempt failed');
    for (let i = 0; i < 40; i++) await h.tick(1000);
    assert.equal(h.app.document!.source, editor.text, 'still unsaved 40 s later, with nothing typed');
  } finally { h.dispose(); }
});

// The 409 branch says "adopt the revision, and retry"; PluginNote_found_sync_error covers it as one more error.
test('P6: after a 409 the plugin adopts the app\'s revision and saves, without another keystroke or an error', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    h.app.document!.revision += 1;                      // an answer was lost: the app is one revision ahead
    editor.type('- budget\n');
    await h.tick(650);
    for (let i = 0; i < 40; i++) await h.tick(1000);
    assert.equal(h.app.document!.source, editor.text, 'still unsaved 40 s later, with nothing typed');
    assert.deepEqual(h.errors, [], 'a conflict the plugin resolves by itself is not an error to show');
  } finally { h.dispose(); }
});

// Not in the model (it has no notices): the retries must not turn one outage into a notice every few seconds,
// and an error must not go unreported because the run of failures began with a 409.
test('P6: a sync that keeps failing is retried quietly: its error is shown once', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    h.app.document!.revision += 1;                      // the first attempt meets a 409: adopted, no notice
    editor.type('- budget\n');
    await h.tick(650);
    assert.deepEqual(h.errors, []);
    for (let i = 0; i < 3; i++) h.app.failNext('sync', 503, 'Vault is starting');   // then the app is not ready
    for (let i = 0; i < 60; i++) await h.tick(1000);
    assert.equal(h.sent(/PATCH/).length >= 5, true, 'attempts: ' + h.sent(/PATCH/).length);
    assert.equal(h.app.document!.source, editor.text, 'saved in the end');
    assert.equal(h.errors.length, 1, 'errors shown: ' + h.errors.join(' | '));
    assert.match(h.errors[0]!, /503/);
  } finally { h.dispose(); }
});

// PluginNote_found_finalized_elsewhere__violates_P6_EventuallySavedAndQuiet (14 states): the poll's GET is out,
// Type, the app has finalized, PollResponse marks the session finalized and leaves it dirty: the timer never stops.
test('P6: a note the app finalized while it was dirty does not leave the save timer running for ever', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    const arrive = h.app.hold('meeting');
    const poll = h.poll();                              // GET /v1/meetings/:id is out
    await settle();
    editor.type('- budget\n');                          // dirty, timer armed
    h.app.commit();                                     // the app finalizes on its own (the 23-hour mark)
    arrive(); await poll;
    await h.tick(700); await h.tick(300);
    const saves = h.saves, calls = h.app.calls.length;
    for (let i = 0; i < 20; i++) await h.tick(650);
    assert.equal(h.saves, saves, `the plugin's data was saved ${h.saves - saves} more times in 13 s with nothing happening`);
    assert.equal(h.app.calls.length, calls);
    assert.ok(editor.text.includes('- budget'));
  } finally { h.dispose(); }
});

// ---------------------------------------------------------------- P4: after Purged

// PluginNote_found_purge_during_flush__violates_P4_QuietAfterPurge (8 states): Type, TimerFires (the flush is
// saving), EvPurged, SaveDone: the PATCH goes out for a meeting the plugin knows is purged.
test('P4: a sync that was under way when the meeting was purged sends nothing afterwards', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    editor.type('- budget\n');
    const saved = h.holdSaves();
    await h.tick(650);                                  // the flush is in `await v.save()`
    h.app.commit(); h.app.purge(); h.purgedEvent();
    const from = h.app.calls.length;
    saved(); await settle();
    for (let i = 0; i < 5; i++) await h.tick(1000);
    assert.deepEqual(h.sent(/document|finalize/, from), [], 'sent after the purge: ' + h.sent(undefined, from).join(', '));
    assert.deepEqual(h.errors, []);
    assert.ok(editor.text.includes('- budget'), 'the note keeps what was typed');
  } finally { h.dispose(); }
});

// PluginNote_found_purge_during_flush__violates_P4b_NoLedgerAfterPurge (10 states): the PATCH is answered after
// the purge was handled; the flush writes its old session's document back into the saved ledger.
test('P4: the saved ledger of a purged meeting is not written again by a sync that was in flight', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    editor.type('- budget\n');
    const answer = h.app.holdAnswer('sync');
    await h.tick(650);                                  // PATCH applied by the app, its answer on the way
    h.app.commit(); h.app.purge(); h.purgedEvent();
    assert.equal(h.ledgers[MEETING], undefined, 'the purge removed the ledger');
    answer(); await settle();
    for (let i = 0; i < 5; i++) await h.tick(1000);
    assert.equal(h.ledgers[MEETING], undefined, 'the ledger of the purged meeting is back in the plugin\'s data');
  } finally { h.dispose(); }
});

// PluginNote_found_purge_missed__violates_P4c_PurgeIsLearned: the purge happens while the events connection is
// down, so `meeting.purged` never arrives; the poll then asks about the meeting every two seconds.
test('P4: a purge that happened while disconnected is noticed, and the note is then left alone', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    await h.connection(false);
    h.app.commit(); h.app.purge();                      // 24 hours pass; no event reaches the plugin
    await h.connection(true);
    await h.poll();
    const from = h.app.calls.length;
    editor.type('- a line added to the kept note\n');
    for (let i = 0; i < 5; i++) await h.tick(1000);
    assert.deepEqual(h.sent(/document|finalize/, from), [], 'sent after the purge: ' + h.sent(undefined, from).join(', '));
    assert.deepEqual(h.errors, []);
    assert.equal(h.ledgers[MEETING], undefined);
    assert.ok(editor.text.includes('- a line added to the kept note'));
  } finally { h.dispose(); }
});

// The same, when the first thing the plugin does after the missed purge is a sync (the app answers 404).
test('P4: a 404 on sync for a purged meeting ends the syncing instead of repeating it', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    await h.connection(false);
    h.app.commit(); h.app.purge();
    await h.connection(true);
    editor.type('- a line added to the kept note\n');
    for (let i = 0; i < 5; i++) await h.tick(1000);
    const from = h.app.calls.length;
    editor.type('- and another\n');
    for (let i = 0; i < 60; i++) await h.tick(1000);
    assert.deepEqual(h.sent(/document|finalize/, from), [], 'still syncing a purged meeting: ' + h.sent(undefined, from).join(', '));
    assert.deepEqual(h.errors, [], 'errors shown: ' + h.errors.join(' | '));
  } finally { h.dispose(); }
});

// ---------------------------------------------------------------- P2 / P6: open() on a note being typed in

// PluginNote_found_reopen__violates_P6a_NothingStranded (10 states): Type, open() replaces the session with the
// file's text (older than the editor), that text is synced, and the note is "clean" with the app behind.
test('P6: opening the note again while typing does not sync the older text of the file', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    editor.type('- budget\n');                          // in the editor; Obsidian has not saved it yet
    await h.notes.open(MEETING, false);                 // "Open live meeting view", a resume, a jot
    for (let i = 0; i < 5; i++) await h.tick(1000);
    assert.equal(h.app.document!.source, editor.text, 'the app holds:\n' + h.app.document!.source);
    assert.deepEqual(h.errors, []);
  } finally { h.dispose(); }
});

// PluginNote_found_reopen__violates_P2_NoRollback: a flush is saving when open() reads the file. The old flush's
// PATCH lands; the reopened session's older text is refused once (409, revision adopted) and accepted the next time.
test('P2: a reopen during a save never makes the app drop a line it already had', async () => {
  const { h, editor } = await openMeetingNote();
  try {
    editor.type('- budget\n');
    const saved = h.holdSaves();
    await h.tick(650);                                  // flush 1: `before` holds "- budget", its save is in progress
    editor.type('- hiring\n');
    await h.tick(650);                                  // flush 2 waits behind it
    await h.notes.open(MEETING, false);                 // reads the file: neither line is in it yet
    await h.tick(650);                                  // flush 3 waits too
    saved(); await settle();                            // flush 1's PATCH: the app has "- budget"
    let rolledBack = false;
    for (let i = 0; i < 10; i++) { await h.tick(650); rolledBack ||= !h.app.document!.source.includes('- budget'); }
    assert.equal(h.app.patches.some(p => p.source.includes('- budget')), true, 'the app was given "- budget"');
    assert.equal(rolledBack, false, 'the app was then sent an older note and dropped "- budget"');
    assert.equal(h.app.document!.source, editor.text);
  } finally { h.dispose(); }
});
