#!/bin/bash
# One-time public-source setup. Safe to rerun after interruption.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { printf '\nSetup needs attention: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'WorkScribe requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'WorkScribe requires an Apple Silicon Mac (run Terminal natively, not under Rosetta).'
macos="$(sw_vers -productVersion)"
[ "${macos%%.*}" -ge 26 ] || fail "macOS 26 or newer is required; found $macos."
for tool in git xcrun swift python3 node npm; do
  command -v "$tool" >/dev/null || fail "Missing $tool. See README.md → Requirements."
done
xcrun --find coremlcompiler >/dev/null 2>&1 || fail 'Install full Xcode 26+, open it once, and select it with sudo xcode-select -s /Applications/Xcode.app/Contents/Developer.'
xcode_version="$(xcodebuild -version 2>/dev/null)" || fail 'Xcode is not ready. Open it once to finish setup and accept its license.'
swift_version="$(swift --version | head -n 1)"
python3 - "$swift_version" "$xcode_version" <<'PY'
import re, sys
xcode = re.search(r'Xcode (\d+)', sys.argv[2])
if not xcode or int(xcode.group(1)) < 26:
    sys.exit('Setup needs full Xcode 26 or newer. Found: ' + sys.argv[2])
v = re.search(r'Swift version (\d+)\.(\d+)', sys.argv[1])
if not v or tuple(map(int, v.groups())) < (6, 2):
    sys.exit('Setup needs Swift 6.2+ from Xcode 26+. Found: ' + sys.argv[1])
if sys.version_info < (3, 12):
    sys.exit('Setup needs Python 3.12+. Install it and put python3 on PATH.')
PY
node -e 'if (+process.versions.node.split(".")[0] < 22) { console.error("Setup needs Node.js 22+."); process.exit(1); }'
export WORKSCRIBE_RUNTIME_HOME="${WORKSCRIBE_RUNTIME_HOME:-$HOME/Library/Application Support/WorkScribe/Runtime}"
export WORKSCRIBE_RUNTIME_CACHE="${WORKSCRIBE_RUNTIME_CACHE:-$HOME/Library/Caches/WorkScribe/Runtime}"
python3 - "$WORKSCRIBE_RUNTIME_HOME" "$WORKSCRIBE_RUNTIME_CACHE" "$PWD" <<'PYTHON'
import json, pathlib, shutil, sys
sys.path.insert(0, 'scripts')
from runtime_home import state
home = pathlib.Path(sys.argv[1]).expanduser()
missing = 0
for item in json.loads(pathlib.Path('Resources/runtime-downloads.json').read_text()):
    name = item['path']
    if '.mlpackage/' in name:
        compiled = home / (name.split('.mlpackage/')[0] + '.mlmodelc')
        if state(compiled) == 'present': continue
    target = home / name
    if state(target, item['sha256'] if not name.endswith('/') else None) != 'present':
        missing += item['bytes']
# Native/Core ML compilation, dependencies, debug + release build workspace.
required = 6 + missing / 1024**3
for target in sys.argv[1:]:
    p = pathlib.Path(target).expanduser()
    while not p.exists(): p = p.parent
    free = shutil.disk_usage(p).free / 1024**3
    print(f'Disk at {p}: {free:.1f} GiB free; need about {required:.1f} GiB including missing assets')
    if free < required:
        sys.exit('Not enough disk space for remaining setup. Free space and rerun; completed downloads are preserved.')
PYTHON
printf '%s\n' "$xcode_version"
printf 'macOS %s · %s · Python %s · Node %s\n' "$macos" "$swift_version" "$(python3 --version)" "$(node --version)"
printf 'Runtime: %s\nCache: %s\n' "$WORKSCRIBE_RUNTIME_HOME" "$WORKSCRIBE_RUNTIME_CACHE"
[ "${1:-}" != --check ] || exit 0
[ "$#" = 0 ] || fail 'Usage: scripts/bootstrap.sh [--check]'
python3 scripts/runtime-doctor.py --all-models
npm --prefix obsidian-plugin ci --no-audit --no-fund
printf '\nSetup complete. Next: swift build && scripts/build-app.sh\n'
