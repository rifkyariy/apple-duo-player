#!/bin/sh
# Builds "build/Duo Player.app" (release, ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Duo Player.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DuoPlayer "$APP/Contents/MacOS/"
cp Sources/DuoPlayer/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
