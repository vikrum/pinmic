#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/PinMic.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "==> Cleaning previous build..."
rm -rf "$APP_BUNDLE"

echo "==> Creating bundle structure..."
mkdir -p "$MACOS_DIR"

echo "==> Compiling AppDelegate.swift..."
swiftc \
    -target arm64-apple-macosx13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -strict-concurrency=minimal \
    -O \
    -o "$MACOS_DIR/PinMic" \
    "$SCRIPT_DIR/Sources/AppDelegate.swift"

echo "==> Copying Info.plist..."
cp "$SCRIPT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

echo "==> Ad-hoc code signing..."
if codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null; then
    echo "    Signed (ad-hoc)."
else
    echo "    codesign failed — skipping (app will still run)."
fi

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "To run:     open \"$APP_BUNDLE\""
echo "To install: cp -r \"$APP_BUNDLE\" ~/Applications/"
