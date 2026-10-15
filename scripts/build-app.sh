#!/bin/bash
# Builds Podpis.app (release, arm64), signs it ad hoc and installs it in ~/Applications.
#   scripts/build-app.sh            build and install
#   scripts/build-app.sh --no-install   only build/Podpis.app
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-26.6.app/Contents/Developer}

APP=build/Podpis.app
DEST="$HOME/Applications/Podpis.app"

swift build -c release --arch arm64 --product Podpis
BIN=$(swift build -c release --arch arm64 --show-bin-path)/Podpis

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Podpis"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Icon: every size from the 1024 px master.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
[ -f Support/Icon/icon-1024.png ] || swift scripts/make-icon.swift Support/Icon/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s Support/Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Support/Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --identifier pl.outofplace.podpis --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "${1:-}" != "--no-install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "Zainstalowano: $DEST"
else
  echo "Zbudowano: $APP"
fi
