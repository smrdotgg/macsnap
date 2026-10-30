#!/bin/bash
# Builds the downloadable release: dist/MacSnap-<version>.dmg and .zip.
# Refuses to package an ad-hoc build: every release must carry the same
# signature, or macOS asks people for Screen Recording permission again
# after each update.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
APP=dist/MacSnap.app

if [ -n "$(git status --porcelain)" ]; then
  echo "error: the working tree has uncommitted changes; commit them first" >&2
  exit 1
fi

scripts/build-app.sh
if ! codesign -dv "$APP" 2>&1 | grep -q "Authority=MacSnap Local Signing"; then
  echo "error: $APP is not signed with MacSnap Local Signing" >&2
  exit 1
fi
codesign --verify --strict "$APP"

ZIP=dist/MacSnap-$VERSION.zip
DMG=dist/MacSnap-$VERSION.dmg
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MacSnap $VERSION" -srcfolder "$STAGE" -fs APFS -format UDZO "$DMG"

echo
for f in "$DMG" "$ZIP"; do
  printf '%s  %s\n' "$(du -h "$f" | cut -f1)" "$f"
done
shasum -a 256 "$DMG" "$ZIP"
cat <<EOF

To publish (after pushing main):
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION $DMG $ZIP --title "MacSnap $VERSION" --notes-file <(scripts/release-notes.sh $VERSION)
EOF
