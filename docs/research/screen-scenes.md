# Screen scenes

## Status (2026-10-15)

The implementation and deterministic tests are complete. **Real-model calibration and the
requested CPU/GPU comparison remain unverified.** Core ML/IOSurface is unavailable in this execution environment:
Core ML cannot load the pinned vision graph, and Vision cannot create its image buffers.
The default cosine thresholds below are provisional, not fitted measurements. This is not a
claim that the real-call performance or scene-quality acceptance bar has been met.

## Implementation

`ScreenSceneDetector` replaces OCR-driven moment construction in the recorder. The existing
2.5-second pixel-difference gate admits EG2 vision samples. A normalized, bounded running
centroid represents the active scene. A candidate starts below cosine **0.88**; returning above
**0.92** cancels it. A new app is also a candidate. Confirmation requires at least two observations,
**5 seconds** of candidate dwell. The initially observed scene can be shorter if capture begins just before an app switch. At normal cadence that
usually takes three observations. Confirmed spans are backdated to the first candidate frame.
Transient menus and frame motion do not automatically create scenes. Blank/text-free scenes
remain searchable.

A scene keeps its representative's 768-d normalized embedding, model ID, app/window, time span,
480-pixel thumbnail and a readable JPEG. The most stable observed frame, measured by consecutive
pixel differences, replaces its representative. Only two candidate images remain in memory;
only accepted scenes are written. An on-demand OCR request freezes the representative. Existing
`ScreenMoment`, `screen-moments.json` and API event shapes remain backward compatible.

Closed scenes can receive one low-priority OCR attempt when load permits. Ask and note enhancement
can request text on demand; empty OCR is recorded too, avoiding repeated attempts. OCR uses the
readable JPEG, not the thumbnail. Calls are globally single-flight and never process every changed
frame. A model-load failure is retryable with a 30-second backoff; no per-frame OCR fallback is used.
Recording finalization invalidates late work rather than waiting indefinitely for a driver call.

Visual chunks and optional OCR chunks enter the existing **256-d Matryoshka candidate scan /
768-d rerank** path. Model-space mismatches cannot contaminate retrieval or evict current vectors.
Live Ask can rank current scene embeddings on demand; pressure suppresses query embedding too.
Selected scenes supply text to answers or note prompts without modifying user notes or transcript
excerpts. AI traces carry scene thumbnails and start/end times; the plugin uses its existing
keyboard-accessible moment renderer. A visual embedding is retrieval evidence, not a generated
caption: without OCR, the text model is explicitly told that scene text has not been read.

## Load and privacy

The existing realrun backlog levels drive screen work:

| Condition | Sampling | Embeddings | OCR |
| --- | --- | --- | --- |
| Normal / nominal thermal state | 2.5 s | Enabled, one at a time | Lazy, one globally |
| `screenPaused` (2 s audio lag), or fair thermals | 7.5 s | Enabled | Deferred |
| `aiPaused` (6 s lag), worse lag, serious/critical thermals | 7.5 s | Deferred | Deferred |

There is no queue of missed frames to replay. The first eligible frame after deferral is reconsidered
even if unchanged. Audio capture and transcription own the budget. Model/GPU work already inside
a driver cannot be preempted; late results are rejected after pause, app change, stop or pressure.

The deny list runs before embedding, with an additional foreground/lifecycle check after inference.
Private applications remain excluded from the captured video. Scene JPEGs, vectors, metadata and
OCR stay inside the meeting's raw-data lifetime: **24 hours / Done**. Deletion and scene writes share
a lock; OCR rechecks the durable retention receipt before committing, so a late completion cannot
recreate a purged folder. The index purge removes compact and full vectors. Saved vault attachments
retain their existing independent ownership rules.

## Fixtures and measurements

`--bench-scenes` renders five 60-second, 1200×750 timelines sampled at 2.5 seconds. The author-marked
boundaries are 20/40 seconds for a three-slide deck and three app switches; a scrolling document,
moving six-person call grid and moving game landscape each have no intended boundary. These are
controlled synthetic fixtures, **not recordings of real applications or hand-annotated calls**.
The first three calibrate a cosine sweep (0.75–0.985); the last two are held out. One-to-one boundary
matching allows ±2.5 seconds. The harness reports raw TP/FP/FN, compact+reranked semantic query
results, cold load separately, and process CPU / wall time for inference and the former OCR path.

The pixel gate alone was measured successfully, without model inference:

| Timeline | Sampled frames/min | Former OCR admissions/min | Intended scenes |
| --- | ---: | ---: | ---: |
| Slideshow | 24 | 3 | 3 |
| Scrolling document | 24 | 23 | 1 |
| Call grid | 24 | 16 | 1 |
| App switches | 24 | 3 | 3 |
| Game/stream | 24 | 24 | 1 |

These are actual pixel-gate admissions, not measured scene recall or predicted savings.
The quality/performance results are deliberately left unclaimed:

| Required measurement | Result here |
| --- | --- |
| EG2 scene precision / recall | Unavailable: Core ML graph loading failed |
| Meaning-query Recall@1 | Unavailable: no real scene/query vectors produced |
| New-vs-old successful OCR CPU seconds/min | Unavailable: Vision image-buffer creation failed |
| GPU cost/minute, concurrent-call transcript quality | Unmeasured; requires desktop hardware run |

Observed diagnostics include `IOSurfaceSharedEventAddEventListener failed: 10000003`, followed by
Core ML's misleading “functionName must be nil unless the model type is ML Program” message.
`MLModelAsset.functionNames` successfully reports `vision_70`, `vision_140`, `vision_280`, and the
compiled metadata identifies an ML Program. A CPU-only diagnostic also failed at IOSurface creation;
no CPU fallback benchmark is substituted for GPU measurements. Vision reported OSStatus **-6662**
creating a 1200×750 `420f` pixel buffer. All **69/69** attempted OCR reads returned empty text. Any timings from those failed calls measure error handling,
not OCR, and are excluded above. The older warm **0.162/0.163 s** results in
[image-understanding.md](image-understanding.md) are prior image-fixture measurements, not this
scene pipeline's performance.

## Verification and reproduction

New tests exercise dwell/backdating, transient cancellation, hysteresis, app boundaries, bounded
representatives, malformed vectors, freeze-on-read, pressure stages, no-OCR visual retrieval,
exactly-once lazy OCR, full/compact vector purge and deletion during an in-flight OCR request.
The preprocessing test checks the pinned graph's Float16 position contract. Plugin coverage preserves
thumbnail/time provenance without inventing OCR. Transcript and excerpt implementations were not changed.

Run from this worktree (models are prepared into this worktree, never the shared `.runtime` symlink):

```sh
swift test --disable-sandbox
python3 scripts/prepare-embedding-model.py --vision --output .artifacts/models/embeddinggemma-2-coreml
.build/debug/WorkScribe --bench-scenes .artifacts/models/embeddinggemma-2-coreml .artifacts/scene-benchmark
.build/debug/WorkScribe --bench-scenes .artifacts/models/embeddinggemma-2-coreml .artifacts/scene-benchmark --ocr-only
.build/debug/WorkScribe --verify-api
.build/debug/WorkScribe --verify-purge
.build/debug/WorkScribe --verify-screen 8
(cd obsidian-plugin && npm test && npm run build && npm run smoke)
(cd obsidian-plugin && WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test)
(cd obsidian-plugin && node dev/scene-trace-check.mjs)
```

`swift test` needs `--disable-sandbox` here because nested SwiftPM `sandbox-exec` is disallowed.
This does not remove the outer execution restrictions. `--verify-screen` now reports missing screen
permission explicitly instead of hanging inside `SCShareableContent`; it does not turn a missing
permission into capture proof. The trace browser script opens an isolated profile, asserts that the
thumbnail and `00:25` are visible, and presses Enter on the scene. Chrome aborted in this sandbox,
so no visual/interaction pass or watchcat result is claimed.

The checked-in [pixel-gate results](screen-scenes-pixel-gate.json) contain only the usable admission
counts; timings of failed OCR calls are deliberately excluded. Run the full benchmark on a permitted
Mac, replace the provisional thresholds from the calibration split, then repeat the held-out cases
and a combined ASR/diarization/LLM call before accepting the load-reduction claim.

Verification on macOS 26.5.1: **191 Swift tests**, **91 plugin tests** (89 pass / 2 real-API tests
skipped without the binary override; all 91 pass with it), plugin build and smoke, `--verify-api`,
and `--verify-purge`. `--verify-screen` exits cleanly with an explicit permission skip and empty
synthetic OCR in this environment; media validation remains blocked. One plugin timing assertion
failed while a concurrent native build was busy, then passed when checks ran sequentially.


## Desktop calibration run (2026-10-15, M4 Max, outside the sandbox)

`--bench-scenes` with the prepared Core ML models from `~/Library/Application Support/WorkScribe/Runtime`. Calibrated thresholds: start **0.91**, return **0.935** (now the defaults). Cold model load 18.1 s.

| Timeline | Marked | Detected | False | Old OCR CPU s/min | New OCR CPU s/min | Embedding wall s/min |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| slideshow | [20, 40] | [20, 40] | 0 | 0.52 | 0.48 | 1.11 |
| scrolling-document | [] | [] | 0 | 8.63 | 0.38 | 3.49 |
| call-grid | [] | [] | 0 | 2.63 | 0.16 | 2.42 |
| app-switches | [20, 40] | [20, 40] | 0 | 0.68 | 0.66 | 1.05 |
| game-stream | [] | [] | 0 | 2.63 | 0.10 | 3.61 |

Visual-only meaning search: **2/5** top-1 (synthetic fixtures; OCR text not yet included in this measurement). Still unmeasured: a real combined call (ASR + diarization + LLM + scenes) and real-app recordings.
