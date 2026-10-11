#!/bin/bash
# Builds "DHCP Server.app" into ./build.   ./build.sh test  runs the logic self-test instead.
set -euo pipefail
cd "$(dirname "$0")"

# Keep intermediate files out of the (cloud-synced) project folder.
OUT="${HOME}/Library/Caches/DHCPServer-build"
TARGET="$(uname -m)-apple-macos13.0"
mkdir -p "$OUT"

if [[ "${1:-}" == "test" ]]; then
    swiftc -swift-version 5 -target "$TARGET" Sources/Core/*.swift Sources/SelfTest/main.swift -o "$OUT/SelfTest"
    exec "$OUT/SelfTest"
fi

APP="build/DHCP Server.app"
swiftc -O -swift-version 5 -target "$TARGET" Sources/Core/*.swift Sources/App/*.swift -o "$OUT/DHCPServer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/DHCPServer" "$APP/Contents/MacOS/DHCPServer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Built: $(pwd)/$APP"
