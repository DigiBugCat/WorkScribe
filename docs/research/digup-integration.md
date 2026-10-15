# DigUp → WorkScribe: what it is and how to use it

Researched 2026-10-13 against DigUp `main` at `f9b8106` (2026-10-12), cloned to
`<research-workspace>/digup/src` (outside the repo). Evidence labels:

- **[Source]**: read in DigUp's code or build scripts.
- **[Built]**: I built or ran it on this Mac (M4 Max, 36 GB, macOS 26, Swift 6.3.3).
- **[README]**: DigUp's own claim, not checked.
- **[WS]**: checked in WorkScribe's tree or its bundled runtime.

Read with `embeddinggemma-2-native-integration.md` (runtime choice).

## TL;DR

DigUp is a well-built MIT Swift app. Its most useful parts for us are the **schema and ranking code**, not its
runtime. On a toy test, text search over our transcript segments found the right moment more precisely than
DigUp's raw-audio windows. DigUp's llama.cpp is also newer than the one WorkScribe ships, and the two can't
share a process safely. **Recommendation:** borrow the design and copy about 400 lines (option c with a small
a). If we choose llama.cpp as the runtime, run its embedder in a helper process. Don't depend on DigUp as a
package, and don't run it alongside WorkScribe.

---

## 1. What DigUp actually is

### Layout [Source]

About 17.8k lines of Swift, swift-tools 6.2, `platforms: [.macOS(.v14)]`.

| Target | What it is |
|---|---|
| `DigUpKit` (library product) | The engine, with no UI: crawler, folder rules, extractors (PDFKit, Vision OCR, AVFoundation), `IndexStore` (SQLite), the `Embedder` protocol, the JSON-lines worker client, `Searcher`. Linux and Windows variants live in `Platform/Portable`. |
| `LlamaRuntime` (not a product) | `LlamaEmbedder.swift` (400 lines): EmbeddingGemma 2 on llama.cpp plus `mtmd` (the image/audio encoders), and `LlamaModels`. |
| `digup` (executable) | Commands `estimate`, `index`, `search`, `status`, `eval`, `worker [--text-only]`, `index-service`, `search-service`, `download-model`. The app runs this binary as its helpers: indexing and the query encoder are separate processes that quit when idle. |
| `DigUpApp` | SwiftUI menu-bar app with a ⇧⌘Space panel and Sparkle 2.10.0 updates. It opens recordings at the matched moment by sending QuickTime an Apple Event, or by setting Quick Look's `CurrentTime`. |
| `worker/` (Python), `shell/` (Tauri) | The mlx-vlm reference worker used for evals, and the Windows/Linux UI. Not relevant to us. |

### How it embeds audio [Source, Built]

DigUp embeds the **raw audio**. It never transcribes.

1. `AudioExtractor.windows` (AVFoundation) decodes to 16 kHz mono Int16 and streams through the file.
2. It writes a temporary WAV for each **30 s window, starting every 25 s** (`IndexOptions.audioWindow/audioHop`), so neighbouring windows overlap by 5 s.
   - Windows with RMS ≤ 0.003 (about −50 dBFS) count as silent and are skipped.
   - A tail of at least 2 s of new audio gets its own window.
3. `LlamaEmbedder` feeds each WAV through mtmd's audio encoder (the `mmproj` file). The resulting soft tokens go into the text model as `<bos> … <eos>`.
4. The output is mean-pooled and L2-normalized into a 768-d vector. Audio past 30 s is cut, matching the reference implementation.

Audio segments therefore carry **no text**. For audio, keyword search can only match the file name.

Other inputs [Source]:
- **Video:** a frame every 3 s at a 70-token budget, with near-duplicates dropped by an 8×8 average hash, plus the soundtrack windowed like audio.
- **Documents:** chunks of about 1,800 characters with 200 characters of overlap.
- **PDFs:** one segment per page. A page with under 200 characters is rendered and embedded as an image instead.
- **Prompts:** `task: search result | query: …` for queries and `title: … | text: …` for documents.

### Storage [Source]

Everything is in one SQLite file, `index.sqlite`, at schema version 5:

```sql
meta(key, value)                              -- includes vector_source = model@rev runtime dtype
files(id, path UNIQUE, kind, size, mtime, inode, device, state, detail, info JSON, indexed_at)
segments(id, file → files ON DELETE CASCADE, kind, modality, loc, loc_end, excerpt,
         vec BLOB)                            -- 768 × float16, L2-normalized; loc = seconds or page
fts USING fts5(name, body, original UNINDEXED,
         tokenize = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'")  -- rowid = segments.id
```

- Vectors live in the same database as their metadata, so a crash can't leave the two out of step.
- Each index records `vector_source`, and an index never mixes vectors from different models or settings.
- For search, all vectors are loaded into an mmap'd float16 matrix and scored a block at a time as float32 with `vDSP_mmul`. That is brute force, with no vector database.

### Hybrid scoring [Source]

`Searcher.search` works in these steps:

1. **Meaning.** Compute the cosine against every vector, then turn it into a per-query z-score:
   - Subtract the mean of that vector's modality (only when the modality has at least 20 vectors).
   - Divide by the standard deviation across all vectors (floor 0.02).
   - Keep each file's best segment.
2. **Words.** Run FTS5 `bm25(fts, 3.0, 1.0)` over the quoted query terms joined with OR.
   - A term that matches nothing as typed becomes a prefix search.
   - `coverage` is the share of query terms found anywhere in the file.
3. **Candidates.** A file qualifies if its best z ≥ 2.0 (`zGate`) or its coverage ≥ 0.5.
4. **Score.** `score = mW·max(z,0) + wW·coverage^1.5 (+1 if the query names the file kind)`.
   - Normally mW = 1 and wW = 2.0.
   - Queries made of codes, IDs or long numbers switch to mW = 0.5 and wW = 4.
   - A source comment says this beat reciprocal-rank fusion on DigUp's evals (R@1 0.88 vs 0.73). I didn't re-run that.
5. **Output.** One hit per file, pointing at its best segment. Hits scoring under half of the top hit are folded away as "weaker" (`strongCount`).

The one-hit-per-file rule is wrong for meetings. One meeting can hold several relevant moments.

### llama.cpp [Source, Built]

- `scripts/build-llama.sh` clones `ggml-org/llama.cpp` at tag **b11461** and checks it against pinned commit `4d756bc7…`.
- It applies a one-line patch (`llama.cpp-no-logits.patch`). Without it, embedding contexts reserve 1 MiB of logits per token.
- It builds static `llama + mtmd + ggml(-cpu/-metal/-blas)` with the Metal library embedded and combines them into `Vendor/llama/lib/libllamacpp.a`. That is llama 0.6.0 / ggml 0.26.0.
- `Vendor/` is **not in git**.
- The code uses the new `llama_batch_ext_*` / `llama_process` API and `mtmd`.
- `ReferenceVectorTests` blocks any llama.cpp bump that changes the stored reference vectors.
- [Built] The llama.cpp build took 22 s on this Mac, and `swift build -c release --product digup` took 34 s. I didn't build the app target.

### Models [Source, Built]

- `ggml-org/embeddinggemma-2-GGUF` at revision `bfcd2987…`, with the SHA-256 of each file pinned in `ModelFiles.swift`.
- Text model `embeddinggemma-2-Q8_0.gguf`: **309,855,456 B**.
- Image and audio encoders `mmproj-embeddinggemma-2-Q8_0.gguf`: **554,821,024 B**.
- [Built] I downloaded both from Hugging Face and the checksums matched.
- Queries need only the text file. Indexing images or audio needs both.
- A source comment puts the loaded model at about 1 GB, or 0.25 GB text-only.

### Requirements and license

- **Requirements:** [README] Apple Silicon, macOS 14+, Xcode 26 plus CMake (or `uv`) to build. [Source] `LSMinimumSystemVersion 14.0`, and the only entitlement is Apple Events.
- **DigUp's license:** [Source] MIT, © 2026 Abdur Rahim.
- **llama.cpp's license:** MIT.
- **Model license:** [README] DigUp calls EmbeddingGemma 2 Apache 2.0. I didn't verify this, so check the `google/embeddinggemma-2` card before shipping weights.

### Proof of concept [Built]

The test clip was 58.8 s of macOS `say` speech in three 19.5 s topics (budget, hiring, outage), at 16 kHz mono.

- `digup index` made 3 windows (0–30, 25–55, 50–58.8 s) in **6.9 s**, including the full model load.
- `digup worker --text-only` reported a **0.48 s** load.
- One `digup search` run took 0.52 s wall time end to end, with a **318 MB peak memory footprint**.
- Searching works, but `digup search` returns **one hit per file** and needs `--zgate -10` on a 3-vector index, because the z-scores mean nothing at that size.
- For the comparison, I embedded the same speech as six WorkScribe-style transcript segments (`title: … | text: Speaker N: …`). Script: `<research-workspace>/digup/scripts/compare.py`.

| Query | Raw-audio windows (top-1, then runner-up) | Transcript segments (top-1, then runner-up) | Right answer |
|---|---|---|---|
| cutting the advertising budget | 0–30 s 0.729 · 50–59 0.631 | **7–20 s 0.776** · 0–7 0.710 | 7–20 |
| hiring a product designer | 0–30 s 0.630 · 25–55 0.607 | **20–27 s 0.728** · 27–39 0.623 | 20–27 |
| database outage postmortem | 25–55 s 0.686 · 50–59 0.669 | **39–48 s 0.797** · 48–59 0.685 | 39–59 |
| checkout was down | 25–55 s 0.626 · 50–59 0.595 | **39–48 s 0.750** · 48–59 0.590 | 39–48 |
| who is sending the spreadsheet | 0–30 s **0.617** · 50–59 **0.614** | **7–20 s 0.696** · 48–59 0.628 | 7–20 |
| remote contract for the candidate | 25–55 s 0.678 · 0–30 0.595 | **27–39 s 0.717** · 20–27 0.620 | 27–39 |

The audio windows always contained the answer, but only to within 30 s, and some margins were razor thin
(0.617 vs 0.614). Transcript segments found the exact segment 6 times out of 6, with clearer margins. This
was clean TTS on three topics, so it says nothing about real calls, accents or crosstalk. The direction still
matches the expectation: **we already have the text, so we should search the text.**

---

## 2. Fit with WorkScribe

### What we can reuse directly (MIT, keep the notice)

| DigUp piece | Use in WorkScribe |
|---|---|
| `Searcher.meaning` / `modalityMeans` (z-score per query, centred per modality) plus the coverage-bonus fusion and the lookup mode | Ranking for semantic search over meetings. Copy these formulas and their tuned constants as a starting point. |
| `segments` / `fts` layout: fp16 BLOB in the same database, FTS5 rowid = segment id, the tokenizer string, `vector_source` in `meta` | The basis of our schema (§4). |
| `Vectors` / `VectorStorage` (mmap fp16 matrix, block conversion, `vDSP_mmul`) | In-memory scoring. It fits the codex doc's "Accelerate cosine" plan, at half the memory of fp32. |
| `Prompts` strings | The same strings for whichever runtime we choose. |
| `ModelFiles` (pinned revision, byte counts, SHA-256, HF-cache lookup) | Model provisioning in `scripts/build-app.sh`. |
| `AudioExtractor.windows` (streaming 16 kHz windows that skip silence) | Only if we add audio-window vectors later. |
| `Extractors`, `Rules` (PDF/docx/odt/html text, chunking, and skipping keys, secrets and caches) | The local-files knowledge base for question cards and Ask. |
| JSON-lines worker protocol plus `ReferenceVectorTests` | The helper-process embedder and the regression gate, if we use llama.cpp. |

### Conflicts [WS, Source]

- **WorkScribe's llama.cpp can't run EmbeddingGemma 2.**
  - WorkScribe links `libllama.0.5.0.dylib` / ggml 0.25.1 from the prebuilt NeMo-Speech.cpp runtime (`.runtime/nemo/lib`). `build-app.sh` copies it into `Contents/Frameworks`.
  - Its architecture table has `gemma-embedding` (EmbeddingGemma 1) but **not `gemma-embedding2`**, which b11461 registers. I checked with `strings`.
  - It ships no `libmtmd`.
  - Our vendored `llama.h` lacks `llama_process` and `llama_batch_ext_*`, so `LlamaEmbedder` neither compiles nor loads the model against it.
- **Two llama.cpp copies in one process would be fragile.**
  - Linking DigUp's static `libllamacpp.a` into the WorkScribe executable would duplicate every `llama_*` and `ggml_*` symbol already exported by the NeMo dylibs. `libnemo_speech_asr` itself links `@rpath/libggml*`.
  - Two-level namespacing might keep the two apart, but `CTextGeneration`'s references would bind to whichever copy the linker picks. Two ggml Metal backends would also share one process. I didn't test this, and we shouldn't ship it.
  - We also can't simply bump the NeMo runtime's llama.cpp, because it's a prebuilt we don't control.
  - So on the llama.cpp route, EmbeddingGemma 2 belongs in a **helper process**, as DigUp does it. The Core ML route has no such conflict.
- **Model duplication.** EmbeddingGemma 2 doesn't overlap with our current models (Nemotron ASR, the Qwen3.5 2B or Gemma 4 E2B title model). But Core ML text (about 585 MB) plus GGUF audio (865 MB) would store the text tower twice. Pick one runtime for both.
- **App shape.** DigUp is a file-centric app (`files.path UNIQUE`, `FileKind`, one hit per file), not a library with a stable API.

### What WorkScribe has that DigUp lacks

- Diarized, timestamped, named transcript segments with stable `Segment.id`s. With those, text search can point at a speaker turn, and FTS can match exact names, numbers and jargon inside what was said. DigUp can only match words in file names for audio.
- Separate microphone and system tracks with `sourceOffsets`, which lets us play the exact moment on the right track.
- Meeting metadata (title, start, speakers) and an MCP server.
- DigUp has no way to index a recording that's still growing. WorkScribe gets finalized segments live.

---

## 3. Integration options, ranked

| Rank | Option | Effort | Risk | License |
|---|---|---|---|---|
| **1** | **(c) Borrow the design, plus a small (a): copy about 400 lines** (`Searcher` scoring, `Vectors`/`VectorStorage`, the schema, `Prompts`, `ModelFiles` pattern) into `WorkScribeCore`, adapted to meetings | **3–5 days** for transcript semantic search plus MCP, *once an embedder exists* | Low. All plain Swift and SQLite with no new native dependency. Ranking constants need re-tuning on our data. | Keep DigUp's MIT notice in `Resources/licenses/` for the copied files. |
| 2 | **(a) Larger port: `LlamaEmbedder` plus the worker protocol as a `workscribe-embed` helper executable** with its own static llama.cpp ≥ b11452 (DigUp pins b11461 + patch) | +2–3 days on top of 1. +1–2 days for audio windows and the KB extractors | Medium. A second llama.cpp build to maintain (vector-parity tests needed), and 865 MB of models. | MIT (DigUp) + MIT (llama.cpp) notices. |
| 3 | **(d) Run DigUp alongside, pointed at `…/WorkScribe/Meetings`** | Minutes | Low to try, poor result. `transcript.json` is skipped as a "data file" [Source, `Rules.swift:82`], so DigUp only gets meaning-only 30 s windows of each WAV. No speakers, results open in QuickTime, and a WAV that grows during recording keeps getting re-indexed. The ~/Library skip only applies when crawling from the home folder, so choosing the Meetings folder directly does work [Source]. | None, since nothing ships. |
| 4 | **(b) Depend on DigUp as a Swift package** | 1 day to wire, ongoing churn | High. `DigUpKit` is the only library product; `LlamaRuntime` isn't exported. On macOS the manifest still resolves Sparkle. `CLlama` needs `Vendor/` built by a script that SwiftPM won't run. There's no semver promise, and the file-centric types don't fit meetings. Untested. | MIT. |

**Runtime choice interacts with this ranking.**
- If we follow the codex doc (FluidUse Core ML, macOS 15+), option 1 is the whole integration, and DigUp's runtime is irrelevant.
- If we need macOS 14, or one runtime for text and audio, use option 2's helper. DigUp's `LlamaEmbedder` is the best working reference I've seen for that. [Built] It loaded in 0.48 s with a 318 MB peak (text-only) on an M4 Max.

---

## 4. Recommendation and steps

Do option 1 now and keep the embedder behind the codex doc's `Embedder` protocol. Index **transcript text
first**. Add audio-window vectors only if a later eval on real meetings shows they find moments the transcript
misses, such as failed or non-English ASR, or non-speech sounds.

1. **Runtime.** Pick it per the codex doc. Implement `Embedder.text(_:role:)` for the chosen runtime. If it's llama.cpp, build `workscribe-embed` as a separate executable: DigUp's `LlamaEmbedder` and JSON-lines protocol, static llama.cpp pinned like `build-llama.sh`, no-logits patch, reference-vector test.
2. **Index store** in `WorkScribeCore` (Foundation plus the system `SQLite3`, which includes FTS5 [Source comment]). It's a derived cache at `~/Library/Application Support/WorkScribe/Index/index.sqlite`, safe to delete and rebuild from `transcript.json`:

   ```sql
   PRAGMA user_version = 1;
   CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);       -- vector_source, built_at
   CREATE TABLE sources(
     id INTEGER PRIMARY KEY,
     kind TEXT NOT NULL,                 -- meeting | file | note
     ref TEXT NOT NULL UNIQUE,           -- Meeting.id (UUID) | file path | note id
     title TEXT, started_at REAL,
     fingerprint TEXT NOT NULL,          -- transcript.json size+mtime+segment count (re-chunk when changed)
     voice_revision INTEGER,             -- Meeting.voiceRevision: names changed → refresh fts.speakers only
     in_ask INTEGER NOT NULL DEFAULT 1, during_meetings INTEGER NOT NULL DEFAULT 1,  -- RATIONALE "two switches"
     state TEXT NOT NULL DEFAULT 'pending', indexed_at REAL
   );
   CREATE TABLE chunks(
     id INTEGER PRIMARY KEY,
     source INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
     kind TEXT NOT NULL,                 -- transcript | audio | note | passage | page
     track TEXT,                         -- microphone | system
     start_s REAL, end_s REAL,           -- seconds in meeting time (Segment.start/end); page for PDFs
     anchor_segment TEXT,                -- Segment.id to deep-link to
     segment_ids TEXT,                   -- JSON array of covered Segment.ids
     speaker_keys TEXT,                  -- JSON array of raw keys ("system:speaker-2"); names resolved at read time
     text TEXT,                          -- exactly what was embedded (NULL for audio)
     modality TEXT NOT NULL,             -- text | audio | none
     vec BLOB                            -- 768 × float16, L2-normalized (DigUp layout)
   );
   CREATE INDEX chunks_source ON chunks(source);
   CREATE VIRTUAL TABLE fts USING fts5(title, speakers, body,
     tokenize = "porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'");  -- rowid = chunks.id
   ```

3. **Chunking.** Walk `orderedSegments` and group consecutive segments into chunks of about 45–90 s or 1,200 characters, carrying one segment of overlap.
   - Embed `title: <meeting title> | text: <segment texts>` **without speaker names**, so renaming a voice never forces a re-embed.
   - Put the current display names (`Meeting.speakerName(for:)`) in `fts.speakers`, and rewrite only that column when `voiceRevision` changes.
   - Index a meeting when it's finalized. During recording, keep an in-memory index of the same shape for note linking and question cards.
4. **Search.** Use DigUp's z-score fusion over all vectors in the library, *then* filter by meeting or source switches, as `Searcher` does with `allowed`.
   - Change one thing: return the **top chunks, up to 3 per meeting**, not one per file.
   - Below a few hundred vectors the z-gate isn't meaningful. Fall back to a raw-cosine floor in that range.
   - Re-tune `zGate` and `wordWeight` on 20–30 real queries over our own meetings.
5. **Deep link in the UI.**
   - Add `focus: (meetingID, segmentID, seconds)` to `AppModel`. Selecting a result sets `selectedID` plus the focus.
   - `TranscriptView` tags rows with `.id(segment.id)`, calls `proxy.scrollTo(anchor_segment, anchor: .center)`, and highlights the chunk's segments.
   - For "play this moment", seek the track's WAV to `start_s − sourceOffsets[track]`.
   - Register a `workscribe://meeting/<uuid>?t=<seconds>&segment=<segment-id>` URL scheme (`CFBundleURLTypes` in the `build-app.sh` Info.plist, plus `.onOpenURL`) so MCP clients and notes can link back. None exists today.
6. **MCP.** Keep `search_transcripts` literal. Add `semantic_search(query, meeting_id?, limit≤50)`.
   - Each result is the existing `evidence()` shape plus `score`, `match` (`meaning` | `words` | `both`), `start_seconds`, `end_seconds`, the covered `segment_ids` and `link` (the URL above).
   - The `--mcp` process opens the index read-only and loads only the text encoder, lazily.
   - If the model or index is missing, return FTS-only results and set `"semantic": false` so the client knows.
7. **Knowledge base, later.** Reuse DigUp's `Extractors`, `Rules` and chunking for local files, as `sources.kind = 'file'`, keeping its rules for skipping secrets and caches.
8. **Notices.** Add DigUp's MIT notice for the copied files next to the existing `licenses/` entries, and verify the EmbeddingGemma 2 weight license before bundling.

**Blockers:**
- The runtime decision itself.
- If llama.cpp: a second llama.cpp build in a helper process, because the bundled NeMo copy can't load `gemma-embedding2`.
- No real-meeting eval set yet.

## Artifacts (outside the repo)

- Clone: `<research-workspace>/digup/src`, with built `digup` CLI and `Vendor/llama` b11461.
- PoC: corpus `<research-workspace>/digup/corpus/meeting.wav`, index `<research-workspace>/digup/idx`, comparison script `<research-workspace>/digup/scripts/compare.py`.
