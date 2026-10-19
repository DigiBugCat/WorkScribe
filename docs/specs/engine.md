# WorkScribe engine — rebuild spec

Status: design for Codex to implement in stages. Base: the merged `core` branch (stage 0, in progress at
`/private/tmp/claude-501/ws-core`). Read `docs/research/core-merge.md` there for the seam list this spec resolves.

**What the engine does.** A user's jot (in a live meeting note, later in any Obsidian note) is a query. The
engine finds what is relevant, decides whether it really is, and writes one short line under the jot:
`**Topic:** one or two sentences (~20–35 words)`. The line evolves only when newly heard or newly indexed
information adds a supported fact. Quiet beats wrong. The user's own text is never touched.

Not in the engine: briefs, action lists, "also discussed". They may run after Stop as a separate low-priority
job (§2.10) and must not shape any engine type.

---

## 0. Evidence this spec rests on

All numbers below are measured in the handoff directory unless marked *estimate*.

| Fact | Value | Source |
|---|---|---|
| Answerable jots whose gold evidence lies in [typed − 90 s, typed + 30 s] | **74 / 82 (90%)** | OOF decision predictions joined to `cases.v3` times (computed for this spec) |
| Ladder stop rule at relevance P ≥ 0.5: rung 1 succeeds / any rung succeeds | 76/82 and 79/82 answerable; abstain jots wrongly "found": 4/14 | same; candidate pool = top-12 cosine ∪ top-12 BM25 ∪ injected gold, so optimistic |
| Same at P ≥ 0.6 | 68/82, 71/82; abstain 2/14 | same |
| Relevance head (6 cheap features) held-out | AUROC 0.771, ECE 0.036; pair precision 0.74 / recall 0.35 at 0.5; keeps 98.7% of positives at 0.042 while removing only 8.2% of negatives | `result-4-decision.md`, OOF predictions |
| Strongest relevance feature | time gap (weight −1.0 on standardized gap/600 s) | `logistic.json` |
| Answerability head at 0.5 | catches 5/14 abstentions, withholds 2/82 answerable | `result-4-decision.md` |
| Off-the-shelf EG2 decision fine-tunes, TinyJev | AUROC 0.55–0.61 (near chance) | same |
| Evidence recall vs full-prompt cap (hybrid ranker, live / final) | 450 tok: 64.5 / 45.5% · 1,500: 98.8 / 94.9% · 4,000: 100 / 100% | `result-4-retrieval.md` |
| E4B live line, ~390-token prompt (rules cached) | TTFT p50 119 / p95 174 ms; whole call p50 469 / p95 958 ms | `notes-5/e4b-default.jsonl` |
| E4B line, ~620 / ~1,040-token prompt | TTFT p50 310 / 647 ms, p95 366 / 769 ms | `notes-5/e4b-tuned.jsonl` |
| E4B decode | ~77–79 tok/s under eval load (159 tok/s idle); a line is ~30 tokens | same, `measure-final.json` |
| E4B cold load | 15.9 s | `notes-5` call stats (`loadMs`) |
| Cached-prefix output | byte-identical to uncached | `measured-1.md` |
| E4B memory at n_ctx 8192 | Metal-mapped weights 4,363 MiB, CPU-mapped 2,192 MiB, Metal compute buffer 2,088 MiB; footprint after load 1.48 GB (iteration 1) | `notes-5/default.log`, `measured-1.md` |
| ASR lag with live indexing on vs off | p95 0.1 s / max 0.1 s both; 813 chunks indexed | `vault-4/asr-{on,off}.json` |
| **Gap:** ASR lag with E4B generating concurrently | **unmeasured** — that replay produced 0 live lines (`live_lines_before_stop: 0`) | same |
| Speech rate / ASR segment size | 131 words/min; segment median 11 words, p90 25 | `cases.v3` |

---

## 1. Principles for the invisible parts

| # | Rule | How it is verified |
|---|---|---|
| P1 | **Quiet beats wrong.** Every path that is unsure produces no line, never a weaker or guessed one. A stale-but-once-correct line beats a fresh wrong one. | Harness: ≥ 98% of line revisions judged supported; abstain jots stay quiet ≥ 90%. Fault-injection tests (§6) assert no line is written on any failure. |
| P2 | **Work only on change.** Every model call has a cause: a new finalized chunk, a jot revision, a retraction, Stop. No polling loops, no periodic passes. | Each call record carries `cause`. A 10-minute silent, untyped replay makes **zero** E4B and zero embedding calls. CI greps the engine module: no repeating timers, no `sleep` loops; the three allowed one-shot wakes (§2.9) are named. |
| P3 | **One of each.** One chunker, one index for meeting and vault, one funnel, one generator, one line prompt, one scheduler, one harness. No "live" vs "final" modes. | Delete list (§7) completed; a test indexes a meeting and a vault note and asserts both went through `Chunker` and `Index.apply`. `TextJob` has no live/final split. |
| P4 | **The user's words are sacred.** User text is never modified. An AI line the user edits becomes theirs and is never rewritten. The user's spelling wins over ASR in the line. | Property test over random edit/ownership sequences; harness asserts no writes inside user-owned ranges; spelling-lock unit tests (§2.7). |
| P5 | **Private by construction.** No audio on disk. No prompt or transcript text in logs. At Done or 24 h, everything derived from the transcript is gone: rows, vectors, accelerator entries, KV snapshots, in-memory caches, SQLite free pages. | Canary purge test: a unique token is spoken in a fixture; after Done, scan the app support dir, caches, DB file bytes and WAL for it. A socket test asserts no connection other than the 127.0.0.1 listener. |
| P6 | **Recognition first.** ASR never waits for enrichment; enrichment yields to ASR pressure. | Real-mode harness on the 60-min replay: ASR lag p95 ≤ 0.25 s **with E4B generating**. Pressure-ladder unit tests. |
| P7 | **Deterministic and replayable.** The engine reads time only from an injected clock and models only through injected protocols. Same events + same model outputs ⇒ same line history. | Harness cached mode run twice ⇒ byte-identical line histories. |
| P8 | **Durable at every transition.** A crash loses at most the call in flight. Restart resumes from persisted watermarks, never from scratch, never re-showing a retracted line. | Kill-and-relaunch test mid-replay: line histories equal an uninterrupted run except for retried calls. |
| P9 | **Every number is a named, sourced constant.** All thresholds and budgets live in one `EngineConstants` with a comment citing the measurement. Variants exist only as harness arms, never env flags in the product. | `WORKSCRIBE_RETRIEVAL_CONFIG`, `WORKSCRIBE_DECISION_MODEL`, `WORKSCRIBE_TRANSCRIPT_PREFIX`, etc. are gone from product code (grep). |
| P10 | **Small, domain-named, single-owner code.** Types are named for pipeline concepts. One actor owns engine state; models run off-actor and re-enter as events. No mutable globals. | `nonisolated(unsafe)` and static hooks count = 0 in the engine module; Swift 6 strict concurrency on for it. |

---

## 2. The pipeline

```
 Sources ──▶ Chunker ──▶ Index ─────────────────────────────┐
 (meeting stream, vault,     (SQLite rows + FTS + vectors;   │ new chunk (Watch)
  folders, clips, screen)     one store, purge fences)       ▼
                                                    ┌──────────────────┐
 Plugin blocks ──▶ Query ──▶ Find (ladder) ──▶ Decide ──▶ Enrich (E4B) ──▶ Line ──▶ Render
                                    ▲                └── Scheduler: events in, priorities, pressure ──┘
```

Proposed layout: pure parts in `Sources/WorkScribeCore/Engine/` (`Source.swift`, `Chunker.swift`,
`Index.swift`, `Query.swift`, `Find.swift`, `Decide.swift`, `Enrich.swift`, `Line.swift`, `Engine.swift`,
`EngineConstants.swift`); app wiring in `Sources/WorkScribe/EngineHost.swift`; harness in
`Sources/WorkScribe/Replay.swift`. Pure parts need no model, GPU or filesystem in their tests.

### 2.1 Source

| | |
|---|---|
| Responsibility | Turn something the user has into ordered **passages** with provenance, and report revisions. |
| Types | `SourceID {kind: meeting/vault/folder/clip/screen/attachment, ref}`; `Passage {source, anchor, start?, end?, speaker?, context?, text}`; `SourceRevision {source, revision: Int, passages}` |
| Adapters | `MeetingSource` (one passage per **finalized** ASR segment; anchor = segment ID; times in meeting seconds; speaker is an attribute), `VaultSource` and `FolderSource` (one passage per Markdown block or extracted paragraph; anchor = heading path + block ordinal; context = `Title > H1 > H2`), `ClipSource`, `ScreenSource` (OCR text with meeting times), `AttachmentSource` (an image pasted into a jot → its observation text, scoped to that one query). |
| Revisions | Meeting: append, plus rare retractions (echo filter at Stop) and text corrections. Speaker relabels change attributes only. Files: whole-file revision by content hash. |
| Must never | Index partial ASR hypotheses. Write audio. Embed speaker names (renaming a voice must not re-embed). Run E4B vision during a live meeting (the libmtmd helper unloads the resident text model; reload costs ~16 s) — attachments use OCR live, vision after Stop or outside meetings. |
| Replaces / keeps | Keeps `Capture`, Nemotron stream, `EchoFilter`, `Meeting`/`Segment` storage, `VaultWatcher`, `VaultIndexer` walk/parse, `FolderRules.walk`, `FileExtractors`, `Clip*`, `ScreenSceneText` OCR. Replaces `IndexService.liveChanged/drainLive`, `ScreenNoteEvidence` (screen text injected into notes). |

### 2.2 Chunk and Index

**One chunker.** `Chunker.chunks(passage) -> [Chunk]`, same algorithm for every source:
a chunk never crosses a passage; split only when a passage exceeds **60 words**, at sentence ends; a tail
under 15 words joins the previous piece; hard-split a sentence over 60 words at word boundaries. With ASR
segments at median 11 words, a meeting chunk is almost always one segment — the unit the relevance head was
trained on. Embedded text = `context + "\n\n" + text` for files (title and heading path), `text` alone for
meetings. Small-to-big context is added later, at prompt time (§2.5), not by bigger chunks.

**Identity.** `ChunkID = hex(SHA-256(source ‖ anchor ‖ pieceIndex ‖ text))[0..<32]`. Chunks are immutable.
Changed text ⇒ new chunk, old one tombstoned. Each row also gets a monotonic `seq` (SQLite rowid); `seq` is what
watermarks use. A vector is reused when the same source already holds a row with the same embedded-text hash.
There is no cross-source vector cache, so purging a source purges its vectors.

**One index.** The existing `SearchIndex` SQLite schema (sources, chunks, FTS5, vector_changes) plus the
`VectorStore` accelerator, wrapped as:

```swift
protocol Index {
  func apply(_ revision: SourceRevision) throws -> ChunkDelta      // diff: added [Chunk], removed [ChunkID]
  func setVectors(_ vectors: [ChunkID: [Float]], model: String) throws
  func candidates(_ q: QueryVector, scope: Scope, limit: Int) throws -> [Chunk]  // vectors present only
  func purge(_ source: SourceID) throws                           // rows, FTS, vectors, accelerator; writes fence
}
enum Scope { case meeting(MeetingID, ClosedRange<Double>?), linked(DocumentID), vault(excluding: Set<SourceID>) }
```

Live meeting and vault go through the same `apply`. FTS rows are written at `apply` (keywords searchable at
once); vectors follow through embedding admission (`IndexAdmission`: live chunks > queries > backlog, two
chunks per backlog call, kept from the vault branch). A chunk without a vector is "not yet heard": Find and
Watch ignore it until its vector lands.

**Purge.** `purge` deletes in one transaction, writes `purged:<source>` (late writes are rejected), runs with
`PRAGMA secure_delete=ON`, then `wal_checkpoint(TRUNCATE)`. The engine drops in-memory state for that source
(query vectors stay; they are the user's text), and the generator drops KV snapshots.

| | |
|---|---|
| Must never | Hold two chunkers. Re-embed unchanged text. Keep anything derived from a purged meeting. Block on embedding before FTS is written. |
| Replaces | `TranscriptChunker`, `MeetingChunker` (20–40 s spans, `pieces`, tail merge), `TextChunker` (1,800 chars, 200 overlap), `MarkdownChunker`, `LiveIndex.updateLive` (its diff idea becomes `apply`), `RetrievalEmbeddingCache` in the product path, `liveVectors`. |
| Keeps | `SearchIndex` schema and FTS tokenizer, `VectorStore`, `VectorEncoding`, `IndexAdmission`/`AdmittedEmbedder`, purge fence, `CoreMLEmbedder` (idle release). |

### 2.3 Query

```swift
struct Query {
  let id: QueryID              // document ID + plugin block ID
  var text: String             // the jot, user's spelling; image embeds stripped (NoteImageContent)
  var revision: Int
  var typedAt: Double?         // meeting seconds when typed; nil outside a meeting or after Stop
  var context: QueryContext    // note title, heading path. Prompt only — never embedded, never a feature.
  let kind: Kind               // .jot | .ask(conversationID)
}
```

- A jot is a top-level paragraph or list item with at least one content token. Headings, owned blockquotes and
  empty bullets are not queries.
- **Minor vs major edit.** Minor = normalized token sets differ by ≤ 1 token or ≤ 30% of tokens: `typedAt` is
  kept and the line is re-checked. Major: `typedAt` = edit time (if recording) and the line is hidden (§3).
- Outside meetings, a block becomes a query only when typed or edited in this session, or via an explicit
  "Enrich this line" command. Opening an old note must not trigger work.
- The query vector embeds the raw jot (the relevance head was trained on raw jots). Query vectors are cached by
  text for the session.
- Ask is a `Query` with `kind: .ask`: same Find and Decide; its answer streams with citations through the
  existing Ask prompt; it has no line lifecycle.

Replaces the enhancement fields on `Note` (`enhanced`, `enhancedFrom`, `excerptRefs`, `enhancementState`,
`isStale`, `lastEnhanced`, `trace.revisions`) with `Query` + `Line` (§3) in a `lines` table next to the index.
Keeps plugin block IDs and `anchors.reconcile`.

### 2.4 Find — the time-first ladder

| Rung | Scope | Used when |
|---|---|---|
| 1 Moment | current meeting, chunks overlapping **[typedAt − 90 s, typedAt + 30 s]**, plus screen chunks in that range | `typedAt` is set |
| 2 Meeting | whole current meeting so far | rung 1 failed **and** the moment window has closed |
| 3 Linked | notes linked to/from this note (Obsidian links) | outside meetings |
| 4 Vault | indexed vault, folders, clips, finished notes, excluding the current meeting and this note | everything above failed |

- A rung **succeeds** when some candidate has relevance ≥ `stop` (0.5, §2.5). Stop there. Never lower the bar to
  get an answer; an exhausted ladder means `listening` (meeting) or `quiet` (outside).
- **The moment window closes on speech, not on a timer.** At typing time only [t − 90, t] exists. Rung 1 stays
  open until a finalized chunk ending after t + 30 s arrives (or Stop). Then widen once. The answer to a
  question usually arrives in those 30 s (74/82 gold inside the window).
- **During a meeting the vault is background** (definitions, names, spellings), never meeting facts. A vault-only
  line during a meeting carries a visible source ("from *Sync design*"), and the prompt labels it as background.
  Outside meetings the vault is the evidence.
- **Watch** (the incremental half of Find). When a chunk gets its vector, score it against every active query
  in its scope (open meeting note; open vault notes outside meetings). Dot products over ≤ a few hundred queries
  cost microseconds. Then: listening query + chunk ≥ `stop` in an open rung ⇒ found; answered query + chunk ≥
  `stop` ⇒ fresh evidence (update candidate). Each line keeps `seenThrough` (max `seq` considered); restart
  re-watches everything after it.
- **Candidates.** Meeting rungs score every vectorized chunk in scope (≈ 700 chunks per hour). Rungs 3–4: top 48
  by cosine from the accelerator ∪ top 24 FTS hits, then exact full-vector cosine.
- Output: `FindResult {rung?, evidence: [Evidence], holding: Bool}` where
  `Evidence {chunk, relevance, rung, fresh}`.

| | |
|---|---|
| Must never | Search the vault while a meeting rung succeeds (an arm may test "background always", §5). Use chunks without vectors. Read wall-clock time. |
| Replaces | `NotePlanner.plan/finalPlan/broadPlan/rank/expand/release/recent/nearest`, `NotePlan`, `ExcerptPolicy` (live/final), `RetrievalConfig` and its flags, `timeMatched` + time-only fallback, `unionLive`, `QueryExpansion`, `BackgroundEvidence` (becomes rung 4). |
| Keeps | `LexicalMatcher.tokens` (features, FTS). The small-to-big expansion idea from `BroadRetrieval`. |

### 2.5 Decide — the relevance gate

One calibrated head, two operating points, plus answerability:

| Constant | Value | Meaning | Basis |
|---|---|---|---|
| `keep` | 0.042 | evidence floor: chunks below it never reach E4B | 98.7% positive retention held out |
| `stop` | 0.5 | a rung succeeds; Watch triggers an update | OOF: 76/82 answerable stop at rung 1; 4/14 abstain wrongly found. **Refit leave-one-case-out in the harness** before promotion. |
| `answerable` | 0.5 | first line is attempted only if answerability(query, pack) ≥ this | 5/14 abstentions caught, 2/82 answerable withheld |

- Features (unchanged from `EmbeddingDecisionModel`): cosine, gap/600 s (capped at 1), speaker change, jot-token
  coverage, Jaccard, log length. **Gap for Watch** = distance to the nearer of `typedAt` and the end of the line's
  latest supporting evidence. This follows a topic that keeps being discussed, so "ship date?" can still evolve
  ten minutes later. It equals the trained definition on first find. The harness compares it with typed-only gap
  (§5) before it becomes the default.
- **Untimed chunks** (rungs 3–4) are out of the head's training distribution. Until an `untimed` head is trained
  on vault fixtures, rungs 3–4 use cosine ≥ 0.78 (vault branch value, **unvalidated**) as both `keep` and `stop`.
- The artifact is bundled and always on. Model identity is checked at load. A mismatch fails closed: no lines,
  one status message.
- Never generates text. Never sees image evidence (attachments bypass Decide, as today).
- Replaces `NoteRelevance.threshold` (0.68 cosine), the `relevance` closure with its 20 s `ContinuationBox`
  timeout, `Grounding.addresses` (time-match heuristic), the `WORKSCRIBE_DECISION_MODEL` opt-in. Keeps the
  `DecisionModel` protocol, `EmbeddingDecisionModel`, the parity golden test.

### 2.6 Evidence pack (Find + Decide → Enrich)

1. Seeds: evidence ≥ `keep` from the successful rung, plus fresh Watch chunks; sort by relevance.
2. Expand each seed: the rest of its passage; meeting chunks within ±5 s; for questions (ends in `?` or starts
   with a wh-word) chunks starting ≤ 12 s after the seed. (These are the 1.5k-hybrid sweep values.)
3. Budget: whole prompt ≤ **1,500 tokens**, counted exactly with the llama.cpp vocabulary (one BOS). Drop whole
   seed groups, lowest relevance first. Clip a single oversized group at a sentence end.
4. Order chronologically. Evidence IDs (`E1…`) are assigned in first-seen order **per query and kept across
   revisions**, so "Why?" is stable and an append-only pack keeps a reusable prompt prefix.

### 2.7 Enrich — E4B writes or refines the line

One call per query per change. Resident llama.cpp E4B, rules prefix cached (byte-identical outputs measured).

**Prompt** (stable parts first, so a per-query KV prefix *could* be reused later):
```
<rules — cached prefix, ~300 tokens>
<note section="Pricing">ship date?</note>
<evidence id="E1" at="12:04" who="Speaker 2">…</evidence>      (chronological; fresh ones marked new="1")
<background id="B1" title="Sync design">…</background>         (rung 4 only)
<current>**Ship date:** Being discussed; Oct 28 at risk.</current>   (absent on first line)
```
Rules (rewrite of `finalNoteRules`): reply with exactly one of `* **Topic:** sentence(s)`, `UNCHANGED`, or
`NOT DISCUSSED`, then `</output>`. Use the note's spelling for names, acronyms, terms. Answer a question if the
evidence answers it, otherwise say what is known and what is open. With `<current>`: keep every fact unless the
new evidence changes it, and then say what changed ("moved from Oct 28 to Nov 4"); reply `UNCHANGED` if
nothing new. Keep status exact (proposed ≠ agreed; at risk ≠ cancelled). Background explains names and terms;
meeting facts come only from evidence. Keep the existing rules about jokes, garbled numbers, speaker labels,
invented causes, and untrusted input. `maxTokens` 96.

**Acceptance checks** (deterministic, in order; any failure ⇒ no visible change):

1. Parse exactly one bullet (`NoteOutput.parse`, single-bullet path). 8–45 words (target 20–35). Not a refusal.
2. **Grounding** (`Grounding.supported`): numbers ⊆ evidence ∪ jot; no value the evidence negates is affirmed;
   ≥ 50% of content words from evidence ∪ jot. Background counts as support only for rung-4 lines.
3. **Spelling lock**: a term in the line within edit distance ≤ 2 (or the same acronym letters) of a jot term is
   replaced by the jot's spelling.
4. Updates only:
   - **Facts preserved.** Every number, date, name and status word of `current` appears in the new line, unless
     the fresh evidence negates it or the line says it changed. Keep `FactualRewrite.preserve` for clauses.
   - **Material difference.** The fact set (numbers, dates, capitalized names, status words: agreed, decided,
     approved, proposed, at risk, blocked, open, pending, moved, delayed, cancelled, shipped) must differ.
     Otherwise it counts as `UNCHANGED`.
   - **No flap.** The text is not equal to any earlier revision.
   - **Topic kept.** The previous topic label is reused unless the jot changed.
5. Revision guards at apply time: query revision, line revision and ownership must be unchanged since the call
   was planned. Otherwise discard the result and re-mark the query dirty.

Outcomes: `.line(text, evidenceIDs)`, `.unchanged`, `.quiet(reason)`. A failed or quiet attempt records its
**basis signature** (hash of jot text + evidence chunk IDs). It is retried only when that signature changes.

| | |
|---|---|
| Must never | Write more than one line. Take facts from background during a meeting. Rewrite without new evidence or a jot edit. Run a separate "final" prompt or pass. Fall back to quoting transcript. |
| Replaces | `NoteEnhancer` (per-note loop, `liveNotesPerPass`, `tried`, `liveSelections`, `enhanceFinal`, `extractive`/`quoteLine`, nearest-excerpt retry, background cache), `NotePrompt.instruction` (multi-note JSON), `NotePrompt.maxTokens(plan)`, `NoteOutput.align`, `NoteEnhancement.apply`, `TextJob.liveLine/finalLine`. |
| Keeps | `TextModel`/`ResidentTextModel`/`LlamaTextEngine`, the C bridge with prefix snapshots, `GenerationControl` cancel, `Grounding`, `FactualRewrite`, `NoteOutput.parse/usable/withoutPlaceholder`, `Grounding.tidy`. Rename `TitleModel`/`TextModels.llama` to something that says "the generator". |

### 2.8 Render — plugin decorations

The app publishes one SSE event per line change:
`line {documentId, blockId, state, text?, revision, changed?: [[from,to]], sources: [{kind,title,at?}], reason?}`
plus one engine `status {model: ready|loading|missing, paused?: reason}`.

| State | Plugin draws |
|---|---|
| listening | nothing for 8 s after typing, then the faint nib (existing). Nothing outside meetings. |
| found | nothing unless it lasts > 1.5 s, then the nib breathes (no text). |
| answered | the line. On a revision bump: word-diff highlight that fades over 1.2 s (no motion with Reduce Motion). |
| settled | the line, no animation. |
| quiet | nothing; after Stop, a question jot shows a faint "Not discussed". |
| yours | an ordinary blockquote in the Markdown (existing "Make it mine"). |
| paused (overlay) | the existing single header line; never per-line errors. |

Keep: CM6 widget decorations (AI text never enters undo history or the Markdown before Finalize), deferral
while the caret is in the block or IME is composing, stable caret line on height change, "Why?" (evidence quotes
with time and speaker; after purge: "Sources faded with the transcript"), "Let AI rewrite". The `notes` snapshot
and the pending/enhancing/done/plain states are retired.

### 2.9 Scheduler — one engine actor

**Events in:** `speech(meeting, segments)` (finalized only), `retracted(meeting, segmentIDs)`,
`document(id, blocks, meeting?)` (plugin sync), `lineEdited`, `handBack`, `vectors(ChunkDelta)`,
`generated(queryID, outcome, basis)`, `stop`, `resume`, `done`, `pressure`, `thermal`, `modelState`, `ask`.
**Out:** `LineChange`, call records (metadata only), status.

**Lanes:**

| Lane | Executor | Priority order inside the lane |
|---|---|---|
| CPU (Find, Decide, checks, state) | engine actor, inline; sub-millisecond | — |
| Embed | ANE via `IndexAdmission` | live chunks > query vectors > backlog (2 chunks per call, yields between) |
| Generate | one resident E4B, **serial**, one call in flight | P1 first line (newest jot first) > P2 Ask > P3 update (newest first; an update waiting > 60 s is promoted at dequeue time) > P4 after-Stop job |

**Coalescing.** A dirty set keyed by `QueryID` holds the reason and the fresh chunk IDs. Events landing while a
call runs just update the set; the next dequeue takes the latest state. A jot edit cancels that query's in-flight
call (token-boundary cancel). New evidence does not; the result is applied if the guards pass, and the query
stays dirty.

**Allowed one-shot wakes** (the only timers): per-line **10 s cool-down** after a visible revision (evidence
arriving inside it is batched into one update when it ends), model idle release, the 24 h purge deadline.

**Back-pressure:**

| Signal | Effect |
|---|---|
| ASR lag ≥ 2 s (`screenPaused`) | P3/P4 and backlog embedding stop; P1/P2 continue |
| ≥ 6 s (`aiPaused`) | no generation or embedding admitted |
| ≥ 12 s (`transcriptDelayed`) | also cancel the in-flight call at the next token |
| thermal `.serious` | as ≥ 2 s; prompt budget for P1 drops to 450 tokens |
| thermal `.critical` / Low Power + battery < 20% | no generation; status says so |

Batching (iteration-2 multi-sequence) and per-query KV reuse are **not built** until the harness shows a budget
miss that they fix (§4).

**Stop settles pending work.** Capture drains → final chunks arrive as normal events → open moment windows widen
once → the in-flight call finishes (it is not cancelled) → the dirty queue drains, with cool-downs flushed →
then answered ⇒ settled and listening ⇒ quiet. No re-transcription, no rewrite of clean lines, no second pass.
Done waits for the drain up to 5 s, then finalizes what is settled. A still-pending query keeps its current
visible state, which was correct when written. Resume reopens settled/quiet lines of that meeting.

Replaces `NoteEnhancementScheduler` (4 s debounce, 15 s throttle, pending/running/dirty/live/heartbeat sets,
`yieldLive`, the live and final passes). Keeps `RecordingPressure`, the `RecordingDeadline` stall idea (as the
per-call watchdog), `GenerationControl`.

### 2.10 After-Stop job (outside the engine)

Brief, action items and "also discussed" may run at P4 after settle. They read settled lines and *uncovered
chunks* (meeting chunks not cited by any line) through a read-only API. They own no engine type, no planner
field and no prompt rule. They can be switched off without touching the engine.

---

## 3. Line lifecycle

States: **listening · found · answered · settled · quiet · yours**. "Updated" is an event (a revision bump on
an answered line), not a state. "Paused" is an overlay from the scheduler, not a line state.

```
            ┌──── NOT DISCUSSED / checks fail (basis recorded) ────┐
            ▼                                                      │
 jot ─▶ listening ──chunk ≥ stop──▶ found ──line passes checks──▶ answered ──fresh chunk ≥ stop──▶ (update call)
            ▲                                                   │   ▲            │  passes + material ⇒ rev+1 "updated"
            └──── evidence retracted & unsupported, or major edit ┘   └────────────┘  unchanged/cosmetic ⇒ no visible change
 answered/listening ──Stop + drain──▶ settled / quiet        any ──user edits AI line──▶ yours ──Let AI rewrite──▶ listening
```

| From | Event | Guard | To | Effect |
|---|---|---|---|---|
| — | jot created | is a query (§2.3) | listening | embed query; run ladder |
| listening | ladder or Watch: chunk ≥ `stop` | answerability ≥ 0.5 | found | enqueue P1 |
| listening | moment window closes | rung 1 failed | listening | widen to rung 2, then 3–4, once |
| found | `.line` | guards pass | answered (rev 1) | publish |
| found | `.quiet` / checks fail | — | listening | record basis; retry only on a new basis |
| answered | fresh chunk ≥ `stop` | not in cool-down | answered (dirty) | enqueue P3 |
| answered | `.line`, material, facts preserved | guards pass | answered (rev+1) | publish with `changed` ranges |
| answered | `.unchanged` / cosmetic / fails | — | answered | advance `seenThrough` only |
| answered | evidence retracted | remaining evidence fails Grounding | listening | remove the line; **no model call** |
| any but yours | minor jot edit | — | same | re-run Find; dirty only if the basis changed |
| any but yours | major jot edit | — | listening | hide the line; reset `typedAt` |
| answered | user edits the AI line | — | yours | blockquote written; never touched again |
| yours | Let AI rewrite | — | listening | quote removed; ladder re-runs |
| listening / found / answered | Stop and drain complete | — | quiet / settled / settled | — |
| settled / quiet | Resume | — | answered / listening | Watch again |
| settled / quiet | Done | — | finalized | lines → Markdown blockquotes; line rows, revisions and evidence refs purged |
| any | jot deleted | — | — | cancel work; drop row |

Outside meetings there is no listening phase: ladder → answered → settled (or quiet). Watch reopens a settled
line in an **open** note when a newly indexed chunk scores ≥ `stop`.

`Line {query, state, text?, topic?, revision, evidence: [ChunkID], basis, seenThrough: Int64, queryRevision,
revisions: [{text, evidenceIDs, cause, at}]}` is persisted on every transition (P8).

---

## 4. Budgets and measurements

Every row is reported by the harness (§5). Real-mode rows run on the 60-min replay unless noted.

| Budget | Target | Basis |
|---|---|---|
| Jot received → state known (found or listening) | p50 ≤ 80 ms, p95 ≤ 150 ms | HTTP + EG2 query embed (*estimate* 20–60 ms warm, to measure) + Find/Decide < 1 ms |
| Jot received → line visible (evidence already heard, E4B idle) | p50 ≤ 1.0 s, p95 ≤ 1.8 s | TTFT 310–650 ms at 620–1,040 tokens, cached rules (measured) + ~30 tokens at ~77 tok/s ≈ 0.4 s |
| Same with one call ahead in the queue | p95 ≤ 3.0 s | + one call (measured p95 0.96–1.12 s) |
| Speech chunk finalized → updated line visible | p50 ≤ 1.2 s, p95 ≤ 2.5 s (excluding cool-down) | chunk embed + Watch + one call |
| Stop → all lines settled | p95 ≤ 5 s | only dirty queries drain; Stop measured at 3.66 s on the replay |
| First line after a cold start | ≤ 18 s; 0 s extra when prewarmed at Record | measured load 15.9 s; prewarm E4B and EG2 when recording starts |
| Visible revisions per answered line, per meeting | median ≤ 2, p95 ≤ 4 | user's evolution example has 3 |
| Cosmetic revisions (no fact change) / flaps | 0 / 0 (alarm > 2%) | enforced by checks; measured by fact anchors |
| E4B calls per 60-min meeting | ≤ 3 × jots + 10 | ~30 jots ⇒ ≤ 100 |
| GPU duty from E4B over 60 min | ≤ 5% (≤ 180 s busy) | 100 calls × ≤ 1.1 s |
| Energy | engine adds ≤ 1.5 W average over the ASR-only arm (*estimate*; the duty budget governs if the measurement disagrees) | `powermetrics` (cpu/gpu/ane) sampled by the harness launcher, same replay with the engine off vs on |
| Thermal | state stays ≤ `.fair` on the test Mac for the whole replay | `ProcessInfo.thermalState` log |
| ASR lag with everything running | p95 ≤ 0.25 s, max ≤ 1 s | 0.1/0.1 s measured with indexing only; **must be re-measured with E4B active** |
| Memory | E4B `n_ctx` 4096 (prompts ≤ 1.5k + 96 out; Ask ≤ 3k), `n_ubatch` 512. App `phys_footprint` ≤ 3.5 GB in a meeting; growth over 60 min ≤ 100 MB; back to baseline ± 50 MB 10 min after Done | compute buffer was 2,088 MiB at n_ctx 8192 — measure at 4096; record mapped (clean) weights separately (6.4 GiB) |
| KV prefix snapshots | ≤ 8 entries / 256 MiB (existing LRU) | iteration-2 policy |
| Index growth per meeting hour | ≈ 700 chunks, ≤ 2 MB on disk, 0 after purge | 131 wpm, 11-word segments; 768-d f16 = 1.5 KB per vector |
| Index per vault chunk | ≤ 2.5 KB all-in; accelerator 256 B | f16 full vector + int8 256-d |
| Purge | at Done or 24 h: 0 rows, vectors, FTS terms, accelerator entries, KV snapshots, line revisions or evidence refs for the meeting; canary token absent from every file byte, including WAL and free pages | P5 canary test |
| Find + Decide | ≤ 15 ms p95 for a 60-min meeting + 10k-chunk vault | dot products + 0.1 ms head |

---

## 5. One evaluation harness: timeline replay

`WorkScribe --replay <cases.jsonl> [--models cached|real] [--audio] [--arm arm.json] --out <dir>`

**Case format** (extends `cases.v3`; a converter ships with stage 1):

```json
{"id": "...", "status": "reviewed",
 "speech": [{"id": "s1", "speaker": "Speaker 1", "start": 0, "end": 6.7, "text": "...", "final_at": 7.2}],
 "retractions": [{"at": 540, "segments": ["s12"]}],
 "vault": [{"id": "v1", "title": "...", "markdown": "..."}],
 "jots": [{"id": "n1", "text": "ship date?", "at": 57, "edits": [{"at": 80, "text": "ship date??"}]}],
 "stop_at": 560,
 "gold": {"n1": {"abstain": false, "evidence": ["s5", "s6"],
   "milestones": [{"after": "s20", "must": ["Oct 28"], "must_not": ["Nov 4 agreed"]},
                  {"after": "s41", "must": ["Nov 4"]}],
   "final": {"must": ["Nov(ember)? 4"], "must_not": ["Dec 1"]}}}}
```

`must` / `must_not` are **anchors**: regexes or number/date sets, authored and reviewed per case. `final_at`
defaults to `end + 0.5 s`.

**Run.** The engine runs unmodified on a virtual clock. Events fire at their times: speech at `final_at`,
jots and edits at `at`, Stop at `stop_at`. In `--models real` the clock advances by each call's measured
duration, so queueing behaves as in the app. In `--models cached`, E4B outputs and durations come from a cache
keyed by `(model, prompt SHA-256)` and embeddings from the exact-key cache; a miss fails and lists the misses
(as today). `--audio` plays the fixture WAV through real capture and Nemotron, and adds ASR lag, memory,
thermal and energy. `--arm` overrides `EngineConstants` for that run only.

**Scored per jot, over time:**

| Metric | Definition |
|---|---|
| found | time typed → found; recall of gold evidence IDs in the line's evidence at first answer and at settle (only IDs heard by then) |
| faithful@step | every distinct revision: deterministic anchors first (numbers ⊆ heard evidence, `must_not` absent), then a **blind LLM judge** gets the revision, the jot and the transcript up to that moment: supported / unsupported / contradicted. The judge is used only here. |
| converged | the settled line hits the `final.must` anchors and no `must_not` |
| milestones | at each milestone, the visible line satisfies its anchors (or is empty — empty is never an error) |
| quiet | abstain jots never show a line |
| churn | visible revisions; cosmetic revisions (fact-anchor set unchanged); flaps |
| latency | typed → first line; finalized speech → update visible |
| funnel | gold recall at Find candidates → after `keep` → in the prompt (replaces `--eval-retrieval` and `--eval-decisions`) |
| system | calls by cause, tokens p50/p95, TTFT, GPU busy s, embed calls; real/audio: ASR lag, footprint, thermal, energy |

**Headline score** (what to hill-climb): `useful = answerable jots converged with zero unfaithful revisions`,
minus `2 × jots with any unfaithful revision`, plus `quiet-correct abstain jots`; case-macro, with bootstrap CI.
Threshold fitting (`stop`, `keep`, window, budget) reports **leave-one-case-out only**.

**Arms to run before promotion:** gap definition (topic vs typed), `stop` 0.5 vs 0.6, answerability gate
on/off, budget 1,500 vs 4,000, moment window +30 vs +10 s, background-always vs strict ladder.

**Keep:** `cases.v3` + vault fixtures (converted), the exact-key embedding cache and miss listing, llama-exact
token counting, the judge kit (`judgekit.py`, `make_packets.py`, `aggregate.py`; `JUDGE.md` rewritten for
faithfulness-only packets with temporal availability, from its live-level rules), the LOCO fold logic from
`tune-retrieval.py` (as `scripts/fit-engine.py` over replay outputs), the decision-head trainer (as
`scripts/train-decision-head.py`, fed pairs exported by `--replay --export-pairs`), the TTS real-meeting
fixture, and the purge verification (as a test).

**Data debt:** 12 cases, 96 jots, 14 abstentions, mostly synthetic. Stage 1 adds milestones to every case,
and stages 3–7 each add at least 2 real-meeting or vault cases. No promotion rests on fewer than 20 abstain jots.

---

## 6. Failure behaviour — always quiet, never wrong

| Condition | Detected by | Behaviour | User sees |
|---|---|---|---|
| E4B missing or hash mismatch | `RuntimeAssets` at launch | Find/Decide run; no Enrich; lines stay listening, then quiet at Stop | one status: "AI lines need the Gemma model · run WorkScribe --doctor" |
| E4B loading (cold, ~16 s) | model state | P1 queue waits; prewarm started at Record | listening nibs only |
| E4B slow (call p95 over 3 s in the last 10 calls) | call records | P1 budget → 450 tokens; P3 shed until recovered | nothing |
| Call stalls (no token for 20 s) or errors | per-call watchdog | cancel; record basis; 3 consecutive ⇒ generation paused, status | "AI lines paused" header |
| Thermal serious / critical | `thermalStateDidChange` | §2.9 table | header only when critical |
| ASR pressure | `RecordingPressure` | §2.9 table | existing message |
| Embedder compiling (ANE) or missing | embedder state | no vectors ⇒ nothing is "heard" ⇒ no lines; FTS keeps search working; on ready, Watch catches up from watermarks | listening |
| Index stale (backlog not embedded) | chunk lacks a vector | treated as not heard yet | — |
| Decision artifact invalid or embedding model changed | identity check | fail closed: no lines | status |
| Evidence retracted (echo filter) | `ChunkDelta.removed` | re-check support without a model; remove the line if unsupported | line disappears (rare) |
| Jot edited mid-call | revision guard | discard the result | — |
| Purge during work | fence | in-flight results for that source are dropped | — |
| Crash mid-meeting | relaunch with open session | transcript and lines are durable; `Index.apply` re-run from the transcript (idempotent); queries resume from `seenThrough`; the lost call is re-dirtied | lines persist |
| Disk full / SQLite error | write failure | stop writing lines; capture keeps priority | status |
| Plugin disconnected | SSE closed | engine continues; plugin resyncs on reconnect | existing "AI lines paused · your notes are saving" |

---

## 7. Staged implementation plan

Each stage ships on its own: build green, full test suite green, harness report attached, no product
regression versus the previous stage's report.

| Stage | Delivers | Deletes in the same stage | Exit check |
|---|---|---|---|
| 0 (running) | merge 4 branches, remove MLX/Qwen/E2B/AFM/Dory/bench harness | per `core-merge.md` | tests green |
| 1 Harness | `--replay` (cached + real) driving the **current** engine through an adapter; case converter with milestones; per-jot timeline report; real-mode ASR-lag-with-E4B run | `--eval-notes`, `--eval-retrieval`, `--eval-decisions`, `--measure-text-models`, `--fill-embed-cache` (folded into replay), `--verify-live-session`, `--verify-finalize`, `--verify-notes`, `NoteEvaluation`, `RetrievalEvaluation`, `DecisionEvaluation`, `VaultEvaluation`, `TextModelMeasurement`, `LiveSessionVerification`, `scripts/tune-retrieval.py`, `sweep-retrieval-4.py`, `eval-vault.py`, `score-decision-results.py`, `run-typed-decision.py`, `run-clef-decision.py`, `score-transcript-replay.py`, `prepare-e4b-benchmark.py` | baseline report committed; cached mode deterministic twice |
| 2 Chunk + Index | `Source`, `Chunker`, `Index.apply/purge/candidates`; meeting, vault, folder, clip and screen all through them; secure-delete purge | `TranscriptChunker`, `MeetingChunker`, `TextChunker`, `MarkdownChunker`, `LiveIndex`, `liveVectors`, `drainLive`, `RetrievalEmbeddingCache` (product path) | funnel recall ≥ baseline; canary purge test passes |
| 3 Find + Decide | ladder, Watch, watermarks, evidence pack, always-on head; `stop` refit LOCO | `NotePlanner` (all), `NotePlan`, `ExcerptPolicy`, `RetrievalConfig`, `BroadRetrieval`, `QueryExpansion`, `BackgroundEvidence`, `ScreenNoteEvidence`, `NoteRelevance`, `Grounding.addresses`, relevance closure + `ContinuationBox`, `WORKSCRIBE_RETRIEVAL_CONFIG`, `WORKSCRIBE_DECISION_MODEL` | found ≥ baseline; quiet improves; LOCO table |
| 4 Enrich + Line | `Line` state machine (pure, table-tested), `lines` table, one prompt with `current`, checks incl. spelling lock and material difference | `NoteEnhancer`, `NotePrompt.instruction/maxTokens`, `NoteOutput.align`, `NoteEnhancement.apply`, `enhanceFinal`, `extractive`/`quoteLine`, `TextJob.liveLine/finalLine`, enhancement fields on `Note` | faithful@step ≥ 98%; churn budgets; headline ≥ baseline |
| 5 Scheduler | engine actor, lanes, priorities, coalescing, cool-down, pressure/thermal, Stop = settle, crash resume | `NoteEnhancementScheduler` and its timers, `polish`-era finish steps, mutable static hooks (`embedderSource`, `backgroundSource`) | silent-replay zero-call test; kill/relaunch test; Stop p95 ≤ 5 s; ASR lag budget |
| 6 Render | `line`/`status` SSE events; plugin states, diff highlight, quiet copy | `notes` snapshot event, pending/enhancing/done/plain/paused note states, mock-server parts that only serve them | plugin tests + real-API contract test; visual check on the TTS replay |
| 7 Beyond meetings | jots in any open vault note (session-edited only), rungs 3–4 as evidence, Watch for open notes; Ask through Find/Decide; `untimed` head trained on vault fixtures | Ask's private retrieval path where Find covers it | vault cases in harness; no work on opening old notes (test) |
| 8 Budgets | `n_ctx` 4096 / `n_ubatch` 512, memory/energy/thermal rows in real mode, cold-start prewarm; KV reuse or batching **only if** a budget is missed | whatever lost its arm | every §4 row reported and within target |

**Explicit delete list** (in addition to stage 0; delete if still present):

- Chunkers: `TranscriptChunker`, `MeetingChunker` (+ `pieces`, tail merge), `FolderRules.TextChunker`, `MarkdownChunker`.
- Planning: `NotePlanner.{plan, finalPlan, broadPlan, rank, expand, release, recent, nearest, filterEvidence, clip}`, `NotePlan` (`targets`, `excerpts`, `uncovered`, `chunkRefs`, `timeMatched`, `followUps`, `followUpSegmentIDs`, `retrievalPriority`, `limitPromptTokens`), `PlannedNote`, `Excerpt`, `ExcerptPolicy`, `RetrievalConfig` (all flags, `funnel()`, `application()`, abbreviation table), `QueryExpansion`, `BroadRetrieval`, `BackgroundEvidence`, `ScreenNoteEvidence`, `NoteRelevance`.
- Generation paths: `NoteEnhancer` (whole), `NoteEnhancing`, `NoteDraft`, `ContinuationBox`, `NotePrompt.{instruction, maxTokens, finalNote}` (replaced by the line prompt), `NoteOutput.align/overlap`, `NoteEnhancement`, `TextJob.liveLine/finalLine`, quoted-transcript fallback.
- Scheduling: `NoteEnhancementScheduler`, `liveNotesPerPass`, debounce/throttle constants, `yieldLive`, `heartbeat`.
- Note model: `Note.enhanced/enhancedFrom/excerptRefs/lastEnhanced/enhancementState/isStale/revision/trace.revisions` (moved to `Line`); `editText`'s state strings.
- Env switches: `WORKSCRIBE_RETRIEVAL_CONFIG`, `WORKSCRIBE_DECISION_MODEL`, `WORKSCRIBE_TRANSCRIPT_PREFIX`, `WORKSCRIBE_BATCH_SLOTS`, `WORKSCRIBE_CONTEXT_TOKENS`, `WORKSCRIBE_NOTES_DEBUG` (replaced by the call-record observer).
- Eval CLIs and scripts listed in stage 1, plus both cache-miss spellings (`--list-embed-misses`,
  `--retrieval-cache-misses`; replay lists misses itself) and E4B option scoring (`ws_session_score_options`,
  `LlamaTextEngine.scoreOptions`) unless an arm still uses it.
- Kept, outside the engine: `--bench-scenes`, `--bench-real-vectors`, `WorkScribeVectorBench` (documented
  research benchmarks), Plaud opt-in.
- Moved out of the engine (not deleted): `Commitments`, `BriefPolicy`, missed-topic prompts → after-Stop job.

## 8. Open questions the harness must answer (do not decide by taste)

1. Topic-gap vs typed-gap for Watch (§2.5).
2. `stop` 0.5 vs 0.6, and whether the answerability gate adds anything on top of `stop`.
3. Strict ladder vs "background always" during meetings (does vault help spelling and names without leaking facts?).
4. 1,500 vs 4,000-token pack: is the 100% recall at 4k worth ~1 s more TTFT?
5. Whether the 0.78 cosine floor for untimed rungs survives vault cases, or an `untimed` head is needed first.
