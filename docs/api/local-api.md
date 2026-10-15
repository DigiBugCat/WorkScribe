# WorkScribe local API (v1)

This is the shared contract for the menu-bar app, Obsidian plugin and development mock.
The handlers are in `Sources/WorkScribe/LocalAPI.swift`, the listener in `LocalAPIServer.swift`,
and the wire models in `Sources/WorkScribeCore/API/`. The plugin decodes these in `obsidian-plugin/src/lib/parse.ts`.

## Discovery and transport

The app binds **127.0.0.1 only**, on an ephemeral port. It writes
`~/Library/Application Support/WorkScribe/api.json` with mode **0600**:

```json
{"port":53490,"token":"<64 hex characters>","version":1}
```

`WORKSCRIBE_API_DIR` overrides the discovery directory; `WORKSCRIBE_DISABLE_API=1` disables the listener.
All requests require `Authorization: Bearer <token>` except OPTIONS preflight.
Host must be a loopback name (`127.0.0.1`, `localhost`, `[::1]`, optionally with port).
The only allowed Origin is `app://obsidian.md`; other origins receive 403.
CORS allows `Authorization, Content-Type` and `GET, POST, PATCH, OPTIONS`.
An allowed preflight returns 204 without a token. The plugin uses Obsidian `requestUrl` for JSON
and Node HTTP for SSE, with fetch as fallback.

JSON bodies are limited to 1 MB; attach files by absolute path, not an upload. Errors are
`{"error":"message"}` with HTTP 400 (malformed body), 401 (token), 403 (host/origin), 404
(missing route/meeting/note), 405 (method), 409 (recording state), 413 (size), 422 (invalid input),
or 503 (warming/search unavailable). Optional JSON properties may be omitted; clients accept null too.
Wall-clock dates are ISO 8601 UTC. Numeric times are seconds from meeting start.

## JSON endpoints

| Method and path | Request | Response |
| --- | --- | --- |
| GET `/v1/status` | — | Status |
| POST `/v1/recording/start` | `{title?}` | Status; 409 if busy, 503 if warming |
| POST `/v1/recording/stop` | `{}` | Status; 409 unless recording |
| POST `/v1/meetings/:id/resume` | `{}` | Status; 409 outside ten minutes after Stop, during capture, or after finalizing/deletion |
| GET `/v1/meetings?limit=50` | limit 1–500 | Array of summaries, newest first |
| GET `/v1/meetings/:id` | — | `{meeting: Summary, segments, notes, missedTopics, actionItems, answers, attachments, clips}` |
| POST `/v1/meetings/:id/notes` | `{text, at?, fromAnswer?, fromMissedTopic?}` | Note, HTTP 201 |
| PATCH `/v1/meetings/:id/notes/:noteId` | exactly one of `{text}`, `{enhanced:{topic,text}}`, `{rewrite:true}` | Note |
| POST `/v1/meetings/:id/document` | `{}` | Create/open the native note; NoteDocument |
| PATCH `/v1/meetings/:id/document` | NoteDocument with current revision | NoteDocument with revision incremented |
| POST `/v1/meetings/:id/finalize` | `{}` | Retry finalization after Stop; NoteDocument |
| POST `/v1/search` | `{query, kinds?, limit?}` | Array of Moments; limit 1–100 |
| POST `/v1/attachments` | `{meetingId?, conversationId?, path?, text?}` | `{attachment, owner, path?}`, HTTP 201 |

Status contains `recording`, `phase`, `meetingId?`, `title?`, `startedAt?`, `elapsed`,
`sources:{mic,system,screen}`, `permissions:{screenRecording,microphone}`, `warming`, `message?`,
and `model:{provider,name}`, plus optional `finalizationProgress` (0–1, completed lifecycle stages rather than elapsed time). Phase is ready, starting, recording, finalizing, error or preview.
Provider is openai, local or none. Warming means the speech engine is loading.

Summary contains `id,title,startedAt,duration?,speakers,status,vaultPath?,obsidianLink?`.
Duration is absent while recording. Status is recording, finalizing, complete, interrupted or failed.
`vaultPath` is an **absolute filesystem path**, and `obsidianLink` is the vault writer's canonical
`obsidian://open?...` URL when known. The plugin converts absolute paths inside its vault to relative paths.

Segment contains `id,speaker,speakerKey,source,start,end,text,final`. Speaker is a display name.
The provisional segment's ID survives its final update; if recognition splits a provisional turn into
multiple speaker turns, the first final turn reuses the ID and subsequent turns have their own IDs.
The next provisional turn gets a new ID. Meeting snapshots carry the same IDs as events.

### Notes

```json
{"id":"note-id","at":545,"text":"ship nov 4","enhanced":{"topic":"Ship date.","text":"November 4."},
 "state":"done","blockId":"e1","excerpts":[{"id":"E1","chunkId":"segment-id#0","segmentId":"segment-id",
 "speaker":"Priya","start":541,"end":548,"text":"November fourth.","hollow":false,
 "match":"time+meaning","link":"workscribe://meeting/meeting-id?t=541&segment=segment-id"}]}
```

`enhanced`, `at`, `blockId` and `fromAnswer` are optional. States are pending, enhancing, done or plain.
Plain means no usable enhancement was produced, or the line came from an answer. The original text remains.
Excerpt IDs are E1… per note; `match` is `time+meaning` or `meaning`. `hollow` is the equivalent boolean
for older clients. `blockId` is the vault writer's persisted block ID, without `^`, returned only when known.

POST defaults `at` to now for the live recording, otherwise leaves it absent.
`fromAnswer:{answerId,question,askedBy?}` is preserved and the answer text stays plain.
`fromMissedTopic:{topic}` promotes a matching topic and its evidence to a note, removing it from missedTopics.
Jots, shorthand edits and relevant transcript updates schedule bounded live enhancement. `{text}` marks a normal
note pending again. `{enhanced:{topic,text}}` saves an explicit user edit; later passes, including ones already
in flight, cannot overwrite that enhancement. This protection survives save/reload and subsequent shorthand edits.

Missed topics contain `topic,text,excerpts`. Action items contain `text,quote,noteId,at?,owner?,askedBy?`;
owners and requesters are currently unknown. Saved answers contain `id,conversationId,question,answer,state,
citations,at,createdAt,done:true`; `at` is a meeting offset and `createdAt` is a wall-clock date.
Attachments include their indexing state. Clips are SavedClip objects described below.

### Moments and search

Moment kinds are `meeting,note,clip,pdf,document,audio,video,image,screen`. Search accepts those names
(`meetingSegment` remains an alias for `meeting`). PDF/note filters share document retrieval then filter the
wire results. A Moment contains `kind,title,snippet?,meetingId?,path?,start?,end?,page?,speaker?,thumbnail?,
window?,link,attached,number?`. `number` appears in citations and starts at 1.
`path` and local `thumbnail` are absolute paths. `link` is a `workscribe://` deep link or a canonical
`obsidian://` link when the source is in a vault. Meeting links preserve their time and segment anchors.
While recording, search uses words only and includes the live screen moments.

Attachments require path or text. `meetingId` takes precedence; otherwise the app creates or uses a
conversation. `owner` is `meeting:<id>` or `conversation:<id>`. Files up to 200 MB are copied; larger files
are referenced. Text is stored as Markdown. The response's `attachment.indexState` describes indexing success.

## GET /v1/events

SSE sends a `status` immediately, increasing event IDs, and a `: keep-alive` comment every 15 seconds.
Reconnect clients reload the current meeting; there is no event replay.

| Event | JSON payload |
| --- | --- |
| `status` | Status; changes and elapsed-time updates |
| `transcript` | `{meetingId,segment}`; partial and final updates |
| `notes` | `{meetingId,notes,missedTopics,actionItems}`; full authoritative snapshot after jot, edit or enhancement |
| `answer` | `{id,at,done,conversationId,meetingId?,question,answer,state,citations}`; accumulated text, same ID through streaming and completion |
| `screen` | `{meetingId,id,start,end,text,app?,window?,thumbnail?,link}`; new or extended screen moment |
| `clip` | SavedClip: `{id,path,title,url,site?,meetingID?,offset?,clippedAt}`; path is **vault-relative** |
| `ask_request` | `{clip:SavedClip,question?,untrusted:true}`; offer the page in the composer, never auto-submit it |
| `continue` | `{conversationId,title,meetingId?,markdown}`; open the existing conversation in Ask |

The canonical notes event is batched so notes, actions and missed topics change together. Optional
`documentFinalized:true` retires editor decorations immediately after a native document is committed.
The plugin retains transitional support for `segment`, `note`, `enhancement.note` and `enhancement` events;
the app and mock emit the canonical names above. Unknown events are ignored.

## POST /v1/ask

Body: `{question,meetingId?,conversationId?,attachments?:[{path? ,text?}]}`.
Attachments are stored before retrieval. Pass `conversationId` back to continue the same chat.

The SSE order is `started {conversationId,messageId}` → zero or more `token {text}` →
`citations {conversationId,answer,state,detail?,citations}` → `done {conversationId}`, then close.
A failed answer can terminate with `error {message}`. HTTP errors occur before SSE begins.
The plugin ignores `started`; it receives the conversation ID again at completion.

**The citations event's `answer` is authoritative:** it replaces the concatenated tokens because citation
mapping removes invalid markers and renumbers valid `[n]` markers in first-use order. Its 1-based citation
numbers match the final text. States are answered, momentsOnly, empty or failed. No available model or no
matching evidence may yield zero token events; the final text and/or matching moments still render.

## Verification

```sh
swift test
.build/debug/WorkScribe --verify-api
cd obsidian-plugin
npm test
npm run build
npm run smoke
WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test
```

The last command launches `--serve-api-for-tests`: real listener, auth, handlers, serialization and event hub,
with a throwaway meeting/conversation store and deterministic note/answer providers. It checks in-flight edit
protection, note provenance, missed topics, streaming identity, final citation text, conversation reuse,
attachments and CORS. It does not capture audio, load models, or use the user's library or vault.
`dev/mock-server.mjs` emits the same canonical payloads with scripted meeting content for UI development.

## Ephemeral meetings and live AI lines

Every user line is retained verbatim and in insertion order. Its AI line updates automatically when relevant
transcript arrives, with a four-second debounce and at most one pass every 15 seconds per meeting. Matching
considers both the typing window and meaning. A final pass considers the complete transcript after Stop,
including every AI-owned note and missed topics. Previous enhanced text is supplied to keep rewrites stable.
Model failure preserves the existing/user text rather than blocking saving.

`Note.userEdited` indicates an explicit edit of the AI line. `PATCH {enhanced:{topic,text}}` transfers ownership;
`PATCH {rewrite:true}` returns it to AI. Exactly one of `text`, `enhanced`, or `rewrite:true` is required.
A version check prevents an old in-flight result from overwriting a later ownership change.
There is no accept/dismiss state for AI lines.

Summaries include `retention: live|finalized|purging|purged` and optional `purgeAt` (ISO UTC).
For legacy meetings, after Stop and final enhancement the vault receives title, date, attendees, original and AI lines,
a brief, action items and missed topics. The finalized write-up has no transcript URLs, evidence links or
`^eN` anchors. The brief is a short extract from the enhanced notes (or first transcript turns when no notes exist).
An edited vault region remains protected; a conflicting finalized version is saved alongside it.

`POST /v1/meetings/:id/done` returns the updated Summary and deletes raw meeting material immediately.
It returns 409 during recording/finalization and is idempotent. The same cleanup runs when `purgeAt`
(24 hours after the meeting ended) is reached, on launch and every minute. A persisted `purging` record
replays unfinished deletion after a crash. Errors retain this record and retry on the next sweep.
`meeting.purged {meetingId}` is emitted only when cleanup has completed; clients clear cached transcript,
screen, evidence and answers, and load the vault note. Purged detail contains metadata and a vault path,
with empty raw collections. A minimal metadata receipt remains solely to resolve old meeting IDs and
record deletion completion.

Cleanup removes the whole meeting folder (including audio, screen video, OCR, thumbnails, attachments and
unknown leftover files), transcript/screen/attachment index rows and vectors, and saved meeting Q&A.
Cross-meeting answers citing the deleted source are scrubbed as well. Answer text already inserted into
notes remains there. Shared speaker profiles and other meetings are preserved. Search and scoped Ask use
vault notes after purge. Logical index deletion is followed by vector compaction and SQLite cleanup.

Additional isolated verification: `.build/debug/WorkScribe --verify-purge`.

On upgrade, ended legacy meetings without a retention journal are finalized before they become eligible
for cleanup. Those whose end time is already more than 24 hours ago are purged after that successful
vault write. The app never runs this migration against the user's library in verification modes.


## Native meeting documents

The plugin now opens a normal MarkdownView, with Live Preview or Source mode. `POST document` is
idempotent: it creates one plain note under Meetings (local `date`, optional duration/attendees,
`tags`, and the `workscribe` identity key), ending in an empty bullet. Obsidian supplies the only title.
The reader also accepts legacy `workscribe_id`; renames preserve identity. Jots received before attachment are seeded verbatim.
The configured WorkScribe vault must be this Obsidian vault; the plugin reports a mismatch instead of
writing a second file. Meeting detail includes optional `document`.

```json
{"path":"/absolute/vault/Meetings/2026-10-14 Planning.md","revision":3,
 "source":"# Planning\n\n- ship Friday\n", "finalized":false,
 "blocks":[{"id":"client-generated-uuid","from":12,"to":25,"text":"- ship Friday","at":42.1,"section":"Planning"}]}
```

`source` is the exact current Markdown. Offsets are UTF-16 code units (CodeMirror / NSString), not UTF-8
bytes or Unicode scalar counts. Blocks are ordered, non-overlapping, nonempty and have unique IDs;
`text` must equal `source.slice(from,to)`. A block may include
`owned:{from,to,text}` for adjacent real text the user has taken over (a roman list continuation). Its range is checked
against the same source and cannot overlap the next block. `at` is the first-typed meeting offset;
once the server has seen an ID, later syncs cannot change its timestamp. A new offline block may omit it.
`section` supplies heading context to enhancement, without making the heading itself a note.

PATCH is an authoritative full snapshot: omitted IDs are deleted, order is updated, changed shorthand
is re-enhanced, and ownership changes invalidate in-flight AI results. Retry with the returned revision.
A mismatched revision or finalized document returns 409; malformed ranges return 422. Sync never writes
user Markdown. The path must resolve inside the configured vault, outside `.obsidian`, and identify this
meeting through frontmatter. The normal 1 MB transport bound and a 2,000-block bound apply.
The plugin debounces 650 ms, serializes requests, and persists pending identities locally before network
sync. It saves through Obsidian before Stop. Legacy POST/PATCH `notes` endpoints return 409 once a
meeting owns a document; document sync is then the only note mutation path.

An `owned` continuation makes the note `userEdited`. Removing it via the explicit **Let AI rewrite** editor
action returns ownership. Both operations are ordinary undoable edits. Decorations and AI rewrites are
not file edits and do not enter undo history. Copy gets a fresh UUID; cut/paste and undo may restore the
old ID. On reconnect or reopen, matching reconciles the current file with the saved ledger.

Stop finishes the pencil pass. Finalize inserts italic AI continuations, a brief, Also discussed and
Tasks-format action items into this same file. Existing owned continuations are not duplicated.
No generated block IDs or transcript links are inserted. Subsequent finalization is idempotent, including
a replay after the atomic file rename but before the retention journal commit. The legacy region writer
never rewrites a bound native document. The note's own headings, spelling, spacing, lists, properties,
embeds and other content are left in their original order.

Normal finalization compares the exact saved source and preserves unsynced edits. An explicit commit
writes a ` (WorkScribe).md` sibling; an existing sibling is not overwritten. **Done** and the 24-hour recovery
path cannot retain raw material forever because Obsidian was closed: they read the current file and
insert AI only at unique, unchanged, line-aligned blocks. Ambiguous, edited or deleted anchors receive no
insertion. A user-deleted file is not recreated. The original raw-data purge still runs. Reading view shows
only real file contents; live AI appears in the two editing modes. Purge removes the transient ledger
along with the meeting and clears open editor decorations.

## Ink and Pencil provenance and commitment

Native meeting documents remain in pencil after Stop. The final enhancement pass finishes,
then the user explicitly presses Finalize (⌘↩ in the editor). The app commits unattended
native documents at the 23-hour mark; raw deletion stays at 24 hours. A successful automatic
commit produces one system notification. An unsynced explicit commit preserves the original
file and writes a ` (WorkScribe).md` sibling instead. Deadline recovery retains the existing
conservative anchor rebase policy.

`trace` is optional on notes, live answers and the final Ask `citations` event. Ask additionally
emits `event: trace` as retrieval/generation steps advance. Its JSON body is the trace itself:

```json
{"steps":[{"title":"Selected evidence","status":"complete","detail":"3 moments supplied to the model"}],
 "model":"Qwen 3.5", "location":"On this Mac", "durationMs":420,
 "sources":[{"kind":"document","title":"Scope","text":"Quoted source text","link":"workscribe://file?..."}],
 "revisions":[{"version":2,"text":"The updated line","reason":"New transcript evidence","at":"2026-10-15T03:00:00Z"}]}
```

Steps expose observed actions and results, never private chain-of-thought. Missing provenance
is displayed as missing, not filled with a guessed model. The fallback generator reports the
actual provider through a per-request provenance object. Revisions live in the raw meeting
store, sources in the scoped conversation store; both disappear in the existing purge.
Cross-meeting answers scrub their trace when a cited meeting is purged.

Undo is an ordinary isolated CodeMirror transaction restoring the entire pre-commit document
and its pencil ledger. The subsequent PATCH may reopen a finalized document only before its
purge deadline, with the exact pre-finalize source, matching revision, and matching on-disk
source. This is not a generic write-through endpoint. The deadline and purge journal remain
in force after undo.

Native Markdown writes continuation text inside the bullet in italic, escaping backslashes,
asterisks and underscores. Owned continuation text remains roman. Topic labels are dropped;
a one-paragraph italic brief follows properties, `## Also discussed` precedes action items.
### Images in meeting documents

A block may carry `images: [{target, path?}]`. `target` is the destination from an Obsidian
embed or Markdown image; `path` is the absolute path resolved by Obsidian's metadata cache.
The server derives image classification from the block's actual text, never from supplied
captions or a client `kind`. It reads only raster files inside the selected vault, rejects
symlink escapes, and does not fetch remote images. Remote/unsupported images remain image
blocks with no generated interpretation. Mixed blocks use the user's non-image text as shorthand.
The original Markdown, identity, first-pasted time, ownership, undo, and finalization rules apply.

`APINote.images` optionally returns image evidence: `target`, `path`, `fingerprint`, `text` (OCR),
`caption`, `method`, `seconds`. The client ignores unrecognized fields. Text/captions are
untrusted evidence, never instructions. `method` is `vision-ocr`, `gemma4+vision-ocr`,
`no-readable-text`, or `unavailable`. `seconds` measures analysis, excluding the normal note
scheduler/debounce. This evidence is private to the meeting's retention window; an independent
vault image index remains while the file remains in the vault. The shared Why? trace renders one image
source per entry using target as title, caption/OCR as text, and method plus analysis timing.
Image-only AI lines survive the final pass even without transcript excerpts. These sources clear on purge.

`POST /v1/meetings/:id/grab-moment` (empty JSON) returns `{filename, png, at}` where `png` is a
base64 PNG and `at` is seconds into the recording. Requires that exact live meeting, active
screen awareness, an available captured frame, no pause, and a permitted foreground app.
Returns 409 when unavailable/private. It does not start capture or read an unrelated screenshot.
The plugin's **Grab this moment** command has no default hotkey. It uses Obsidian's
`getAvailablePathForAttachment` and `createBinary`, then inserts a generated embed at a mapped
cursor position as one undoable transaction. The attachment is durable user content, independent
of the screen movie and thumbnails. Undoing insertion does not delete the attachment file.


Finalize responses may include `document.insertions:[{at,text}]`: additions at pre-finalize
UTF-16 offsets, ordered by offset. The editor verifies that applying them produces the saved
source, then commits them as one undoable transaction. Transcript-backed action items are
optional structured `ActionItem` values with owner and due date; finalization excludes tasks
already present after case/whitespace normalization. It never derives a second task list from
the user's own shorthand.

### Resuming a stopped note

`POST /v1/meetings/:id/resume` keeps the meeting ID, original start clock, note document,
transcript segments, screen moments and confirmed speaker assignments. It opens new WAV
tracks and a new screen movie under `recordings/<session UUID>/`, and records the per-source
offsets in `recordingSessions`. New recognizer speaker labels get the session namespace;
they do not inherit a previous session's speaker identity. Existing recordings without a
session manifest are adopted as the initial session, with their files left untouched.

Meeting detail includes `endedAt` for the Resume deadline. Resume clears this timestamp
and the purge deadline while capture runs; the next Stop restarts the 24-hour retention
clock. An in-flight final pass cannot commit across a resumed session. Resume is available
while the final pass runs after audio streams have drained, but not after Finalize.
