#!/usr/bin/env bash
# Builds Murmur.app (Apple silicon) into mac/build/ and zips it.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/Murmur.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Murmur" "$APP/Contents/MacOS/Murmur"
# SwiftPM resource bundles (looked up in Contents/Resources)
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# ad-hoc signature (no developer account): macOS asks for the microphone
# again after each new build
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"
(cd build && ditto -c -k --keepParent Murmur.app Murmur.zip)
echo "built $APP ($VERSION, build $BUILD)"
