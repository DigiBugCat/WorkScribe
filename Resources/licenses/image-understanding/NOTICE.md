# Image understanding

Image captions use Google DeepMind's Gemma 4 E2B Q4_0 + Q8 projector, converted
by ggml-org, under Apache-2.0. The [original model card](https://huggingface.co/google/gemma-4-E2B-it)
links the [Gemma 4 license](https://ai.google.dev/gemma/docs/gemma_4_license).
Full Apache terms: `../apache-2.0/LICENSE`. Unlike older Gemma generations,
this pinned Gemma 4 model is published under Apache-2.0.

The separate llama.cpp/libmtmd helper is MIT-licensed, built from commit
`e467e5b5e5ba43071d6151b3d881deb9300d000e`; full terms: `../llama.cpp/LICENSE`.
It isolates its llama ABI from the speech runtime. Pinned model revisions and
hashes are in `MODELS.json`. Vision embeddings use the Apache-2.0 EmbeddingGemma
2 conversion, with separate pins in `../embeddinggemma2/MODEL-SHA256.json`.
