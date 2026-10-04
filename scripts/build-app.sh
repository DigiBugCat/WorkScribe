#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
plaud_frameworks="${WORKSCRIBE_PLAUD_FRAMEWORKS:-$HOME/Library/Caches/WorkScribe/PlaudNativeLab/Frameworks}"
if [ ! -d "$plaud_frameworks/PlaudBleSDK.framework" ]; then
  echo 'Build the native Plaud frameworks first; see experiments/plaud-macos/README.md.' >&2
  exit 1
fi
swift build -c release
stage="$(mktemp -d "${TMPDIR:-/tmp}/workscribe-build.XXXXXX")"
app="$stage/WorkScribe.app"
output_dir="${WORKSCRIBE_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Models" "$app/Contents/Frameworks"
cp .build/release/WorkScribe "$app/Contents/MacOS/WorkScribe"
if [ ! -x .runtime/nemo/bin/nemo-speech ]; then
  echo 'Missing .runtime/nemo. Install the NVIDIA runtime first (see README).' >&2
  exit 1
fi
ditto .runtime/nemo/lib "$app/Contents/Frameworks"
ditto "$plaud_frameworks/PlaudBleSDK.framework" "$app/Contents/Frameworks/PlaudBleSDK.framework"
ditto "$plaud_frameworks/PlaudDeviceBasicSDK.framework" "$app/Contents/Frameworks/PlaudDeviceBasicSDK.framework"
install_name_tool -delete_rpath "$plaud_frameworks" "$app/Contents/MacOS/WorkScribe"
ditto .runtime/nemo/share/licenses "$app/Contents/Resources/licenses"
install_name_tool -delete_rpath "$PWD/.runtime/nemo/lib" "$app/Contents/MacOS/WorkScribe"
asr_cache="$HOME/Library/Caches/NeMoSpeech/models/nvidia/nemotron-3.5-asr-streaming-0.6b/1c8deaecc64b91f034d73e08dd8b64625eb3395d"
diar_cache="$HOME/Library/Caches/NeMoSpeech/models/nvidia/Nemotron-3-Diarization/f667ed73aee57d40cc39428eb768b4fd87a0a29e"
cp -c "$asr_cache/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf" "$app/Contents/Resources/Models/"
cp -c "$diar_cache/Nemotron-3-Diarization.q8_0.gguf" "$app/Contents/Resources/Models/"
title_model="${WORKSCRIBE_TITLE_MODEL:-qwen35}"
case "$title_model" in
  gemma4) title_file=gemma-4-E2B_q4_0-it.gguf ;;
  qwen35) title_file=Qwen3.5-2B-Q4_K_M.gguf ;;
  *) echo 'WORKSCRIBE_TITLE_MODEL must be gemma4 or qwen35' >&2; exit 1 ;;
esac
ditto .runtime/models/wespeaker_v2.mlmodelc "$app/Contents/Resources/Models/wespeaker_v2.mlmodelc"
ditto Resources/licenses/fluidaudio "$app/Contents/Resources/licenses/fluidaudio"
cp .build/checkouts/FluidAudio/LICENSE "$app/Contents/Resources/licenses/fluidaudio/FluidAudio-LICENSE"
for resource_bundle in .build/release/FluidAudio_*.bundle; do
  [ ! -d "$resource_bundle" ] || ditto "$resource_bundle" "$app/Contents/Resources/$(basename "$resource_bundle")"
done
cp -c ".runtime/models/$title_file" "$app/Contents/Resources/Models/"
printf '%s\n' "$title_model" > "$app/Contents/Resources/title-model.txt"
mkdir -p "$app/Contents/Resources/licenses/title-model"
cp Sources/CTextGeneration/vendor/LICENSE "$app/Contents/Resources/licenses/title-model/llama.cpp-LICENSE"
cp Sources/CTextGeneration/vendor/MODEL-LICENSE-2.0.txt Sources/CTextGeneration/vendor/MODEL-NOTICE.txt "$app/Contents/Resources/licenses/title-model/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.workscribe.app</string>
<key>CFBundleName</key><string>WorkScribe</string>
<key>CFBundleExecutable</key><string>WorkScribe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMicrophoneUsageDescription</key><string>WorkScribe records your microphone for local meeting transcription.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>WorkScribe saves your Plaud recordings and releases the recorder when you choose to move it to the Plaud iPhone app.</string>
<key>NSScreenCaptureUsageDescription</key><string>WorkScribe captures system audio to transcribe meeting participants playing through your Mac.</string>
</dict></plist>
PLIST
chmod -R u+w "$app"
xattr -cr "$app"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$output_dir"
if [ -e "$output_dir/WorkScribe.app" ]; then
  mv "$output_dir/WorkScribe.app" "$stage/previous.app"
fi
mv "$app" "$output_dir/WorkScribe.app"
printf 'Built %s/WorkScribe.app\n' "$output_dir"
