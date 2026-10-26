#!/bin/sh
# Builds dist/ClipStash.app (universal: Apple silicon + Intel) and, with --dmg, dist/ClipStash.dmg.
set -eu
cd "$(dirname "$0")"
# Multi-arch `--arch a --arch b` needs Xcode's xcbuild; build each slice and lipo them so CLT alone works.
for A in arm64 x86_64; do swift build -c release --triple $A-apple-macosx13.0; done
APP=dist/ClipStash.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/ClipStash .build/x86_64-apple-macosx/release/ClipStash \
    -output "$APP/Contents/MacOS/ClipStash"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ad-hoc signature: fine for this Mac. macOS asks for Accessibility again after each rebuild.
codesign --force --sign - --options runtime "$APP"
echo "Built $APP"
if [ "${1:-}" = "--dmg" ]; then
    rm -f dist/ClipStash.dmg
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname ClipStash -srcfolder "$STAGE" -ov -format UDZO dist/ClipStash.dmg >/dev/null
    rm -rf "$STAGE"
    echo "Built dist/ClipStash.dmg"
fi
