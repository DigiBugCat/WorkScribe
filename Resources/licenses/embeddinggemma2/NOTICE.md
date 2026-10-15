# EmbeddingGemma 2 (Core ML)

[Google's EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) and
[FluidInference's Core ML conversions](https://huggingface.co/FluidInference/embeddinggemma-2-coreml)
are published as Apache-2.0. Full terms: `../apache-2.0/LICENSE`.
Google DeepMind created the original model; FluidInference converted its text,
audio and vision encoders to Core ML. WorkScribe compiles the pinned packages
locally without changing their parameters.

FluidUse (Apache-2.0, full text in `FluidUse-LICENSE`) is pinned to
`d278e17df85e39e8c21bb64a467da81c39576fcd`. Model revisions and all source-file
SHA-256 values are in `MODEL-SHA256.json`. The prepared models remain in
`WORKSCRIBE_RUNTIME_HOME/models/embeddinggemma-2-coreml`, outside the app bundle.
