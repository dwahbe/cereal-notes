#!/usr/bin/env bash
# Dev loop: kill any running CerealNotes, rebuild the .app, launch it.

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CerealNotes"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"

echo "==> stopping existing $APP_NAME instances"
# Kill every variant: wrapped .app, raw SwiftPM binary, and Xcode DerivedData builds.
# Also kill any attached lldb/debugserver so traced processes can actually exit.
pkill -9 -f "debugserver.*$APP_NAME" 2>/dev/null || true
pkill -9 -f "lldb-rpc-server" 2>/dev/null || true
killall "$APP_NAME" 2>/dev/null || true
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "\.build/$CONFIG/$APP_NAME" 2>/dev/null || true
pkill -f "DerivedData/.*/$APP_NAME" 2>/dev/null || true

# Purge any stale Xcode DerivedData build so LaunchServices can't resolve our
# bundle ID to it. Using Run in Xcode recreates it — avoid that and use this script.
DERIVED_GLOB=("$HOME"/Library/Developer/Xcode/DerivedData/distracted-ride-*)
for d in "${DERIVED_GLOB[@]}"; do
    if [ -d "$d" ]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -u "$d/Build/Products/Debug/" 2>/dev/null || true
        rm -rf "$d"
    fi
done

# Wait for processes to actually exit before rebuilding/launching.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "    warning: $APP_NAME still running after SIGTERM, sending SIGKILL"
    killall -9 "$APP_NAME" 2>/dev/null || true
    sleep 0.3
fi

"$ROOT/scripts/build-app.sh" "$CONFIG"

echo "==> launching $APP_BUNDLE"
open "$APP_BUNDLE"
