#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime_home="${WORKSCRIBE_RUNTIME_HOME:-$HOME/Library/Application Support/WorkScribe/Runtime}"
repo=ggml-org/gemma-4-E4B-it-GGUF
revision=b8093469224f83f5c38f691eb906c380e9e63114
file=gemma-4-E4B-it-Q4_0.gguf
expected=a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2
mkdir -p "$runtime_home/models"
target="$runtime_home/models/$file"
if [ -f "$target" ] && [[ "$(stat -f %Sf "$target")" != *dataless* ]]; then
  actual="$(shasum -a 256 "$target" | awk '{print $1}')"
  if [ "$actual" = "$expected" ]; then printf 'Verified %s\n' "$target"; exit 0; fi
fi
curl --fail --location --retry 2 "https://huggingface.co/$repo/resolve/$revision/$file" -o "$target.partial"
actual="$(shasum -a 256 "$target.partial" | awk '{print $1}')"
if [ "$actual" != "$expected" ]; then echo 'Model checksum mismatch; existing model was not replaced.' >&2; exit 1; fi
mv "$target.partial" "$target"
printf 'Verified %s\n' "$target"
