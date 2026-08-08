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

# Signing is required for UNUserNotificationCenter. Ad-hoc works, but gives every
# build a new code identity, so macOS re-prompts for Keychain access each time.
# Set CODESIGN_ID to a stable identity to keep the grant across rebuilds — see
# `security find-identity -v -p codesigning`. Keep it out of the repo by putting it
# in .codesign.local (untracked), or export it before running this script.
[ -f .codesign.local ] && . ./.codesign.local
codesign --force --deep --sign "${CODESIGN_ID:--}" "$APP"
echo "Signed: $APP (${CODESIGN_ID:-ad-hoc})"

echo "Built:  $APP"
echo "Run:    open $APP"
