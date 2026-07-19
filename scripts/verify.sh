#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

echo "==> Running unit tests"
swift test

echo "==> Treating compiler warnings as errors"
swift build -Xswiftc -warnings-as-errors

echo "==> Building LinkGlint.app"
ARCHS="${ARCHS:-$(uname -m)}" ./build_app.sh

APP="$ROOT/dist/LinkGlint.app"
echo "==> Verifying bundle signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$APP/Contents/Library/PrivilegedHelperTools/LinkGlintHelper"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/LinkGlint")"
HELPER_ARCHITECTURES="$(lipo -archs "$APP/Contents/Library/PrivilegedHelperTools/LinkGlintHelper")"
[[ "$ARCHITECTURES" == "$HELPER_ARCHITECTURES" ]] || {
    echo "App/helper architecture mismatch: $ARCHITECTURES vs $HELPER_ARCHITECTURES" >&2
    exit 1
}
echo "Verified LinkGlint $VERSION ($ARCHITECTURES)"
