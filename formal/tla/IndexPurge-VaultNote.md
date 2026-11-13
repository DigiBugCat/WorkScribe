# Two more models: the index purge and the vault note

Written 2026-11-12 against the working tree on branch `codex-backend`. Both machines were on the list of state
machines "found by reading" in `formal/README.md`, each with a hazard that reading had suggested. The models
confirm those, add others, and one of them found a hole in the first design of its own fix.

Run them with the others: `./run.sh IndexPurge` and `./run.sh VaultNote` (20 configurations, a few seconds).
Configurations are named as in `README.md`, with two code names: `found`, the code before this round, and `fixed`,
the working tree. `fixed_without_<fix>` takes one fix out again; `fixed_mutation_<what>` breaks one rule.

## Machine 4: what the search index holds for a purged meeting (`IndexPurge.tla`)

### Code covered

| | |
| --- | --- |
| `Sources/WorkScribe/MeetingRetention.swift`, `done` | the purge from the point where the journal says "purging" |
| `Sources/WorkScribe/IndexService.swift`, `purgeMeeting` | which roots are purged |
| `Sources/WorkScribeCore/Search/SearchIndexVectors.swift`, `purge(meeting:folder:roots:)`, `purge(refs:)`, `checkpoint` | fences, deletion, clearing the files |
| `Sources/WorkScribeCore/Engine/Index.swift`, `apply` | the fence check, in the transaction that inserts |
| `Sources/WorkScribeCore/Retention.swift`, `RetentionStore.purge` | conversations and the folder removed, journal "purged" |
| `Sources/WorkScribeCore/Ask/AttachmentIndexer.swift`, `index`, `prune` | the indexer, and the launch-time clean-up |
| `Sources/WorkScribe/AskService.swift`, `files(_:)`, `ensureConversation` | what the person can still do while a purge runs |

### How the code is cut into steps

The index has one SQLite connection behind a lock (`Database.lock`), taken per statement or per transaction. The
purge runs on the `IndexService` actor; an indexer's `apply` runs off it (`FolderIndexer.index` is a non-isolated
`async` function), so an `apply` transaction can fall between any two statements of the purge that are not in one
transaction. `MeetingRetention.done` is on the main actor and gives way at each `await`
(`NoteImageUnderstanding.clear`, `index.purgeMeeting`); a conversation can be started at either.

| Model action | Code |
| --- | --- |
| `Attach`, `Converse` | `AskService.attach` / `ask(scopeMeetingID:)`: neither is refused while `done` runs, because the meeting in memory only says "purged" at the end |
| `Read`, `Apply`, `Embed` | the extractor reading the file; `SearchIndex.apply` (one transaction: fence check, then insert); `writeVectors` |
| `Begin` | the receipt journalled "purging" with the conversations scoped to the meeting at that moment |
| `ListThenFence_List`, `ListThenFence_Fence`, `DeleteListed` | as found: `IndexService.purgeMeeting` (two queries, then `setMeta` per fence), then `purge(refs:)` |
| `FenceListDelete` | as fixed: `SearchIndex.purge(meeting:folder:roots:)`, one transaction |
| `Checkpoint` | `wal_checkpoint(TRUNCATE)`, `VACUUM`, checkpoint again |
| `Recheck` | as fixed: the loop in `done` that purges the index again for conversations it had not been told about |
| `RemoveFiles` | `RetentionStore.purge(index: nil)`: conversations and the folder deleted, journal "purged" |
| `Retry`, `Crash` | the retention loop replaying a journalled purge a minute later, or after a relaunch |
| `Launch` | `AttachmentIndexer.prune` at launch: attachment sources whose file is gone are dropped |

### Abstractions

- One meeting. Its transcript is one source; each attachment and each conversation's attachment is one source.
- A source either has rows or does not. Which rows, and vectors, are not modelled (`writeVectors` refuses a fenced
  source in its own SQL and adds no rows).
- `residue` is one bit: "deleted text may still be in the index's files". It is set by any delete and cleared
  only by a completed checkpoint and vacuum. Whether a given byte is really still there is SQLite's business; the
  test checks it on real files.
- Another connection "holds the log" for as long as the environment likes, at most `MaxBlocks` times.
- Other meetings, folder indexing and vault indexing are not in the model: they have other roots.

### Bound

`fixed__holds`: 2 attachments, 2 conversations, the log held twice, one crash, a relaunch: 505,869 states,
depth 29. The liveness run: 1 attachment, 1 conversation, two holds, one crash: 5,619 states.

### Results

| Property | In plain words | `found` | `fixed` |
| --- | --- | --- | --- |
| `Gone` | Once the journal says "purged", the index holds nothing of the meeting: not its transcript, its attachments, or the attachments of conversations deleted with it. Checked in every later state, so nothing comes back either. | violated twice (below) | holds; fails without `FenceFirst`, without `RootsRechecked`, and with either mutation |
| `NothingLeftOnDisk` | ... and none of the deleted text is left in the index's files. | violated twice (below) | holds; fails without `CheckpointChecked` |
| `HealedByLaunch` | Whatever survived a purge is dropped at the next launch. | holds | holds |
| `PurgeEnds` | The purge finishes, however often it has to be run again. | not run | holds |

### Findings

**I1. An attachment still being read when Done is pressed stays searchable after the purge.**
`found_attachment_read_during_purge__violates_Gone`, 10 states: attach, the extractor reads the file, the purge
lists what to delete, the indexer's `apply` commits, the purge sets its fences and deletes what it had listed.
The attachment's row was neither listed nor refused. It stays findable until the next launch, when `prune` drops
it because its file is gone. *Replayed*: `IndexPurgeTests.testWordsAppliedAtAnyMomentOfAPurgeDoNotSurviveIt` runs
a real indexer thread against real purges and fails within its 25 rounds when the old order is put back;
`testListingBeforeFencingLetsWordsAppliedInBetweenSurviveThePurge` shows the mechanism step by step.
*Fixed*: fences, listing and deletion are one transaction.

**I2. A conversation started while the index is being purged keeps its rows.**
`found_conversation_started_during_purge__violates_Gone`, 10 states. The index was told which conversations to
purge when the receipt was journalled; one started during a later `await` has its files deleted by
`RetentionStore.purge` and its rows left. *Replayed*:
`RetentionRaceTests.testAConversationStartedWhileTheIndexIsBeingPurgedGoesWithTheMeeting`, which fails with the
single pass put back. *Fixed*: the index is purged again until a pass finds no conversation it had not been told
about, and nothing suspends between that last look and the deletion of the files. The journal is updated with
each new conversation, so a purge cut short still deletes it.

**I3. A purge that could not clear the files reported success.**
`found_log_held_by_another_connection__violates_NothingLeftOnDisk`, 8 states. SQLite answers a checkpoint that
another connection blocked with "busy" in its first column, not with an error, and the code did not read the
answer. The MCP server reads the same index from its own process. *Replayed*:
`IndexPurgeTests.testAPurgeThatCannotClearTheFilesSaysSoAndClearsThemOnceItCan` holds a read open from a second
connection: the old code returns normally with the text still in the files. *Fixed*: the purge fails, the journal
stays at "purging", and the retention loop runs it again.

**I4. The launch-time clean-up is an ordinary delete.** `found_survivor_pruned_at_launch__violates_NothingLeftOnDisk`.
With I1 and I2 fixed nothing of a purged meeting is left for it to clean up, so this no longer concerns raw
meeting data. It is still how the attachments of a conversation deleted by hand leave the index. Not changed.

**Not a defect, but worth knowing.** While a purge runs, attaching a file to the meeting is still accepted (the
copy of the meeting in memory says "finalized" until the end). The file is written into the meeting's folder,
refused by the index, and removed with the folder. Refusing it outright would be cleaner; nothing is lost either way.

## Machine 5: one note written by two programs (`VaultNote.tla`)

### Code covered

| | |
| --- | --- |
| `Sources/WorkScribeCore/Vault/VaultStore.swift`, `exchange` (behind `replace`) | the one place a note is replaced |
| the same file, `update`, `finalizeDocument`, `appendToInbox` | its callers: read, merge, replace, and read again when told the note changed |
| the same file, `removeMarkers` | the rewrite before a purge (was inline in `MeetingRetention.done`) |

### How the code is cut into steps

WorkScribe and Obsidian are two processes with nothing in common but the file, so every system call is a step.
What matters is the order of: WorkScribe reading the note, comparing it again, writing the temporary file, the
rename or exchange, and reading what came out; against Obsidian's save, which can fall between any two of those.

| Model action | Code |
| --- | --- |
| `Save` | Obsidian writing the person's text to the note's path |
| `Read` | `Data(contentsOf:)` and the merge that follows (no system calls) |
| `Recheck` | `current() == expected` at the top of `exchange` |
| `Rename`, `StripWrite` | as found: `rename` over the note; `write(atomically:)` with no comparison |
| `Exchange`, `PutBack` | `renamex_np(RENAME_SWAP)`: the note and the temporary file change places in one step |
| `Judge` | reading the temporary file and comparing its hash with what was expected to come out |

### Abstractions

- A note's content is who wrote it and which of the person's saves it carries. WorkScribe's text carries the save
  it was merged from; whether the merge itself keeps the person's text is `VaultWriter.merge`'s business and has
  its own tests.
- A save is one step. Obsidian writes in place, which is several system calls, but the first of them truncates
  the file: a save that has begun before an exchange makes the old file differ from what was read, and so counts
  as having happened. A save that begins after an exchange lands in the note's place, on top of whatever is there.
- One write by WorkScribe at a time (`VaultStore.lock`).
- Not modelled: the note being moved or deleted in the middle of a write (the code then puts what it holds into
  the empty place and reports the note as changed), and volumes that cannot exchange two files (the code compares
  again and renames, as before, with the gap narrowed to those two calls).

### Bound

`fixed__holds`: 4 saves and 4 writes: 1,799 states, depth 25.

### Results

| Property | In plain words | `found` | `fixed` |
| --- | --- | --- | --- |
| `NoLostSave` | Whenever WorkScribe is not in the middle of a write, the note carries the person's latest save: as saved, or inside WorkScribe's text merged from it. | violated twice (below) | holds; fails without either fix and with either mutation |
| `WriteEnds` | A write comes to an end, however the saves fall. | not run | holds |

### Findings

**V1. A save between the comparison and the rename is replaced by a text that never saw it.**
`found_save_between_check_and_rename__violates_NoLostSave`, 5 states. `replace` read the note again, then wrote a
temporary file, then renamed it over the note; the gap is as long as writing the file takes. The comment on
`finalizeDocument` said a racing edit is never overwritten. *Replayed*:
`VaultStoreTests.testASaveBetweenTheCompareAndTheReplacementIsNotLost`, which fails on the old `replace`.
*Fixed*: exchange, look at what came out, put it back if it is not what was read.

**V2. The rewrite before a purge compared nothing.**
`found_save_during_the_rewrite_before_a_purge__violates_NoLostSave`, 4 states. Read, strip WorkScribe's markers,
write. *Replayed*: `VaultStoreTests.testTakingTheMarkersOutBeforeAPurgeKeepsASaveThatLandsMeanwhile`. *Fixed*: it
goes through the same exchange. While there: that code read the note with `String(contentsOf:encoding:)`, which
throws on a file that is not UTF-8, and the throw aborted the purge, every minute, for good. It now leaves such a
note alone and carries on.

**V3. The first design of the fix lost a save itself.** Before any Swift was written, the model of the fix
failed: `fixed__holds` gave a 12-state trace in which the person saves three times, once before the exchange and
twice while the put-back is under way, and the write ends with the second save in the note and the third deleted.
The design compared what a put-back took out against the wrong thing. The rule that holds: each exchange should
take out exactly what the one before it put in; anything else is a save not yet seen, the newest there is, and
goes back in. *Replayed*: `VaultStoreTests.testASaveWhileWorkScribesTextStandsInTheNotesPlaceIsTheOneThatStays`,
which fails when the put-back does not look at what it took out.

### What these models do not establish

- That the Swift matches the models. The step mapping above is by reading. The tests replay the counterexamples
  on the real code and each fix was removed again to see a test fail, which is evidence for those traces only.
- Anything about Obsidian beyond "it writes the person's text to the note's path". If it merged an external
  change into an unsaved buffer incorrectly, that would be outside both.
- The conflict copy (`….conflict.md`) is still written whole, with nothing compared: text typed into the conflict
  copy itself is replaced by the next conflicting update.
