#!/bin/sh
# Builds build/Crescendo.app and build/Crescendo-<version>.dmg.
# SIGN_IDENTITY picks the code-signing identity; the default "-" signs ad-hoc.
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
SIGN_IDENTITY=${SIGN_IDENTITY:--}
APP=build/Crescendo.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset build/dmg

clang -O2 -fobjc-arc -Wno-deprecated-declarations -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
  -o "$APP/Contents/MacOS/Crescendo" Crescendo.m \
  -framework AppKit -framework ApplicationServices -framework CoreAudio -framework IOKit -framework QuartzCore -framework ServiceManagement
clang -O2 -fobjc-arc -o build/make-icon make-icon.m -framework AppKit
build/make-icon build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
codesign -s "$SIGN_IDENTITY" -f "$APP"

cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Crescendo -srcfolder build/dmg -ov -format UDZO "build/Crescendo-$VERSION.dmg" >/dev/null
echo "Built $APP and build/Crescendo-$VERSION.dmg"
