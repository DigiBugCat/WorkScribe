#!/usr/bin/env bash
# Install the WorkScribe plugin into an Obsidian vault.
#   scripts/install.sh /path/to/vault [--enable]
# Copies main.js, manifest.json and styles.css into <vault>/.obsidian/plugins/workscribe/.
# --enable also adds "workscribe" to <vault>/.obsidian/community-plugins.json
# (Obsidian still asks you to turn off Restricted mode the first time).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VAULT="${1:-}"
ENABLE="${2:-}"
if [[ -z "$VAULT" || "$VAULT" == -* ]]; then
  echo "usage: $0 /path/to/vault [--enable]" >&2
  exit 2
fi
if [[ ! -d "$VAULT" ]]; then
  echo "error: $VAULT is not a directory" >&2
  exit 1
fi
if [[ ! -d "$VAULT/.obsidian" ]]; then
  echo "note: $VAULT has no .obsidian folder yet (open it once in Obsidian, or continuing creates one)"
  mkdir -p "$VAULT/.obsidian"
fi
if [[ ! -f "$HERE/main.js" ]]; then
  echo "main.js missing; building…"
  (cd "$HERE" && npm run build >/dev/null)
fi
DEST="$VAULT/.obsidian/plugins/workscribe"
mkdir -p "$DEST"
cp "$HERE/main.js" "$HERE/manifest.json" "$HERE/styles.css" "$HERE/THIRD_PARTY_NOTICES.txt" "$DEST/"
echo "installed to $DEST"
if [[ "$ENABLE" == "--enable" ]]; then
  node -e '
    const fs = require("fs"); const f = process.argv[1];
    let list = []; try { list = JSON.parse(fs.readFileSync(f, "utf8")); } catch {}
    if (!list.includes("workscribe")) list.push("workscribe");
    fs.writeFileSync(f, JSON.stringify(list, null, 2));
    console.log("enabled in " + f);
  ' "$VAULT/.obsidian/community-plugins.json"
fi
echo "Reload Obsidian (or toggle the plugin under Settings → Community plugins)."
