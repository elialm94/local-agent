#!/usr/bin/env bash
# Build the PairApp executable and wrap it in a minimal .app bundle.
#
# Why a bundle: macOS privacy permissions (Accessibility, Screen Recording,
# Microphone) are granted to a code identity. A bare `swift run` binary gets a
# new ad-hoc identity on every rebuild and you would re-grant permissions each
# time. Signing the bundle with a stable identifier keeps them sticky.
#
# Usage:  scripts/make-app.sh [debug|release]
#         open build/Pair.app
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "PairApp is macOS-only. On other platforms build PairCore with: swift build --target PairCore" >&2
  exit 1
fi

swift build -c "$CONFIG" --product Pair

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Pair"
APP="$ROOT/build/Pair.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pair"
cp "$ROOT/Sources/PairApp/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Ad-hoc signature with a stable identifier. Replace "-" with your Developer ID
# to distribute. The entitlements are what a hardened-runtime build needs for
# mic + Apple Events; ad-hoc builds ignore them harmlessly.
codesign --force --sign - --identifier dev.pair.app \
  --entitlements "$ROOT/scripts/Pair.entitlements" "$APP" 2>/dev/null \
  || codesign --force --sign - --identifier dev.pair.app "$APP"

echo "Built $APP"
echo "Run:   open \"$APP\""
echo "Logs:  log stream --predicate 'process == \"Pair\"' --level debug"
