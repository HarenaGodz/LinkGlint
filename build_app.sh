#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHS="${ARCHS:-x86_64 arm64}"
APP="$ROOT/dist/NetBar.app"

cd "$ROOT"
BINARIES=()
HELPER_BINARIES=()
for ARCH in ${(z)ARCHS}; do
    swift build -c "$CONFIGURATION" --arch "$ARCH"
    BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --show-bin-path)"
    BINARIES+=("$BIN_DIR/NetBar")
    HELPER_BINARIES+=("$BIN_DIR/NetBarHelper")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/PrivilegedHelperTools"
if (( ${#BINARIES[@]} > 1 )); then
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/NetBar"
    lipo -create "${HELPER_BINARIES[@]}" -output "$APP/Contents/Library/PrivilegedHelperTools/NetBarHelper"
else
    cp "$BINARIES[1]" "$APP/Contents/MacOS/NetBar"
    cp "$HELPER_BINARIES[1]" "$APP/Contents/Library/PrivilegedHelperTools/NetBarHelper"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/NetBar.icns" "$APP/Contents/Resources/NetBar.icns"
chmod +x "$APP/Contents/MacOS/NetBar"
chmod +x "$APP/Contents/Library/PrivilegedHelperTools/NetBarHelper"

# Sign the nested helper explicitly before signing the containing app. This also
# lets the app compare the installed helper byte-for-byte after updates.
codesign --force --sign - "$APP/Contents/Library/PrivilegedHelperTools/NetBarHelper"
# Ad-hoc signing is enough for a local app and prevents an unsigned-bundle warning.
codesign --force --deep --sign - "$APP"
echo "$APP"
