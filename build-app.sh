#!/usr/bin/env bash
set -e

swift build -c release

APP="dist/ClaudeTray.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/ClaudeTray "$APP/Contents/MacOS/ClaudeTray"
cp Info.plist "$APP/Contents/Info.plist"

echo "Built: $APP"
echo "Run:   open $APP"
