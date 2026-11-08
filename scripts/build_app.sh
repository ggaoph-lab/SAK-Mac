#!/bin/bash
# Builds "SwitchSwitcher.app" into dist/ with a fully bundled Python runtime + deps.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${VENDOR:-$ROOT/vendor}"
NSCB_REPO="https://github.com/julesontheroad/NSC_BUILDER.git"
NSZ_REPO="https://github.com/nicoboss/nsz.git"
APP_NAME="SwitchSwitcher"
VERSION="1.2.1"

# python-build-standalone (relocatable CPython)
PY_VERSION="3.12.16"
PY_TAG="20261026"
case "$(uname -m)" in
    arm64) PY_ARCH="aarch64-apple-darwin" ;;
    x86_64) PY_ARCH="x86_64-apple-darwin" ;;
    *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac
PY_TGZ="cpython-${PY_VERSION}+${PY_TAG}-${PY_ARCH}-install_only_stripped.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_TAG}/${PY_TGZ}"
PY_CACHE="$VENDOR/python-standalone"

cd "$ROOT"

echo "==> 准备后端源码"
mkdir -p "$VENDOR"
[ -d "$VENDOR/NSC_BUILDER" ] || git clone --depth 1 "$NSCB_REPO" "$VENDOR/NSC_BUILDER"
[ -d "$VENDOR/nsz" ] || git clone --depth 1 "$NSZ_REPO" "$VENDOR/nsz"
for patch in "$ROOT/patches/nscb-macos.patch" "$ROOT/patches/nscb-fix-xml-remove.patch"; do
    if [ -f "$patch" ] && git -C "$VENDOR/NSC_BUILDER" apply --check "$patch" 2>/dev/null; then
        git -C "$VENDOR/NSC_BUILDER" apply "$patch"
    fi
done

echo "==> 下载内置 Python ($PY_ARCH)"
mkdir -p "$PY_CACHE"
if [ ! -f "$PY_CACHE/$PY_TGZ" ]; then
    curl -L --fail --retry 3 -o "$PY_CACHE/$PY_TGZ" "$PY_URL"
fi
PY_STAGE="$(mktemp -d)/python-root"
mkdir -p "$PY_STAGE"
tar -xzf "$PY_CACHE/$PY_TGZ" -C "$PY_STAGE"
# tarball contains a top-level "python/" directory
if [ -d "$PY_STAGE/python" ]; then
    PY_PREFIX="$PY_STAGE/python"
else
    PY_PREFIX="$PY_STAGE"
fi
PY_BIN="$PY_PREFIX/bin/python3"
[ -x "$PY_BIN" ] || { echo "错误：解压后找不到 python3" >&2; exit 1; }
echo "    $($PY_BIN --version 2>&1)"

echo "==> 预装 Python 依赖（打进 App，用户无需联网安装）"
"$PY_BIN" -m ensurepip --upgrade >/dev/null
"$PY_BIN" -m pip install --disable-pip-version-check --upgrade pip
"$PY_BIN" -m pip install --disable-pip-version-check -r "$ROOT/Resources/requirements.txt"
TMP_NSZ="$(mktemp -d)"
cp -R "$VENDOR/nsz/" "$TMP_NSZ/"
"$PY_BIN" -m pip install --disable-pip-version-check --no-deps "$TMP_NSZ"
rm -rf "$TMP_NSZ"
# nsz ships as a package without __main__.py; add one so `python -m nsz` works when relocated.
NSZ_SP="$("$PY_BIN" -c 'import nsz, pathlib; print(pathlib.Path(nsz.__file__).parent)')"
cat > "$NSZ_SP/__main__.py" <<'PY'
from nsz import main

if __name__ == "__main__":
    raise SystemExit(main())
PY
# Drop caches / tests to keep the bundle smaller
find "$PY_PREFIX" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$PY_PREFIX" -type d -name 'tests' -path '*/site-packages/*' -prune -exec rm -rf {} + 2>/dev/null || true

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
cp "$ROOT/Resources/check_updates.py" "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

BACKEND="$APP/Contents/Resources/backend"
# Bundled relocatable Python with site-packages already populated
rsync -a "$PY_PREFIX/" "$BACKEND/python/"
# Make sure the interpreter is executable after copy
chmod +x "$BACKEND/python/bin/"* 2>/dev/null || true

rsync -a \
    --exclude '*.bat' --exclude '*.exe' --exclude '__pycache__/' \
    --exclude 'ztools/web/' --exclude 'ztools/bin/' --exclude 'ztools/keys.txt' --exclude 'zconfig/DB/' \
    "$VENDOR/NSC_BUILDER/py/ztools" "$VENDOR/NSC_BUILDER/py/zconfig" "$BACKEND/NSC_BUILDER/"
cp "$VENDOR/NSC_BUILDER/LICENSE" "$BACKEND/NSC_BUILDER/LICENSE"

# Keep nsz sources for license/reference; runtime uses the pip-installed module.
mkdir -p "$BACKEND/nsz"
rsync -a --exclude '__pycache__/' \
    "$VENDOR/nsz/LICENSE.md" "$VENDOR/nsz/README.md" \
    "$BACKEND/nsz/" 2>/dev/null || true
cp "$VENDOR/nsz/LICENSE.md" "$BACKEND/nsz/LICENSE.md" 2>/dev/null || true

{
    echo "app=$VERSION"
    echo "python=$PY_VERSION+$PY_TAG-$PY_ARCH"
    echo "nscb=$(git -C "$VENDOR/NSC_BUILDER" rev-parse HEAD)"
    echo "nsz=$(git -C "$VENDOR/nsz" rev-parse HEAD)"
    shasum "$ROOT/patches/"*.patch "$ROOT/Resources/requirements.txt" | awk '{print $1}'
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
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 本地签名"
# Clear quarantine-ish extended attrs that break codesign on downloaded python bits
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

echo "==> 完成：$APP"
"$BACKEND/python/bin/python3" -c "import Crypto, nsz, zstandard; print('backend imports OK')"
