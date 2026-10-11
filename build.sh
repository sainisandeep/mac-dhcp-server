#!/bin/bash
# ./build.sh        builds "DHCP Server.app" into ./build (runs on Apple silicon and Intel)
# ./build.sh dmg    also packages it as ./build/DHCP-Server.dmg for sharing
# ./build.sh test   runs the logic self-test instead
set -euo pipefail
cd "$(dirname "$0")"

# Keep intermediate files out of the (cloud-synced) project folder.
OUT="${HOME}/Library/Caches/DHCPServer-build"
mkdir -p "$OUT"

if [[ "${1:-}" == "test" ]]; then
    swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/Core/*.swift Sources/SelfTest/main.swift -o "$OUT/SelfTest"
    exec "$OUT/SelfTest"
fi

APP="build/DHCP Server.app"
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" Sources/Core/*.swift Sources/App/*.swift -o "$OUT/DHCPServer-$ARCH"
done
lipo -create "$OUT/DHCPServer-arm64" "$OUT/DHCPServer-x86_64" -output "$OUT/DHCPServer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/DHCPServer" "$APP/Contents/MacOS/DHCPServer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built: $(pwd)/$APP"

if [[ "${1:-}" == "dmg" ]]; then
    STAGE="$OUT/dmg"
    DMG="build/DHCP-Server.dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "DHCP Server" -srcfolder "$STAGE" -format UDZO -ov -quiet "$DMG"
    echo "Built: $(pwd)/$DMG"
fi
