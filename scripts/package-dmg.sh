#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHS="${ARCHS:-x86_64 arm64}"
DIST="$ROOT/dist"
PLIST="$ROOT/Resources/App/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
EXPECTED_VERSION="3.10.0"
EXPECTED_BUILD="23"
[[ "$VERSION" == "$EXPECTED_VERSION" ]] || { echo "Unexpected version: $VERSION" >&2; exit 1; }
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || { echo "Unexpected build: $BUILD" >&2; exit 1; }

APP="$DIST/LinkGlint.app"
DMG_OUTPUT="${DMG_OUTPUT:-$DIST/LinkGlint-$VERSION-universal.dmg}"
CHECKSUM="$DMG_OUTPUT.sha256"
VOLUME_NAME="LinkGlint $VERSION"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linkglint-dmg.XXXXXX")"
RW_IMAGE="$WORK_DIR/LinkGlint-rw.dmg"
STAGE="$WORK_DIR/stage"
BACKGROUND="$WORK_DIR/background.png"
MOUNT_POINT=""

cleanup() {
    set +e
    if [[ -n "$MOUNT_POINT" ]]; then
        hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$DIST" "$STAGE/.background"
ARCHS="$ARCHS" CONFIGURATION="$CONFIGURATION" "$ROOT/scripts/build-app.sh" >/dev/null
[[ -d "$APP" ]] || { echo "Application build did not produce $APP" >&2; exit 1; }

swift "$ROOT/scripts/render-dmg-background.swift" \
    "$ROOT/Resources/DMG/dmg-background-source.png" "$BACKGROUND"
cp "$BACKGROUND" "$STAGE/.background/background.png"
ditto "$APP" "$STAGE/LinkGlint.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG_OUTPUT" "$CHECKSUM"
du_kb="$(du -sk "$STAGE" | awk '{print $1}')"
size_mb=$(( (du_kb + 32767) / 32768 + 32 ))
hdiutil create \
    -size "${size_mb}m" \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -format UDRW \
    -ov \
    "$RW_IMAGE" >/dev/null

MOUNT_POINT="$(hdiutil attach "$RW_IMAGE" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ { sub(/^[^[:space:]]+[[:space:]]+Apple_HFS[[:space:]]+/, ""); print; exit }')"
[[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || { echo "Unable to mount temporary DMG" >&2; exit 1; }

open -a Finder
osascript - "$VOLUME_NAME" "$MOUNT_POINT" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set mountPoint to item 2 of argv
    tell application "Finder"
        tell disk volumeName
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {100, 100, 760, 500}
            set icon size of icon view options of container window to 96
            set text size of icon view options of container window to 13
            set arrangement of icon view options of container window to not arranged
            set background picture of icon view options of container window to file ".background:background.png"
            set position of item "LinkGlint.app" of container window to {170, 230}
            set position of item "Applications" of container window to {490, 230}
            close container window
            open
            delay 2
            close container window
        end tell
    end tell
end run
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNT_POINT=""

hdiutil convert "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_OUTPUT" >/dev/null
codesign --force --sign - "$DMG_OUTPUT" >/dev/null
hdiutil verify "$DMG_OUTPUT" >/dev/null

VERIFY_MOUNT="$(hdiutil attach "$DMG_OUTPUT" -readonly -noverify -noautoopen | awk '/Apple_HFS/ { sub(/^[^[:space:]]+[[:space:]]+Apple_HFS[[:space:]]+/, ""); print; exit }')"
[[ -n "$VERIFY_MOUNT" ]] || { echo "Unable to mount final DMG" >&2; exit 1; }
[[ -d "$VERIFY_MOUNT/LinkGlint.app" ]] || { echo "DMG is missing LinkGlint.app" >&2; exit 1; }
[[ -L "$VERIFY_MOUNT/Applications" ]] || { echo "DMG is missing Applications link" >&2; exit 1; }
[[ -f "$VERIFY_MOUNT/.background/background.png" ]] || { echo "DMG is missing background" >&2; exit 1; }
lipo -archs "$VERIFY_MOUNT/LinkGlint.app/Contents/MacOS/LinkGlint" | grep -q 'x86_64' || exit 1
lipo -archs "$VERIFY_MOUNT/LinkGlint.app/Contents/MacOS/LinkGlint" | grep -q 'arm64' || exit 1
hdiutil detach "$VERIFY_MOUNT" >/dev/null
shasum -a 256 "$DMG_OUTPUT" > "$CHECKSUM"

echo "$DMG_OUTPUT"
echo "$CHECKSUM"
