#!/bin/bash
# Builds MacSnap, installs it to ~/Applications, adds the `macsnap` CLI to
# ~/.local/bin, and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."
PREFIX_APPS="${MACSNAP_APPS_DIR:-$HOME/Applications}"
PREFIX_BIN="${MACSNAP_BIN_DIR:-$HOME/.local/bin}"

scripts/build-app.sh

# Quit a running copy so the new one takes over.
osascript -e 'tell application id "dev.smr.macsnap" to quit' >/dev/null 2>&1 || true
pkill -x MacSnap 2>/dev/null || true
sleep 0.5

mkdir -p "$PREFIX_APPS" "$PREFIX_BIN"
rm -rf "$PREFIX_APPS/MacSnap.app"
cp -R dist/MacSnap.app "$PREFIX_APPS/MacSnap.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PREFIX_APPS/MacSnap.app" || true

cat > "$PREFIX_BIN/macsnap" <<SH
#!/bin/sh
# MacSnap CLI. With no arguments it starts a smart capture.
[ \$# -eq 0 ] && set -- capture
exec "$PREFIX_APPS/MacSnap.app/Contents/MacOS/MacSnap" "\$@"
SH
chmod +x "$PREFIX_BIN/macsnap"

open "$PREFIX_APPS/MacSnap.app"
echo
echo "Installed $PREFIX_APPS/MacSnap.app and $PREFIX_BIN/macsnap"
case ":$PATH:" in *":$PREFIX_BIN:"*) ;; *) echo "Note: $PREFIX_BIN is not on your PATH." ;; esac
