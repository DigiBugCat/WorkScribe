# EmbeddingGemma 2: native WorkScribe integration

Researched October 13, 2026. **Source** means inspected implementation/manifest; **Card** means upstream documentation or reported measurements, not independently benchmarked. **Recommendation** is proposed work. No models were executed.

## Runtime and dependency

**Source:** The wrapper is **FluidUse**, not FluidAudio: `EmbeddingGemma2Manager.loadDefault()` / `load(from:)`, `embed(_:prompt:)`, and `EmbeddingGemma2Audio.load(text:)` / `embed(window:)`. [Implementation directory](https://github.com/FluidInference/FluidUse/tree/d278e17df85e39e8c21bb64a467da81c39576fcd/Sources/FluidUse/EmbeddingGemma2).

FluidUse's [manifest](https://github.com/FluidInference/FluidUse/blob/d278e17df85e39e8c21bb64a467da81c39576fcd/Package.swift) specifies Swift tools 6.0, macOS 14, and FluidAudio ≥0.15.8. However, this model's loader explicitly requires **macOS 15 / iOS 18** for multifunction Core ML. Swift 6.0 implies Xcode 16 tooling; WorkScribe already requires Swift 6.2, ordinarily Xcode 26. Its deployment target remains macOS 14.

**Source:** [FluidUse v0.3.0](https://github.com/FluidInference/FluidUse/tree/v0.3.0/Sources/FluidUse) lacks these files; [FluidAudio v0.17.5](https://github.com/FluidInference/FluidAudio/tree/v0.17.5/Sources/FluidAudio) does too. Add the FluidUse product pinned to **`d278e17df85e39e8c21bb64a467da81c39576fcd`**; keep FluidAudio **exact 0.17.5**. No FluidAudio bump is required by the inspected manifest. Package resolution/build remains untested.

## Inputs, placement, size

**Source:** [Tokenizer](https://github.com/FluidInference/FluidUse/blob/d278e17df85e39e8c21bb64a467da81c39576fcd/Sources/FluidUse/EmbeddingGemma2/EmbeddingGemma2Tokenizer.swift) uses Gemma BPE, Unicode scalars, byte fallback, space→`▁`, and BOS/EOS. [Prompt enum](https://github.com/FluidInference/FluidUse/blob/d278e17df85e39e8c21bb64a467da81c39576fcd/Sources/FluidUse/EmbeddingGemma2/EmbeddingGemma2Types.swift) supplies `title: none | text: …` for documents and `task: search result | query: …` for queries. Default `.none` adds nothing: callers must choose explicitly.

**Source:** The manager memory-maps `embeddings.bf16`, converts token rows to floats, scales by √512, then supplies FP16 embeddings. Fixed buckets are **32/48/64/128/256/512 tokens**, including special tokens and prefixes; excess text is truncated. `pack_256` packs up to eight independent texts. Output is 768 dimensions. Text defaults to `.cpuAndNeuralEngine`.

**Source:** Audio defaults to `.cpuAndGPU`. It accepts mono Float PCM at **16 kHz**, splits recordings into **10-second** windows, and skips a trailing <0.5-second window when preceding windows exist. Each input is `[1,160160]`: 160 leading zeros plus ≤160,000 samples, right-padded. A `[1,1000]` frame mask accompanies it. The encoder computes log-mel internally, emits ≤250 soft tokens, then the text model embeds BOS/audio-start/tokens/audio-end/EOS through `embed_256`. This is semantic audio retrieval, not transcription. [Audio implementation](https://github.com/FluidInference/FluidUse/blob/d278e17df85e39e8c21bb64a467da81c39576fcd/Sources/FluidUse/EmbeddingGemma2/EmbeddingGemma2Audio.swift).

**Asset metadata:** Text package + BF16 table + tokenizer/config total **584.75 MB decimal (557.66 MiB)**; audio adds **587.88 MB (560.64 MiB)**, approximately **1.173 GB combined**. These are downloaded bytes, **not peak RAM**. Tokenizer dictionaries, Core ML allocations/activations, concurrent predictions and compilation caches add memory/disk overhead. No verified RSS figure exists here. [Files](https://huggingface.co/FluidInference/embeddinggemma-2-coreml/tree/main).

**Card:** On M5 Pro, text reportedly takes 2.6 ms at 32 tokens / 27.4 ms at 512; audio encoder 13.6 ms/window; first ANE specialization can take minutes. These are upstream hardware-specific results. The card declares Apache-2.0. [Model card](https://huggingface.co/FluidInference/embeddinggemma-2-coreml). FluidUse itself has an [Apache-2.0 license](https://github.com/FluidInference/FluidUse/blob/d278e17df85e39e8c21bb64a467da81c39576fcd/LICENSE).

## Alternatives

| Route | Source-verified scope and effort | Size / speed evidence |
|---|---|---|
| llama.cpp GGUF | Existing `CTextGeneration` only generates titles. Add an embedding context, pooling/normalization and C ABI. Verify bundled dylib supports the new architecture; headers alone prove nothing. Current upstream converts text **and** audio/vision projectors, so GGUF is not intrinsically text-only; media additionally requires `libmtmd` integration. | Q8 text **310 MB**, projector **555 MB**; BF16 text **558 MB**, projector **982 MB**. CPU/Metal, no ANE. No comparable local latency measured. |
| MLX Swift | Current source has `MLXEmbedders` text support and `MLXVLM.EmbeddingGemma2Embedding`, an actor accepting text/image/audio/video with lazy media loading. Native, medium integration effort; pin **`c53d7d480147684f42dac9d959f648dc35f021d0`**: inspected release **3.32.3 lacks it**. Manifest: macOS 14, Swift 6.2, MLX ~0.32.3. | Full 4-bit checkpoint weights **1.098 GB**, because media towers remain BF16. CPU/GPU; no ANE. Audio processor allows 30 seconds. No comparable Swift latency measured. |
| Anemll | Source runtime is a Python Core AI worker, not a Swift package. Text/image/audio towers exist, but native Swift requires a new host/runtime adapter. Highest integration effort. | Files total **1.492 GB**, including host table; text+host about **596 MB**. Card reports ~35 ms text and 45–60 ms audio end-to-end on M4 Pro, validated on macOS 27.x; not evidence for macOS 15 support. |

Sources: [llama conversion](https://github.com/ggml-org/llama.cpp/blob/091b6a7fc561b78da90a0ed2d524ec995458c657/conversion/gemma.py), [GGUF files](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/tree/main), [MLX Swift implementation](https://github.com/ml-explore/mlx-swift-lm/blob/c53d7d480147684f42dac9d959f648dc35f021d0/Libraries/MLXVLM/EmbeddingGemma2.swift), [MLX checkpoint card](https://huggingface.co/mlx-community/embeddinggemma-2-4bit), [Anemll worker](https://github.com/Anemll/anemll-embeddings/blob/deea287d8175300bd4b59dc7b734f24d58971f62/api/coreai_worker.py), [Anemll card](https://huggingface.co/anemll/anemll-embeddinggemma-2-ane).

## Storage and recommendation

**Recommendation:** Start with SQLite metadata/vector BLOBs plus **Accelerate cosine search**: normalized vectors need only dot products. 5,000×768 Float32 vectors occupy **15.36 MB**, small enough for a contiguous in-memory matrix. Add [FTS5 BM25](https://www.sqlite.org/fts5.html) and fuse lexical/vector ranks; preserve chunk IDs, file locations and transcript timestamps. Combine lexical and semantic retrieval while preserving source provenance. [Accelerate dot product](https://developer.apple.com/documentation/accelerate/vdsp_dotpr).

[sqlite-vec](https://github.com/asg017/sqlite-vec) is a later option for SQL filtering/KNN: pure C, no dependencies, but pre-v1. Its [source](https://github.com/asg017/sqlite-vec/blob/main/sqlite-vec.c) exposes `sqlite3_vec_init` and cosine distance; statically compile/register it with the app's SQLite rather than loading an external extension. It still needs corpus-scale measurement.

Use Core ML text first, gated to macOS 15; retain macOS 14 recording. Bundle pinned assets using the existing model-preparation/build pattern, load from an explicit resource URL, and optionally bundle audio separately. The upstream [store](https://github.com/FluidInference/FluidUse/blob/d278e17df85e39e8c21bb64a467da81c39576fcd/Sources/FluidUse/EmbeddingGemma2/EmbeddingGemma2ModelStore.swift) already pins revisions/checksums; avoid its default runtime-download path for an offline bundle.

Proposed Foundation-only contract in `WorkScribeCore`; implementation actor in `WorkScribe`:

```swift
enum TextRole: Sendable { case query, document(title: String?) }
protocol Embedder: Sendable {
    var modelID: String { get } // revision + dimension + preprocessing
    var dimension: Int { get }
    func text(_ value: String, role: TextRole) async throws -> [Float]
    // One nonempty mono 16-kHz window, at most 160,000 samples.
    func audio(_ pcm16k: [Float]) async throws -> [Float]
}
```

Chunk before embedding; cancel superseded live requests; return finite, normalized vectors. Keep semantic vectors separate from the existing 256-dimensional WeSpeaker identity profiles. Evaluate audio speaker identification independently before changing that system.
