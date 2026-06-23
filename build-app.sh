#!/usr/bin/env bash
set -e

# Generate icon
echo "Generating icon…"
swift make-icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "Icon ready."

# Build binary
swift build -c release

APP="dist/ClaudeTray.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/ClaudeTray "$APP/Contents/MacOS/ClaudeTray"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign — required for UNUserNotificationCenter to work
codesign --force --deep --sign - "$APP"
echo "Signed: $APP"

echo "Built: $APP"
echo "Run:   open $APP"
