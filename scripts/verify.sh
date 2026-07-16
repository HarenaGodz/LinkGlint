#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

echo "==> Running unit tests"
swift test

echo "==> Building NetBar.app"
ARCHS="${ARCHS:-$(uname -m)}" ./build_app.sh

APP="$ROOT/dist/NetBar.app"
echo "==> Verifying bundle signature"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/NetBar")"
echo "Verified NetBar $VERSION ($ARCHITECTURES)"
