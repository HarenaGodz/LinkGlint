#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHS="${ARCHS:-x86_64 arm64}"
APP="$ROOT/dist/LinkGlint.app"

cd "$ROOT"
BINARIES=()
HELPER_BINARIES=()
for ARCH in ${(z)ARCHS}; do
    swift build -c "$CONFIGURATION" --arch "$ARCH"
    BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --show-bin-path)"
    BINARIES+=("$BIN_DIR/LinkGlint")
    HELPER_BINARIES+=("$BIN_DIR/LinkGlintHelper")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/PrivilegedHelperTools"
if (( ${#BINARIES[@]} > 1 )); then
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/LinkGlint"
    lipo -create "${HELPER_BINARIES[@]}" -output "$APP/Contents/Library/PrivilegedHelperTools/LinkGlintHelper"
else
    cp "$BINARIES[1]" "$APP/Contents/MacOS/LinkGlint"
    cp "$HELPER_BINARIES[1]" "$APP/Contents/Library/PrivilegedHelperTools/LinkGlintHelper"
fi
cp "$ROOT/Resources/App/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/App/LinkGlint.icns" "$APP/Contents/Resources/LinkGlint.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
chmod +x "$APP/Contents/MacOS/LinkGlint"
chmod +x "$APP/Contents/Library/PrivilegedHelperTools/LinkGlintHelper"

# Sign the nested helper explicitly before signing the containing app. This also
# lets the app compare the installed helper byte-for-byte after updates.
codesign --force --sign - "$APP/Contents/Library/PrivilegedHelperTools/LinkGlintHelper"
# Ad-hoc signing is enough for a local app and prevents an unsigned-bundle warning.
codesign --force --deep --sign - "$APP"
echo "$APP"
