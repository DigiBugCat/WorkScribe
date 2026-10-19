# On-device model integration

All production text jobs use Gemma 4 E4B through the resident llama.cpp engine: live/final jot enrichment, titles, answers, actions, and briefs. The generator GGUF and image projector revisions, byte sizes, and SHA-256 values are recorded in `Resources/runtime-downloads.json`. No cloud inference or alternative generator is installed.

`TextModels` shares the resident model by GGUF path. `ResidentTextModel` serializes requests, handles cancellation, and releases weights on idle or memory pressure. `LlamaTextEngine` caches fixed prompt-prefix state. The existing planner, retrieval policy, and scheduler are retained for the core rebuild; see [core-merge.md](core-merge.md) for their unresolved seams.

EmbeddingGemma 2 provides text/audio/vision embeddings. Nemotron handles streaming ASR and diarization; WeSpeaker embeds bounded live speaker samples. New recordings do not retain audio or run a second transcription pass. The separate E4B image-caption helper remains an architectural seam.

## Application verification

- `WorkScribe --eval-notes cases.jsonl --model gemma4-e4b --out notes.jsonl` exercises the app's retrieval, generation, and acceptance path. Add `--embed-cache cache.json` for vault fixtures and `--case id` to select a case.
- `WorkScribe --eval-retrieval cases.jsonl --embed-cache cache.json --tokenizer-gguf model.gguf --out retrieval.json` measures retrieval with llama.cpp token counts. `--fill-embed-cache cases.jsonl cache.json` builds a real EmbeddingGemma cache.
- `WorkScribe --measure-text-models transcript.json --backend llama --runs 5` measures the resident path and cached/uncached prefix behavior.
- `WorkScribe --eval-decisions rows.jsonl --task relevance --model-path model.gguf --out decisions.jsonl` evaluates the merged decision experiment. It does not change the production generator.
- `WorkScribe --verify-live-session fixture-directory` replays the capture/scheduler lifecycle. Fixture WAV input is distinct from production audio retention.

Use `WORKSCRIBE_TEXT_MODEL` for a local E4B GGUF override. The default comes from the runtime home. Run GPU/ANE verification serially. Model quality is evaluated separately from build, unit-test, and runtime measurements.

MLX, alternate Qwen/E2B generators, Apple Foundation Models, Dory, and the old raw-prompt/pipeline benchmark harness have been removed. Historical measurements belong to their original git revisions and must not be presented as measurements of this tree. Current merge/deletion verification is recorded in [core-merge.md](core-merge.md).
