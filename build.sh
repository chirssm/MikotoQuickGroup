#!/usr/bin/env bash
# ============================================================================
#  一键构建 MikotoQuickGroup.dylib
#  适用环境：macOS（含 Xcode Command Line Tools）或 Linux（已装 theos 工具链）
#  用法：
#     ./build.sh              # 构建 dylib + deb
#     ./build.sh dylib        # 只构建 dylib（最快）
#     THEOS_PACKAGE_SCHEME=  ./build.sh   # 有根越狱
# ============================================================================
set -euo pipefail

SCHEME="${THEOS_PACKAGE_SCHEME-rootless}"
echo "==> 越狱方案：${SCHEME:-rootful}"

# ---------- 1. 准备 Theos ----------
if [ -z "${THEOS:-}" ]; then
  if [ -d "$HOME/theos" ]; then
    export THEOS="$HOME/theos"
  else
    echo "==> 未找到 Theos，开始克隆..."
    git clone --recursive --depth 1 https://github.com/theos/theos.git "$HOME/theos"
    export THEOS="$HOME/theos"
  fi
fi
echo "==> THEOS=$THEOS"

# ---------- 2. 准备 iOS SDK ----------
if [ ! -d "$THEOS/sdks" ] || [ -z "$(ls -A "$THEOS/sdks" 2>/dev/null)" ]; then
  echo "==> 下载 iOS SDK..."
  mkdir -p "$THEOS/sdks"
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/theos/sdks.git "$tmp/sdks"
  cp -R "$tmp"/sdks/*.sdk "$THEOS/sdks/" 2>/dev/null || true
  rm -rf "$tmp"
fi
ls "$THEOS/sdks" | head -3

# ---------- 3. 构建 ----------
cd "$(dirname "$0")"
make clean >/dev/null 2>&1 || true

if [ "${1:-package}" = "dylib" ]; then
  echo "==> make（仅 dylib）"
  make
else
  echo "==> make package（dylib + deb）"
  # 打包需要 dpkg-deb；macOS 走 brew
  if ! command -v dpkg-deb >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
    brew install dpkg ldid >/dev/null 2>&1 || true
  fi
  make package
fi

# ---------- 4. 汇总产物 ----------
echo
echo "================ 构建产物 ================"
find . -name "*.dylib" -not -path "./.git/*" -print 2>/dev/null
find . -name "*.deb"   -not -path "./.git/*" -print 2>/dev/null
echo "=========================================="
echo "dylib 可直接改名后投放至越狱设备的："
echo "  rootless  : /var/jb/Library/MobileSubstrate/DynamicLibraries/"
echo "  有根越狱  : /Library/MobileSubstrate/DynamicLibraries/"
