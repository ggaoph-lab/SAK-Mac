#!/bin/bash
# Builds "SwitchSwitcher.app" into dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${VENDOR:-$ROOT/vendor}"
NSCB_REPO="https://github.com/julesontheroad/NSC_BUILDER.git"
NSZ_REPO="https://github.com/nicoboss/nsz.git"
APP_NAME="SwitchSwitcher"
VERSION="1.0.0"

cd "$ROOT"

echo "==> 准备后端源码"
mkdir -p "$VENDOR"
[ -d "$VENDOR/NSC_BUILDER" ] || git clone --depth 1 "$NSCB_REPO" "$VENDOR/NSC_BUILDER"
[ -d "$VENDOR/nsz" ] || git clone --depth 1 "$NSZ_REPO" "$VENDOR/nsz"
if git -C "$VENDOR/NSC_BUILDER" apply --check "$ROOT/patches/nscb-macos.patch" 2>/dev/null; then
    git -C "$VENDOR/NSC_BUILDER" apply "$ROOT/patches/nscb-macos.patch"
fi

echo "==> 编译 Swift"
# SwiftUI's @State macro plugin ships only with Xcode, not the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)/SAKMac"

echo "==> 组装 .app"
APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend"
cp "$BIN" "$APP/Contents/MacOS/SAKMac"
cp "$ROOT/Resources/setup_backend.sh" "$APP/Contents/Resources/"
cp "$ROOT/Resources/check_updates.py" "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/requirements.txt" "$APP/Contents/Resources/backend/"

BACKEND="$APP/Contents/Resources/backend"
rsync -a \
    --exclude '*.bat' --exclude '*.exe' --exclude '__pycache__/' \
    --exclude 'ztools/web/' --exclude 'ztools/bin/' --exclude 'ztools/keys.txt' --exclude 'zconfig/DB/' \
    "$VENDOR/NSC_BUILDER/py/ztools" "$VENDOR/NSC_BUILDER/py/zconfig" "$BACKEND/NSC_BUILDER/"
cp "$VENDOR/NSC_BUILDER/LICENSE" "$BACKEND/NSC_BUILDER/LICENSE"
mkdir -p "$BACKEND/nsz"
rsync -a --exclude '__pycache__/' \
    "$VENDOR/nsz/nsz" "$VENDOR/nsz/nsz.py" "$VENDOR/nsz/setup.py" "$VENDOR/nsz/README.md" \
    "$VENDOR/nsz/LICENSE.md" "$VENDOR/nsz/requirements.txt" "$VENDOR/nsz/MANIFEST.in" \
    "$BACKEND/nsz/"
{
    echo "app=$VERSION"
    echo "nscb=$(git -C "$VENDOR/NSC_BUILDER" rev-parse HEAD)"
    echo "nsz=$(git -C "$VENDOR/nsz" rev-parse HEAD)"
    shasum "$ROOT/patches/nscb-macos.patch" "$ROOT/Resources/requirements.txt" | awk '{print $1}'
} > "$BACKEND/VERSION"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>local.sak.mac</string>
    <key>CFBundleExecutable</key><string>SAKMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 本地签名"
codesign --force --deep --sign - "$APP"

echo "==> 完成：$APP"
