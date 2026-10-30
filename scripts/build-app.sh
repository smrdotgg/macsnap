#!/bin/bash
# Builds dist/MacSnap.app (release) and signs it with the local identity.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release
BIN=$(swift build -c release --show-bin-path)/MacSnap

APP=dist/MacSnap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN" "$APP/Contents/MacOS/MacSnap"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
cp Resources/Fonts/*-OFL.txt "$APP/Contents/Resources/Licenses/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/Licenses/MacSnap-LICENSE.txt"

if KC=$(scripts/signing-identity.sh 2>/dev/null); then
  ID=$(security find-identity -p codesigning "$KC" | awk '/"MacSnap Local Signing"/ {print $2; exit}')
  codesign --force --keychain "$KC" -s "$ID" --identifier dev.smr.macsnap "$APP"
  echo "signed with MacSnap Local Signing"
else
  codesign --force -s - --identifier dev.smr.macsnap "$APP"
  echo "ad-hoc signed (permissions reset on every rebuild)"
fi
echo "built $APP ($VERSION)"
