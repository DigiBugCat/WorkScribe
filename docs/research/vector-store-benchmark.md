# Native vector store: design and measurements

Measured October 13, 2026 on this Mac: Apple M4 Max, 14 CPU cores, 36 GiB unified memory, macOS 26.5.1 (25F80), Swift 6.3.3. Release (`-O`) build. No external vector service.

## Decision

Use `MappedVectorStore` by default: normalized 256-dimensional Matryoshka prefixes, signed int8 values with a Float32 scale per vector, four CPU scan workers, and a bounded top-k heap. Retain the full 768-dimensional vectors as Float16 in SQLite for reranking and future retruncation. Embedding model identity stays unchanged by this storage migration.

USearch was evaluated at the interface/source level and **not adopted**. Its [Swift package](https://github.com/unum-cloud/USearch/blob/main/Package.swift) exposes the [native HNSW index and save/load/view API](https://github.com/unum-cloud/USearch/blob/main/swift/README.md); `view` supports mapped storage. It would add a C++/C dependency (current upstream also depends on NumKong), index-build cost, and approximate-neighbor tuning. The measured native scan stays below the requested 50 ms p95 gate at two million vectors, so there is no measured need to add that tier. An ANN implementation can conform to the same `VectorStore` interface if that gate is exceeded on the intended workload/hardware. No HNSW performance or recall numbers are claimed here.

## Storage, recovery, and execution

- `VectorStore` owns batch upsert, delete by chunk ID, filtered search, exclusive snapshots, checkpoint persistence, reset, compaction and stats. `SearchIndex` accepts an injected implementation. Metadata, FTS, full vectors and the change journal remain authoritative in SQLite.
- `index.sqlite.vectors` has a 64-byte versioned header and 320-byte records: chunk ID, numeric source ID, absolute start/end time, kind, modality, full dimension, Float32 scale, alive flag, reserved bytes, and 256 int8 values. The ID-to-slot dictionary is resident; vector values and metadata are mapped. A sidecar `flock` serializes cooperating app/MCP processes; a recursive process lock protects each mapping.
- Filters run before scoring: chunk kinds, numeric source IDs (including meeting IDs resolved by SQLite), and inclusive absolute interval overlap. Undated records do not match a time range. Time filtering is available in the core protocol; local HTTP API shapes are unchanged.
- Schema **v3**, after screen v2, adds Float16 format/dimension columns, a journal, namespace identity, and partial indexes for legacy conversion and calibration sampling. It does not collide with the vault's `IF NOT EXISTS` metadata table. Legacy Float32 blobs convert in 512-row transactions off the main thread, without re-embedding. A read-only v3 connection can read legacy blobs until the owning writer converts them.
- SQLite triggers journal inserts, deletes, vector/metadata changes and source-time changes. Synchronization replays bounded batches against one read snapshot; it handles deleted/reused IDs, flushes records before publishing its checkpoint, and replays after interruption. Database namespace mismatch, a journal cursor ahead of SQLite, or an invalid cache file rebuilds the accelerator from SQLite. Compaction copies live records to a synced temporary file and atomically renames it. More than max(4096, live/4) tombstones triggers compaction.
- Normal searches retrieve at least 200 compact candidates, then fetch full vectors for candidates, lexical matches and an independent 1024-row deterministic calibration sample. Full vectors are renormalized after Float16 decoding. The existing DigUp coverage fusion, small-index cosine gate and per-source result cap remain. Calibration is exhaustive for indexes up to 1024 vectors; larger-index z-scores are estimated from the sample, not from the top-k tail. Candidate selection can change large-index ranking/recall.
- App initialization/migration runs in a utility task; indexing/search run on `IndexService`, not the main actor. Recording pauses embedding and semantic retrieval; keyword retrieval remains available. Recording hardware was not exercised by this change.

The SQLite journal is retained to make a lost cache completely reconstructible; it grows with write history. Deleting the derived cache does not delete documents or full vectors. There is no new embedding runtime, download, or server.

## Method

Run the standalone core-only CLI, or the menu-bar app's matching flag:

```sh
swift build -c release --product WorkScribeVectorBench --scratch-path .build-vector-bench
.build-vector-bench/release/WorkScribeVectorBench --bench-vectors 2000000
# Repeat with 100000, 500000 and 1000000.
# The app's --bench-vectors also runs the small real-model check when installed.
.build-vectors/debug/WorkScribe --bench-real-vectors
```

The deterministic synthetic generator combines 128 random centers, 2048 subcluster directions and independent residual noise in 768 dimensions. Query IDs are outside the indexed IDs. This is a storage/selection stress fixture, **not a Matryoshka-trained model or a relevance benchmark**. Different corpus sizes cover different subclusters, so recall need not be monotonic in N.

Each size uses a fresh process and files. Build time includes synthetic vector generation, normalized-prefix quantization, writing the compact store, writing full reference vectors and synchronization; it is not embedding throughput or SQLite-ingestion time. The sizes ran sequentially under normal desktop conditions; the real-model fixture was also initializing during part of the run. One first scan warms the mapping. Then 30 queries measure SIMD and vDSP scan latencies separately; 10 queries also exhaustively scan the original 768-d Float32 reference for exact top-10 ground truth. The vDSP comparison converts eligible int8 rows into blocks of up to 128 Float32 vectors and calls `vDSP_mmul`; both kernels score the same quantized query. SIMD uses sign extension and Int32 accumulation without Int16 overflow.

`rerank` includes selecting 200 neighbors and reranking their Float16-rounded, renormalized full vectors. It excludes SQLite fetches, the calibration sample, FTS, and query embedding, so it is **not end-to-end app request latency**. Exact-reference time is a scalar row loop calling Accelerate; it is a truth oracle, not a claim about the fastest possible 768-d implementation. The same 200-candidate cap is used at all sizes.

Mapped MB is compact-file size. Warm store RSS is measured before mapping the full reference matrix and includes the harness, ID map and compact pages. Peak harness RSS additionally includes the full 768-d Float32 truth matrix (6.144 GB at 2M); it is not product vector-store memory. First scan covers page touches after build, not a reboot/cold-disk benchmark.

| Vectors | Build s | Mapped MB | Warm store RSS MB | SIMD p50 / p95 ms | Scan + f16 rerank p95 ms | Recall@10 |
|---:|---:|---:|---:|---:|---:|---:|
| 100,000 | 0.46 | 32.0 | 75.7 | 0.32 / 0.38 | 0.61 | 81% |
| 500,000 | 2.34 | 160.0 | 228.4 | 1.14 / 1.32 | 1.57 | 57% |
| 1,000,000 | 5.95 | 320.0 | 422.4 | 2.14 / 2.28 | 2.49 | 71% |
| 2,000,000 | 11.65 | 640.0 | 811.0 | 4.16 / 4.52 | 5.31 | 79% |

| Vectors | vDSP p50 / p95 ms | Exact 768-d p50 ms | First scan ms | Peak harness RSS MB |
|---:|---:|---:|---:|---:|
| 100,000 | 0.92 / 1.08 | 4.05 | 1.09 | 383.5 |
| 500,000 | 4.45 / 4.59 | 20.54 | 5.14 | 1765.0 |
| 1,000,000 | 8.73 / 8.94 | 41.49 | 7.79 | 3495.0 |
| 2,000,000 | 16.40 / 17.61 | 81.50 | 19.63 | 6801.4 |

The measured SIMD scan passes the 50 ms p95 gate at 2M with four workers. Synthetic recall loss is candidate selection from the 256-d prefix, not a failure of full-vector reranking: candidate recall@200 is also reported in the [raw results](vector-store-benchmark-results.json). The larger corpus is not the same query distribution as the smaller one, so the recall percentages are not a monotonic scaling curve.

Real model (`embeddinggemma-2-coreml/text@70fcf18f/768`), release app: **84.375% compact top-10 recall; 100% after Float16 reranking**, 64 passages and 16 queries. Mean compact scan time was **0.024 ms**, after embedding. A separate debug run returned the same recall.

## Quality and limits

Truncation and the bounded candidate pool can omit full-space neighbors. Exact reranking cannot recover a neighbor that never entered that pool; an ANN tier would not fix this. Larger candidate budgets or a different prefix dimension are quality/latency tradeoffs to evaluate on representative content. The synthetic percentages above are reported as measured, not promoted as production relevance.

The small real-model fixture uses only public, generated planning sentences (eight topics, eight variants each); it reads no user meetings, files or notes. Its 64-vector pool fits entirely in the rerank budget, so full-rerank recall validates the round trip but cannot establish million-vector candidate recall.

The existing tests plus `VectorStoreTests` cover normalization, per-coordinate quantization error, SIMD accumulator overflow, SIMD/vDSP parity, serial/parallel tie order, filters, empty filters, interval boundaries, undated data, overwrite/delete tombstones, compaction, persistence reload, cross-instance visibility, namespace reset, malformed-cache recovery, v2 migration, model-change invalidation, small-fixture old-ranking parity, and SQL plans that avoid full-table scans for legacy/calibration checks.

## Verification

`swift build --scratch-path .build-vectors` and `swift test --scratch-path .build-vectors` pass. **126 tests, zero failures**, including **11 vector-store tests**. Both the standalone benchmark and full app build successfully in release mode. Initial builds were retried after source changes; the final checks use the completed source. Existing upstream Swift concurrency/deprecation warnings remain.
