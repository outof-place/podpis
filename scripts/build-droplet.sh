#!/bin/bash
# Builds "Wstaw podpis.app", a droplet for PDFs over `podpisz wyglad` (scripts/wstaw-podpis.applescript),
# signs it ad hoc and installs it in /Applications. No admin rights. Needs scripts/install-cli.sh first.
#   scripts/build-droplet.sh            build and install
#   scripts/build-droplet.sh --no-install   only build/droplet/Wstaw podpis.app
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Wstaw podpis"
BUILD=build/droplet
APP="$BUILD/$NAME.app"
# /Applications, where Finder and Launchpad list apps; ~/Applications only when it is not writable
APPS=/Applications
[ -w "$APPS" ] || APPS="$HOME/Applications"
DEST="$APPS/$NAME.app"

rm -rf "$BUILD" && mkdir -p "$BUILD"
osacompile -o "$APP" scripts/wstaw-podpis.applescript

# Icon: the Podpis paper with an amber seal and a plus, every size from 1024 px.
ICONSET="$BUILD/droplet.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$BUILD/icon-1024.png" --wyglad >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/droplet.icns"
rm -f "$APP/Contents/Resources/Assets.car"   # osacompile's own icon would win over droplet.icns

PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string pl.outofplace.podpis.wyglad "$PLIST"
plutil -replace CFBundleIconFile -string droplet "$PLIST"
plutil -remove CFBundleIconName "$PLIST" 2>/dev/null || true
# PDFs only: Finder lets nothing else onto the icon
plutil -replace CFBundleDocumentTypes -json \
  '[{"CFBundleTypeName":"PDF","CFBundleTypeRole":"Viewer","LSItemContentTypes":["com.adobe.pdf"]}]' "$PLIST"

codesign --force --sign - --identifier pl.outofplace.podpis.wyglad --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "${1:-}" != "--no-install" ]; then
  mkdir -p "$APPS"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "Zainstalowano: $DEST"
else
  echo "Zbudowano: $APP"
fi
[ -x "$HOME/.local/bin/podpisz" ] || echo "Uwaga: nie ma ~/.local/bin/podpisz. Najpierw scripts/install-cli.sh."
