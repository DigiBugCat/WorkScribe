#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-qwen35}" in
  gemma4)
    repo=google/gemma-4-E2B-it-qat-q4_0-gguf
    revision=675cff42a74c774d6cb76f76d8eacb49b48c9b93
    file=gemma-4-E2B_q4_0-it.gguf
    expected=fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634
    ;;
  qwen35)
    repo=unsloth/Qwen3.5-2B-GGUF
    revision=f6d5376be1edb4d416d56da11e5397a961aca8ae
    file=Qwen3.5-2B-Q4_K_M.gguf
    expected=aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223
    ;;
  *) echo 'Usage: download-title-model.sh gemma4|qwen35' >&2; exit 2 ;;
esac
mkdir -p .runtime/models
target=".runtime/models/$file"
if [ -f "$target" ]; then
  actual="$(shasum -a 256 "$target" | awk '{print $1}')"
  if [ "$actual" = "$expected" ]; then printf 'Verified %s\n' "$target"; exit 0; fi
fi
curl --fail --location --retry 2 "https://huggingface.co/$repo/resolve/$revision/$file" -o "$target.partial"
actual="$(shasum -a 256 "$target.partial" | awk '{print $1}')"
if [ "$actual" != "$expected" ]; then echo 'Model checksum mismatch; existing model was not replaced.' >&2; exit 1; fi
mv "$target.partial" "$target"
printf 'Verified %s\n' "$target"
