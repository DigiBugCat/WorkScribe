#!/bin/bash
# Optional, build-time only. A separate helper isolates libmtmd from the speech SDK's llama ABI.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=e467e5b5e5ba43071d6151b3d881deb9300d000e
model_revision=b8093469224f83f5c38f691eb906c380e9e63114
runtime_home="${WORKSCRIBE_RUNTIME_HOME:-$HOME/Library/Application Support/WorkScribe/Runtime}"
work="${WORKSCRIBE_RUNTIME_CACHE:-$HOME/Library/Caches/WorkScribe/Runtime}/image-build"
output=${WORKSCRIBE_IMAGE_RUNTIME:-$runtime_home/models/vision}
mkdir -p "$work" "$output/bin" "$output/lib"
if [ ! -d "$work/llama.cpp/.git" ]; then git clone --filter=blob:none https://github.com/ggml-org/llama.cpp.git "$work/llama.cpp"; fi
git -C "$work/llama.cpp" checkout "$revision"
# Keep the build tool out of the system installation too.
cmake_bin="$(command -v cmake || true)"
if [ -z "$cmake_bin" ]; then
  python3 -m venv "$work/tools"
  "$work/tools/bin/python" -m pip install --disable-pip-version-check --require-hashes -r scripts/cmake-requirements.txt
  cmake_bin="$work/tools/bin/cmake"
fi
"$cmake_bin" -S "$work/llama.cpp" -B "$work/build" -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF
"$cmake_bin" --build "$work/build" --target mtmd -j 4
clang++ -std=c++17 -O2 scripts/image-caption.cpp -I"$work/llama.cpp/include" -I"$work/llama.cpp/ggml/include" -I"$work/llama.cpp/tools/mtmd" -L"$work/build/bin" -lllama -lmtmd -Wl,-rpath,@executable_path/../lib -o "$output/bin/image-caption"
cp -R "$work/build/bin/"*.dylib "$output/lib/"
fetch() {
  local file="$1" expected="$2" target="$output/$1"
  if [ -f "$target" ] && [[ "$(stat -f %Sf "$target")" != *dataless* ]] && [ "$(shasum -a 256 "$target" | awk '{print $1}')" = "$expected" ]; then return; fi
  curl -fL "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/$model_revision/$file" -o "$target.partial"
  echo "$expected  $target.partial" | shasum -a 256 -c -
  mv "$target.partial" "$target"
}
fetch mmproj-gemma-4-E4B-it-Q8_0.gguf 197f49a93027f9843772bd24a6a9e0be2a32a788de5a3def330e9c585d86edd1
bash scripts/download-title-model.sh
cp "$work/llama.cpp/LICENSE" "$output/LICENSE-llama.cpp"
codesign --force --sign - "$output/bin/image-caption"
echo "Prepared $output at llama.cpp $revision; bundle it with a fully downloaded Gemma 4 E4B Q4_0 model."
