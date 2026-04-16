#!/usr/bin/env bash
# Build the SwiftPM binary and wrap it into CerealNotes.app so that
# LaunchServices-gated APIs (UNUserNotificationCenter, Login Items, etc.) work.
#
# Output: <repo>/.build/CerealNotes.app

set -euo pipefail

CONFIG="${1:-debug}"
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
    echo "usage: $0 [debug|release]" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CerealNotes"
BUNDLE_ID="com.cerealnotes.app"
SRC_DIR="$ROOT/Sources/$APP_NAME"
INFO_PLIST="$SRC_DIR/Info.plist"
ENTITLEMENTS="$SRC_DIR/CerealNotes.entitlements"
OUT_DIR="$ROOT/.build"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"

echo "==> swift build ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "ERROR: binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"

# Write PkgInfo so LaunchServices treats this as a proper app.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc sign with entitlements so TCC + notifications behave like a real app.
# When distributing, replace "-" with a Developer ID Application identity.
echo "==> codesign (ad-hoc)"
codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp=none \
    "$APP_BUNDLE" >/dev/null

# Register with LaunchServices so the bundle ID resolves immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> built $APP_BUNDLE"
echo "    bundle id: $BUNDLE_ID"
