#!/bin/bash
# Build "Patron Radio.app" (universal) into ./dist.
#
#   scripts/build-app.sh                 # ad-hoc signed, runs on this Mac
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#                                        # hardened-runtime signed, ready to notarize
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
APP="dist/Patron Radio.app"

swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/PatronRadio"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PatronRadio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
