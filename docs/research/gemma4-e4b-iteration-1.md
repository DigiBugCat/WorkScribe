# Gemma 4 E4B candidate, iteration 1

> Historical experiment. Its model-comparison/download harness has been retired. Use the current runtime doctor and in-app eval CLIs; the commands below require the original git revision.

This is an **opt-in experimental arm**. Application routing and all note prompts, token caps, planner logic, and gates remain unchanged. `--eval-notes --model gemma4-e4b` selects resident MLX provisionally. `--gemma-runtime llama` selects the comparison GGUF. A runtime winner has **not** been measured in this sandbox: the native Metal probe returns zero devices. Do not interpret the manifest's provisional MLX selection as a speed or quality result.

## Pinned local assets

`python3 scripts/prepare-e4b-benchmark.py mlx` and `... llama` download into `/private/tmp/claude-501/llm-models/`. Downloads are size/hash checked and refuse to cross 3 GiB free. Each directory has `receipt.json` with SHA-256 for every downloaded file. If both do not fit, `... mlx --remove-weights` removes only verified candidate weights and keeps its receipt and tokenizer/config files; the next download restores them.

| Runtime | Repository/revision | Weight file SHA-256 |
|---|---|---|
| MLX, affine 4-bit group 64 | [mlx-community/gemma-4-e4b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit/tree/475b9088d29754a3379866cf5aeb6b41acd313c2), `475b9088d29754a3379866cf5aeb6b41acd313c2` | `932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff` |
| llama.cpp, Q4_0 | [ggml-org/gemma-4-E4B-it-GGUF](https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/tree/b8093469224f83f5c38f691eb906c380e9e63114), `b8093469224f83f5c38f691eb906c380e9e63114` | `a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2` |

The app verifies the selected E4B weights before inference, plus MLX's config, tokenizer, and generation config. It never downloads models at runtime. MLX uses the existing pinned `mlx-swift-lm` 3.32.3 / `mlx-swift` 0.32.3 and its `Gemma4TextModel`, selecting the `language_model` tensors from the multimodal checkpoint. Audio and vision towers do not enter the forward pass. Actual weight loading, prefix-cache restoration, and GPU execution remain integration checks to run on a GPU-accessible host.

## Template and tokenizer

The pinned jinja file renders one user turn with `enable_thinking=false` as:

```text
<bos><|turn>user
{instruction}<turn|>
<|turn>model
```

MLX inserts BOS explicitly. The existing llama.cpp Gemma template omits it because llama.cpp's tokenizer adds BOS. Both use greedy decoding and the existing request limits and stop markers. MLX stops at the checkpoint's EOS IDs (1, 106, 50).

Gemma uses scalar BPE with space replacement and byte fallback, unlike Qwen's byte-level BPE. `GemmaBPETokenizer` keeps UTF-8 vocabulary keys exact: Swift canonical string equivalence can merge distinct vocabulary entries, and `JSONSerialization` loses a leading U+FEFF in merge values. The tokenizer reads raw vocabulary key literals and uses `JSONDecoder` for merges. Golden token IDs come from the local Hugging Face `tokenizers` library; E2B and E4B tokenizers have identical SHA-256.

## Reproduce

Build with `swift build --disable-sandbox -j 6` if the enclosing shell already has a sandbox. This does not grant GPU access. Run on an otherwise idle GPU, with other model servers stopped. Preserve the same binary across all measurements and evals.

```sh
# App-path live/final measurements (5 x 6 prompts of each kind), then ~450/~2000-token scaling probes.
python3 scripts/bench-llm/e4b-iteration.py --stage mlx --out-dir .artifacts/eval/e4b/gpu-mlx
python3 scripts/bench-llm/e4b-iteration.py --stage llama --out-dir .artifacts/eval/e4b/gpu-llama
python3 scripts/bench-llm/e4b-speed-table.py .artifacts/eval/e4b/gpu-mlx/*.speed.json .artifacts/eval/e4b/gpu-llama/*.speed.json

# After selecting the runtime from measurements, use mlx or llama below.
python3 scripts/bench-llm/e4b-iteration.py --stage eval --runtime mlx --out-dir .artifacts/eval/e4b/gpu-eval

# Explicit real-model test; otherwise this test skips.
WORKSCRIBE_TEST_E4B=1 swift test --disable-sandbox --filter GemmaEvaluationTests.testResidentGemmaPrefixRestoresExactly
```

The runner uses the reviewed `cases.v3.jsonl`, includes disputed cases, checks that all 12 cases are represented, and invokes the adjacent `score.v3.py`. It refuses to overwrite artifacts. No fallback cases file is needed when the reviewed file is readable. Individual measurements can also be selected with `WorkScribe --measure-text-models <transcript.json> --model qwen35-2b|gemma4-e2b-llama|gemma4-e2b-mlx|gemma4-e4b-mlx|gemma4-e4b-llama`.

Raw timings retain every cached and uncached sample. Live/final totals stop at WorkScribe's normal end marker; decode rate is `(generatedTokens - 1)/(totalMs - ttftMs)`. Synthetic scaling counts are calibrated separately for each tokenizer, targeting 450 and 2000 total prompt tokens, with 64-token decode caps. The table's prefill rate uses uncached prompt tokens divided by engine `prefillMs`, not total wall time; cached scaling stats are retained alongside it. Candidate measurements fail when Metal is unavailable to avoid reporting CPU fallback as GPU performance.

Before choosing GGUF, run a matching llama-bench build with `GGML_SCHED_DEBUG=2` and `-v`, and inspect scheduling: a CPU embedding lookup split is expected; CPU matrix blocks are not. This check remains unperformed here. Do not copy speed numbers from older E2B/Qwen runs into the matched table.
