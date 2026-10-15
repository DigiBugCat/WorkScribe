#!/bin/bash
# Registers WorkScribe's native-messaging host with Chrome, Chromium, Arc, Brave and Edge for the current user.
#
#   ./install-native-host.sh [path/to/WorkScribeNativeHost] [extra-extension-id ...]
#
# The host defaults to the one inside WorkScribe.app (~/Applications, then /Applications, then this checkout's
# .build). Extra IDs (e.g. an unpacked dev copy without the manifest key) are added to the allowlist.
# Run with --uninstall to remove the manifests.
set -euo pipefail
name="com.workscribe.clipper"
default_id="lcbgpofefjibjkigocjhkmjokpojgldd"
support="$HOME/Library/Application Support"
targets=(
  "$support/Google/Chrome/NativeMessagingHosts"
  "$support/Google/Chrome Beta/NativeMessagingHosts"
  "$support/Chromium/NativeMessagingHosts"
  "$support/Arc/User Data/NativeMessagingHosts"
  "$support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
  "$support/Microsoft Edge/NativeMessagingHosts"
)

if [ "${1:-}" = "--uninstall" ]; then
  for dir in "${targets[@]}"; do rm -f "$dir/$name.json"; done
  rm -f "$support/WorkScribe/NativeHost/allowed-origins.txt"
  echo "Removed the WorkScribe native host manifests."
  exit 0
fi

host="${1:-}"
[ $# -gt 0 ] && shift
if [ -z "$host" ]; then
  repo="$(cd "$(dirname "$0")/../.." && pwd)"
  for candidate in "$HOME/Applications/WorkScribe.app/Contents/Helpers/WorkScribeNativeHost" \
                   "/Applications/WorkScribe.app/Contents/Helpers/WorkScribeNativeHost" \
                   "$repo/.build/release/WorkScribeNativeHost" "$repo/.build/debug/WorkScribeNativeHost"; do
    if [ -x "$candidate" ]; then host="$candidate"; break; fi
  done
fi
if [ -z "$host" ] || [ ! -x "$host" ]; then
  echo "WorkScribeNativeHost not found. Build it (swift build -c release --product WorkScribeNativeHost) or pass its path." >&2
  exit 1
fi
host="$(cd "$(dirname "$host")" && pwd)/$(basename "$host")"

ids=("$default_id" "$@")
origins=""
for id in "${ids[@]}"; do
  if ! [[ "$id" =~ ^[a-p]{32}$ ]]; then echo "Not an extension ID: $id" >&2; exit 1; fi
  origins+="${origins:+, }\"chrome-extension://$id/\""
done

# The host checks the same allowlist itself (Chrome already enforces allowed_origins).
mkdir -p "$support/WorkScribe/NativeHost"
chmod 700 "$support/WorkScribe" "$support/WorkScribe/NativeHost" 2>/dev/null || true
printf '# Written by install-native-host.sh\n' > "$support/WorkScribe/NativeHost/allowed-origins.txt"
for id in "${ids[@]}"; do echo "chrome-extension://$id/" >> "$support/WorkScribe/NativeHost/allowed-origins.txt"; done

manifest=$(cat <<JSON
{
  "name": "$name",
  "description": "WorkScribe clip helper",
  "path": "$host",
  "type": "stdio",
  "allowed_origins": [$origins]
}
JSON
)
installed=0
for dir in "${targets[@]}"; do
  browser="$(dirname "$dir")"
  [ -d "$browser" ] || continue
  mkdir -p "$dir"
  printf '%s\n' "$manifest" > "$dir/$name.json"
  echo "Installed for ${browser#"$support/"}"
  installed=1
done
if [ $installed -eq 0 ]; then
  echo "No Chromium browser profile found; nothing installed." >&2
  exit 1
fi
echo "Host: $host"
