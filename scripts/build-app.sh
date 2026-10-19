#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
runtime_home="${WORKSCRIBE_RUNTIME_HOME:-$HOME/Library/Application Support/WorkScribe/Runtime}"
export WORKSCRIBE_RUNTIME_HOME="$runtime_home"
plaud_frameworks="${WORKSCRIBE_PLAUD_FRAMEWORKS:-$HOME/Library/Caches/WorkScribe/PlaudNativeLab/Frameworks}"
if [ "${WORKSCRIBE_PLAUD:-0}" = 1 ] && { [ ! -d "$plaud_frameworks/PlaudBleSDK.framework" ] || [ ! -d "$plaud_frameworks/PlaudDeviceBasicSDK.framework" ]; }; then
  echo 'Build the native Plaud frameworks first; see experiments/plaud-macos/README.md.' >&2
  exit 1
fi
python3 scripts/runtime-doctor.py
swift_flags=()
[ "${WORKSCRIBE_SWIFT_DISABLE_SANDBOX:-0}" != 1 ] || swift_flags+=(--disable-sandbox)
swift build ${swift_flags[@]+"${swift_flags[@]}"} --cache-path "${WORKSCRIBE_SWIFTPM_CACHE:-$PWD/.swiftpm-cache}" -c release
stage="$(mktemp -d "${TMPDIR:-/tmp}/workscribe-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/WorkScribe.app"
output_dir="${WORKSCRIBE_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Models" "$app/Contents/Frameworks"
cp .build/release/WorkScribe "$app/Contents/MacOS/WorkScribe"
# App icon; rebuild both with Resources/AppIcon/tools/build.py. Assets.car is the
# Liquid Glass icon macOS 26 prefers (CFBundleIconName); AppIcon.icns is the fallback.
cp Resources/AppIcon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/AppIcon/Assets.car "$app/Contents/Resources/Assets.car"
cp Sources/WorkScribeCore/Resources/decision-head.json "$app/Contents/Resources/decision-head.json"
# Browser clip extension's native-messaging host (extras/chrome-extension/install-native-host.sh registers it).
mkdir -p "$app/Contents/Helpers"
cp .build/release/WorkScribeNativeHost "$app/Contents/Helpers/WorkScribeNativeHost"
if [ ! -x "$runtime_home/nemo"/bin/nemo-speech ]; then
  echo "Missing $runtime_home/nemo. Run python3 scripts/runtime-doctor.py." >&2
  exit 1
fi
ditto "$runtime_home/nemo"/lib "$app/Contents/Frameworks"
if [ "${WORKSCRIBE_PLAUD:-0}" = 1 ]; then
ditto "$plaud_frameworks/PlaudBleSDK.framework" "$app/Contents/Frameworks/PlaudBleSDK.framework"
ditto "$plaud_frameworks/PlaudDeviceBasicSDK.framework" "$app/Contents/Frameworks/PlaudDeviceBasicSDK.framework"
install_name_tool -delete_rpath "$plaud_frameworks" "$app/Contents/MacOS/WorkScribe"
fi
ditto "$runtime_home/nemo"/share/licenses "$app/Contents/Resources/licenses"
install_name_tool -delete_rpath "$runtime_home/nemo/lib" "$app/Contents/MacOS/WorkScribe"
title_model=gemma4
ditto Resources/licenses "$app/Contents/Resources/licenses"
ditto Resources/licenses/fluidaudio "$app/Contents/Resources/licenses/fluidaudio"
cp .build/checkouts/FluidAudio/LICENSE "$app/Contents/Resources/licenses/fluidaudio/FluidAudio-LICENSE"
for resource_bundle in .build/release/FluidAudio_*.bundle .build/release/FluidUse_*.bundle; do
  [ ! -d "$resource_bundle" ] || ditto "$resource_bundle" "$app/Contents/Resources/$(basename "$resource_bundle")"
done
# Models stay in the non-synced runtime home. The app carries repair metadata/scripts.
mkdir -p "$app/Contents/Resources/runtime/scripts" "$app/Contents/Resources/runtime/Resources"
cp scripts/runtime-doctor.py scripts/runtime_home.py scripts/runtime_doctor_download.py scripts/prepare-embedding-model.py scripts/prepare-image-model.sh scripts/download-title-model.sh scripts/image-caption.cpp scripts/cmake-requirements.txt "$app/Contents/Resources/runtime/scripts/"
ditto Resources/licenses "$app/Contents/Resources/runtime/Resources/licenses"
ditto Resources/licenses/image-understanding "$app/Contents/Resources/licenses/image-understanding"
ditto Resources/licenses/embeddinggemma2 "$app/Contents/Resources/licenses/embeddinggemma2"
ditto Resources/licenses/digup "$app/Contents/Resources/licenses/digup"
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
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>local.workscribe.link</string>
  <key>CFBundleURLSchemes</key><array><string>workscribe</string></array>
</dict></array>
<key>NSMicrophoneUsageDescription</key><string>WorkScribe records your microphone for local meeting transcription.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>WorkScribe saves your Plaud recordings and releases the recorder when you choose to move it to the Plaud iPhone app.</string>
<key>NSScreenCaptureUsageDescription</key><string>WorkScribe captures system audio to transcribe meeting participants playing through your Mac.</string>
</dict></plist>
PLIST
if [ "${WORKSCRIBE_PLAUD:-0}" != 1 ]; then
  /usr/libexec/PlistBuddy -c 'Delete :NSBluetoothAlwaysUsageDescription' "$app/Contents/Info.plist"
fi
chmod -R u+w "$app"
xattr -cr "$app"
# A stable identity keeps macOS privacy grants (microphone, system audio) across rebuilds;
# ad-hoc signatures change every build and silently invalidate them.
sign_identity="${WORKSCRIBE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --deep --sign "${sign_identity:--}" "$app"
printf 'Signed with %s\n' "${sign_identity:-ad hoc (privacy grants reset on every build)}"
codesign --verify --deep --strict "$app"
mkdir -p "$output_dir"
if [ -e "$output_dir/WorkScribe.app" ]; then
  mv "$output_dir/WorkScribe.app" "$stage/previous.app"
fi
mv "$app" "$output_dir/WorkScribe.app"
printf 'Built %s/WorkScribe.app\n' "$output_dir"
