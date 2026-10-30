#!/bin/bash
# Prints the CHANGELOG section for a version, plus install steps, for the
# GitHub release body.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(cat VERSION)}
awk -v v="$VERSION" '
  /^## / { on = ($2 == v) ; next }
  on
' CHANGELOG.md
cat <<'EOF'

### Install

1. Download **MacSnap-*.dmg**, open it, and drag MacSnap to Applications.
2. Open MacSnap. macOS blocks it the first time because it isn't notarized by Apple: go to **System Settings › Privacy & Security**, scroll down, click **Open Anyway**, and confirm. (Or run `xattr -dr com.apple.quarantine /Applications/MacSnap.app` once.)
3. Follow the welcome window to allow Screen Recording.

Requires an Apple silicon Mac on macOS 27 or later.
EOF
