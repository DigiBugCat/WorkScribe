# Iteration 4 decision stage

This is an opt-in experiment. The default application behavior is unchanged. All inference is local; Gemma 4 E4B remains the only product generator. The typed classifiers and Clef are benchmark candidates, not product generators.

## Reproduce

```sh
python3 -m venv /private/tmp/ws-decision-venv
/private/tmp/ws-decision-venv/bin/pip install -r scripts/decision-requirements.txt

/private/tmp/ws-decision-venv/bin/python scripts/bench-decision.py \
  --cases /private/tmp/claude-501/ws-intel/.artifacts/eval/takeover/reviewed/cases.v3.jsonl \
  --cache /private/tmp/claude-501/handoffs/e4b/embeddings-3.json \
  --out .artifacts/decision/bench

/private/tmp/ws-decision-venv/bin/python scripts/run-typed-decision.py \
  --model mrm8488 --data .artifacts/decision/bench \
  --out .artifacts/decision/mrm8488-results.jsonl
/private/tmp/ws-decision-venv/bin/python scripts/run-typed-decision.py \
  --model danny-hybrid --data .artifacts/decision/bench \
  --out .artifacts/decision/danny-hybrid-results.jsonl

git clone https://github.com/ankit-aglawe/tinyjev /private/tmp/ws-decision-tiny-code
git -C /private/tmp/ws-decision-tiny-code checkout fec868b6b44ac5fddac64ff87d318ccceaff27ea
/private/tmp/ws-decision-venv/bin/python scripts/run-typed-decision.py \
  --model tiny --tiny-code /private/tmp/ws-decision-tiny-code \
  --data .artifacts/decision/bench --out .artifacts/decision/tiny-results.jsonl

# Repeat for mrm8488, danny-hybrid, tiny. Rejects missing rows rather than reporting a partial cohort.
/private/tmp/ws-decision-venv/bin/python scripts/score-decision-results.py \
  --data .artifacts/decision/bench --receipts .artifacts/decision/mrm8488-results.jsonl \
  --out .artifacts/decision/mrm8488-scored.json
```

The runner pins weights by revision, forces CPU, and downloads text checkpoints totaling below 2 GB per candidate. `danny-hybrid` uses the full joint/long-context text router; `danny` is the joint-only ablation. It records per-row latency and process peak RSS. Existing receipts resume at the next unscored row. Do not combine receipts from a changed dataset or prompt; alignment validation is required before scoring.

## Dataset and interpretation

Final-meeting context, raw transcript segments, raw jots. Per jot: top 12 cosine hits union top 12 BM25 hits; stable transcript-order ties. BM25 uses per-meeting document frequencies, k1=1.2, b=0.75. Relevance positives are the rubric's gold segment IDs. Gold segments missed by retrieval are added only to the relevance classification dataset. Answerability sees the unmodified retrieved candidates, never gold-augmented candidates. Positives are non-abstain jots; negatives are abstain jots.

This treats non-gold retrieved segments as hard negatives. The rubric may omit useful contextual segments, so this is agreement with the rubric's evidence IDs, not exhaustive human relevance annotation. Missing gold evidence in the answerability candidate set is reported separately. No live-horizon result is claimed.

Every reported prediction is out of fold by case. Standardization, fitting and temperature selection exclude the outer case. Temperature uses inner leave-one-case-out predictions from the remaining cases. No in-sample quality row is reported. ECE uses ten fixed equal-width probability bins; Brier is binary squared error. Accuracy uses 0.5. The optional recall-oriented relevance operating point chooses its cutoff from the inner calibration set, targeting 98% positive retention; held-out retention can differ.

Candidates: fixed C=0.1 logistic regression and fixed 16-unit, alpha=10, max-250-iteration MLP, each with either six inexpensive features or those features plus elementwise query/document product and absolute difference (768 dimensions each). The models were not hyperparameter-tuned. Cheap relevance features: cosine, capped time gap / 600 seconds, preceding transcript speaker change, query token coverage, Jaccard overlap, log(1 + word count). Answerability: maximum and top-three mean cosine, maximum and union query coverage, maximum Jaccard, minimum time gap, and log(1 + candidate count). The JSON head stores standardization, coefficients, bias and temperature; it never contains labels or case IDs.

A final head trained on all 12 cases is a deployment candidate, not an additional held-out score. Selecting a model after comparing these 12-case scores also needs a fresh note evaluation before promotion.

## Native seams

`DecisionModel` exposes relevance and answerability probabilities. `EmbeddingDecisionModel` runs a tiny CPU logistic head on the existing embedding cache. `NotePlanner` filters each jot's own refs and preserves source IDs; `NoteEnhancer` checks answerability before generation and uses the existing empty-evidence path to preserve unsupported jots. Images bypass this text-only gate. Errors and malformed probabilities are not silently treated as negative decisions.

Set `WORKSCRIBE_DECISION_MODEL` to an exported model JSON to opt in. With no variable and no injected model, there is no decision inference. `WORKSCRIBE_RETRIEVAL_CONFIG` still selects the retrieval policy. The decision model independently requires raw-jot and candidate embeddings even if retrieval is lexical. Grouping or retrieval changes shift the classifier's input distribution and require evaluation.

`ws_session_score_options` and `LlamaTextEngine.scoreOptions` expose full-vocabulary log probabilities of fixed single-token options. Both share generation's exact prefill/prefix-cache implementation. Options are checked for distinct single-token encodings. There is no sampler and no autoregressive output decoding. Requests are submitted in batches but evaluated serially in the resident context, reusing the instruction-prefix state. This is not parallel multi-sequence GPU decoding. The CLI records token counts, cache reuse, per-row latency and zero generated tokens.

## GPU checks for the orchestrator

The E4B GGUF is the existing runtime model. Run from this clone; do not download another model.

```sh
swift build --disable-sandbox --scratch-path .build-codex -j 2
# Set this to the existing runtime E4B GGUF if the runtime home is customized.
E4B_GGUF="/private/tmp/claude-501/llm-models/gemma-4-e4b-gguf/gemma-4-E4B-it-Q4_0.gguf"
WORKSCRIBE_TEST_GEMMA4="$E4B_GGUF" swift test --disable-sandbox --scratch-path .build-codex -j 2 --filter DecisionScoringTests

/usr/bin/time -l .build-codex/debug/WorkScribe --eval-decisions .artifacts/decision/bench/relevance.jsonl \
  --task relevance --model-path "$E4B_GGUF" --batch-size 16 --out .artifacts/decision/e4b-relevance.jsonl
/usr/bin/time -l .build-codex/debug/WorkScribe --eval-decisions .artifacts/decision/bench/answerability.jsonl \
  --task answerability --model-path "$E4B_GGUF" --batch-size 16 --out .artifacts/decision/e4b-answerability.jsonl
cat .artifacts/decision/e4b-relevance.jsonl .artifacts/decision/e4b-answerability.jsonl > .artifacts/decision/e4b-results.jsonl
/private/tmp/ws-decision-venv/bin/python scripts/score-decision-results.py \
  --data .artifacts/decision/bench --receipts .artifacts/decision/e4b-results.jsonl \
  --out .artifacts/decision/e4b-scored.json

WORKSCRIBE_DECISION_MODEL="$PWD/docs/research/decision-stage/logistic.json" \
  .build-codex/debug/WorkScribe --eval-notes \
  /private/tmp/claude-501/ws-intel/.artifacts/eval/takeover/reviewed/cases.v3.jsonl \
  --model gemma4-e4b --include-disputed --out .artifacts/decision/notes-with-decision.jsonl
```

Run an otherwise identical note evaluation without the variable. Compare per-note factual/abstention failures, evidence recall, usable-line rate and time to usable line. Classifier accuracy alone does not justify promotion.

## Clef ceiling (not downloaded)

The pinned full checkpoint has ~19.06 GB of tensor files including its joint head. This exceeds the shared-disk download boundary. On an independently provisioned CUDA host with sufficient space, the following is the complete benchmark command. It is an optional quality ceiling, not authorization to download it here.

```sh
hf download Cloudflare/clef-flash --revision 8b2e5fd17c09fd49bc2880b805d5323ec7ff4ff3 --local-dir /models/clef-flash
python scripts/run-clef-decision.py --checkpoint /models/clef-flash \
  --data .artifacts/decision/bench --out .artifacts/decision/clef-results.jsonl
python scripts/score-decision-results.py --data .artifacts/decision/bench \
  --receipts .artifacts/decision/clef-results.jsonl --out .artifacts/decision/clef-scored.json
```
