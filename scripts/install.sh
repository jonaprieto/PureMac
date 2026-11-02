#!/usr/bin/env bash
# Builds this fork and installs it as /Applications/PureMac.app.
#
# A stable signature matters: macOS ties Full Disk Access to it, so ad-hoc builds would lose the grant on every install.
set -euo pipefail
cd "$(dirname "$0")/.."

# find-identity -v still lists revoked certificates, with a CSSMERR note, so pick by hash and never by name.
identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ && !/CSSMERR/ { print $2; exit }')
if [[ -z "$identity" ]]; then echo "No valid Apple Development identity." >&2; exit 1; fi

xcodebuild -project PureMac.xcodeproj -scheme PureMac -configuration Release -derivedDataPath build \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO -quiet build

built=build/Build/Products/Release/PureMac.app
codesign --force --options runtime --sign "$identity" "$built"
codesign --verify --strict "$built"

# Quit politely and stop if PureMac stays open: it may be mid-clean, so it's never killed.
if pgrep -x PureMac >/dev/null; then
  osascript -e 'tell application id "com.puremac.app" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do pgrep -x PureMac >/dev/null || break; sleep 0.1; done
  if pgrep -x PureMac >/dev/null; then
    echo "PureMac is still open. Quit it and run this again." >&2
    exit 1
  fi
fi

new=/Applications/PureMac.app.new
rm -rf "$new"
ditto "$built" "$new"
rm -rf /Applications/PureMac.app
mv "$new" /Applications/PureMac.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PureMac.app
open /Applications/PureMac.app
