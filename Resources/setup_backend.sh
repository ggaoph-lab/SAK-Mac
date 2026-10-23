#!/bin/bash
# Usage: setup_backend.sh <bundled backend dir> <application support dir>
set -euo pipefail

BACKEND="$1"
SUPPORT="$2"

echo "==> 查找 Python 3"
PY=""
for c in \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
    /usr/bin/python3; do
    if [ -x "$c" ] && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
        PY="$c"
        break
    fi
done
if [ -z "$PY" ]; then
    echo "错误：没有找到 Python 3.9 或更高版本。请先运行 'brew install python' 或从 python.org 安装。" >&2
    exit 1
fi
echo "    使用 $PY ($("$PY" --version 2>&1))"

mkdir -p "$SUPPORT"

echo "==> 创建 Python 虚拟环境"
if [ ! -x "$SUPPORT/venv/bin/python" ]; then
    "$PY" -m venv "$SUPPORT/venv"
fi
VPY="$SUPPORT/venv/bin/python"

echo "==> 安装依赖（需要联网）"
"$VPY" -m pip install --disable-pip-version-check --upgrade pip
"$VPY" -m pip install --disable-pip-version-check -r "$BACKEND/requirements.txt"

echo "==> 安装 nsz"
TMP_NSZ="$(mktemp -d)"
cp -R "$BACKEND/nsz/" "$TMP_NSZ/"
"$VPY" -m pip install --disable-pip-version-check --no-deps "$TMP_NSZ"
rm -rf "$TMP_NSZ"

echo "==> 部署 NSC_BUILDER"
mkdir -p "$SUPPORT/NSC_BUILDER"
rsync -a --delete --exclude 'keys.txt' --exclude 'DB/' "$BACKEND/NSC_BUILDER/" "$SUPPORT/NSC_BUILDER/"

cp "$BACKEND/VERSION" "$SUPPORT/.backend_version"
echo "==> 后端安装完成"
