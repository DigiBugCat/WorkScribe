# Images in the meeting note

## Decision and evidence

Use **Vision OCR first**, **Gemma 4 E2B + libmtmd for the image description**, and
**EmbeddingGemma 2 vision vectors together with OCR text vectors for retrieval**.
Everything runs on device. No runtime model downloads, external image fetches, or remote inference.

Measurements on this Mac: Apple M4 Max, 36 GiB RAM, macOS 26.5.1. Fixtures are synthetic
1200 × 750 screenshots: an iPhone launch trace and a marketing budget with similar chart layouts.
`scripts/make-image-fixtures.swift` recreates them. This is a small functional corpus, not a general
vision-quality benchmark. Machine activity and cold hardware compilation affect the first load.

| Path | Measured result | Decision |
| --- | --- | --- |
| Vision accurate OCR | 0.435 s first screenshot, 0.187 s second | Publish evidence immediately; it read all main labels and numbers. A spurious short glyph sequence from the chart demonstrates that OCR is fallible. |
| Gemma E2B Q4_0 + Q8 projector, isolated helper | 3.24 s including load and caption; 3.44 GB maximum RSS, 998 MB reported peak physical footprint | Use for image meaning. Correctly read 420 ms / 2,900 ms and the main-thread image-decode diagnosis. |
| EmbeddingGemma 2 vision_70 + text envelope | 18.578 s first hardware load; 0.162 / 0.163 s warm, 768 dimensions | Index in background, with OCR text. The combined image/OCR/query run reached 1.11 GB maximum RSS. Raw visual vectors alone got only 1/2 of the two similarly arranged screenshot queries right; the actual combined search path found the correct file for 2/2. |
| Existing speech-runtime note generator, image evidence supplied | 27.249 s first complete line; 22.729 s repeat | The old Metal runtime recompiles its attention kernels (14.851 s in repeat logs). Do not add that delay to image notes when the new helper is available. |
| Selected matched runtime: OCR → image caption → context-aware note | **4.803 s** to complete useful line, excluding scheduler; OCR at 0.411 s, caption at 3.614 s; 3.71 GB maximum RSS | Image-containing batches use the matched helper for text too. Plain-note batches retain their existing engine. |

The selected pipeline actually produced:

> **iPhone 12 mini launch:** Marcus walked through the chart, noting the high spike is the 12 mini
> stall during image decoding. A fix is needed to move image decode off the main thread.

The speaker and diagnosis came from the test transcript; the image supplied labels/values.
The normal editor sync (650 ms) and note scheduler (4 s debounce, 15 s throttle between passes)
are additional, overlapping costs; **4.803 s is not a measured paste-to-visible latency**.
OCR is published while the description is still running. A helper call has a deadline; failure
keeps OCR, then abstains if there is neither OCR nor image description. Finalization waits at
most five seconds for outstanding image work before using the evidence already available.

Full synthetic outputs are in `image-benchmarks/`. The standalone caption process was measured
with `/usr/bin/time -l`; RSS and physical footprint are different OS measurements. Embedding
cold startup also compiles the existing FluidUse text functions for query embedding; that cost
must not be mistaken for per-image inference.

## What was verified about the models

- The pre-existing CTextGeneration bridge and bundled speech SDK expose text generation only;
  they do not accept image pixels. The original model files in `.runtime/models` were iCloud
  placeholders (`dataless`, 0 allocated bytes), not usable local test models.
- A fresh, checksum-verified Gemma model and matching projector were tested with **libmtmd**,
  not a filename inserted into a text prompt. The helper tokenizes media, encodes image chunks,
  evaluates them against the language model, then decodes the response.
- llama.cpp is pinned to `e467e5b5e5ba43071d6151b3d881deb9300d000e`; model/projector are pinned
  to `ggml-org/gemma-4-E2B-it-GGUF@b4243c156154b6dca9324415f8c7ccc098b4aed1`, with hashes in
  `Resources/licenses/image-understanding/MODELS.json`. The helper's own matched dylibs avoid
  ABI collisions with the speech SDK's older llama runtime.
- FluidUse `d278e17` exposes text/audio but no image wrapper; the inspected newer HEAD also
  lacked the wrapper. The [Core ML model repository](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
  does provide vision functions and their input contract. `EmbeddingGemmaVision.swift` implements
  its patch/position/pool inputs and `<bos> <|image> tokens <image|> <eos>` envelope. Vision runs
  on GPU; the envelope runs through the same text model on ANE, producing the same 768-d space.
  Revision `3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4` and source hashes are pinned in the existing
  EmbeddingGemma model manifest. The chosen 70-token budget bounds background work; OCR keeps
  screenshot text searchable instead of relying only on low-resolution visual semantics.
- [Upstream Gemma GGUF](https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF) and
  [llama.cpp's multimodal API](https://github.com/ggml-org/llama.cpp/tree/e467e5b5e5ba43071d6151b3d881deb9300d000e/tools/mtmd)
  support the implementation. Upstream latency/accuracy claims are not our measurements.

## Ownership, editor behavior, and retention

`NoteDocument.Block.images` carries target/path references; the server derives them from source
and strips client-supplied derived data. Image-only paragraphs/list items have no shorthand.
Mixed blocks use the user's words as shorthand and the image as evidence. Direct wiki embeds,
inline Markdown images, and explicit reference-style Markdown images are recognized. Remote
and unsupported images remain editable image blocks but are not fetched or fabricated.

Images use the same block IDs, first-typed timestamps, ownership, undo/redo and finalization
mechanism as text. The model never rewrites the user's Markdown. Image evidence changes bump the
note revision, invalidating generation already in flight. Owned AI text stays owned. A missing,
changed, or unreadable image cannot inherit an unrelated old enhancement.

The new command **Grab this moment** has no default hotkey. It takes the current permitted frame
from the active screen-awareness recorder; a pause, private app, app switch before a new frame,
or stopped recorder prevents capture. It does not start a new screen-recording permission flow.
PNG encoding happens off the main actor. Obsidian chooses the attachment folder, resolves name
collisions and generates the link. The insertion point maps through edits during the request.
Undo removes the embed; the attachment remains ordinary user content, like an Obsidian paste.

Captions/OCR and image references in the meeting ledger disappear with meeting retention.
The in-memory analysis cache is bounded, cleared on purge, and protected against late repopulation.
Vault image files are never purged by meeting cleanup. The independent vault index holds OCR
and image vectors; a referencing note also holds image chunks so queries can find the screenshot
in a named meeting note. Image edits/deletion reindex those parent notes. These retained vectors
leave when the image/note is deleted or the vault is removed, rather than when a meeting expires.
Screen awareness now derives meeting-scoped scene vectors from ephemeral frames; those vectors are purged with raw meeting data. Saving an image into the vault still creates independently owned vault content. See [screen-scenes.md](screen-scenes.md) for the scene pipeline and its validation limits.

## Verification boundary

`swift test` passes 146 tests. `--verify-api`, `--verify-purge`, plugin tests/build/smoke and
`WORKSCRIBE_API_BINARY=../.build/debug/WorkScribe npm test` pass. New tests exercise image-only
and mixed blocks, reference images, identity/time preservation, stale-output invalidation,
source/derived separation, path/symlink confinement, retention, persistent image vectors,
parent-note refresh on image deletion, PNG decoding and the grab API contract.

`obsidian-plugin/dev/native-images-check.mjs` launches a fresh profile and disposable vault,
asserts its exact path before operating, and tests the real registered command. It passed:
no default hotkey; attachment in `Meetings/images/`; valid PNG; insertion point survives an
intervening edit before the cursor; image has its own ID and no shorthand; normal Undo removes
the embed while retaining the attachment. Its pixel fixture is synthetic and its screen API is
mocked. This is real Obsidian editing/attachment proof, **not** a physical ScreenCaptureKit or
privacy-permission exercise. Live recorder state/deny-list checks are enforced by the native
implementation; a physical call with screen recording remains a separate field check.

Watchcat reviewed the isolated-window recording: the chart appears after the intervening PREFIX edit; Undo removes the chart while PREFIX remains. It also observed the mock's ordinary AI-status updates. This short recording proves the sequence, not a general animation-performance bound.

The native script records frames of the isolated window for visual/temporal review. The user's
normal Obsidian profile, vault, meeting library and running WorkScribe instance are not fixtures.
All model downloads and generated captures for this task stayed in the worktree's ignored
`.artifacts/`; the shared `.runtime` was only linked/read, not replaced. Optional image model
assets still need the build-time preparation commands before packaging a release.

## Reproduce and bundle

```sh
# Build-time setup; runtime never downloads models.
scripts/prepare-embedding-model.py --vision
scripts/prepare-image-model.sh
swift test
mkdir -p .artifacts/fixtures
swift scripts/make-image-fixtures.swift .artifacts/fixtures
.build/debug/WorkScribe --verify-images .runtime/models/embeddinggemma-2-coreml .artifacts/fixtures/stall.png .artifacts/fixtures/budget.png
```

The image helper, its libraries/model/projector, and licenses are copied by `build-app.sh` when
prepared. `WORKSCRIBE_IMAGE_HELPER`, `WORKSCRIBE_IMAGE_MODEL`, and `WORKSCRIBE_IMAGE_PROJECTOR`
are development overrides; the embedding override remains `WORKSCRIBE_EMBEDDING_DIR`.
Missing assets give OCR-only behavior. Cloud placeholders are refused before image IO rather
than initiating an implicit download. The optional helper's subprocess is bounded to 20 seconds
for captions, 30 seconds for an image-containing note batch; source text crosses stdin, not argv.
