#!/bin/bash
# Packages dist/SwitchSwitcher.app into a compressed DMG with an Applications symlink.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="SwitchSwitcher"
APP="$DIST/${APP_NAME}.app"

if [ ! -d "$APP" ]; then
    echo "错误：找不到 $APP，请先运行 ./scripts/build_app.sh" >&2
    exit 1
fi

VERSION="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0.0"
)"
DMG_NAME="${APP_NAME}-${VERSION}"
STAGING="$DIST/dmg-staging"
DMG_PATH="$DIST/${DMG_NAME}.dmg"
TMP_DMG="$DIST/${DMG_NAME}-tmp.dmg"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$TMP_DMG" "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDRW "$TMP_DMG"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$TMP_DMG"
rm -rf "$STAGING"

echo "==> 完成：$DMG_PATH"
ls -lh "$DMG_PATH"
