#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/.build/QuarkFS.app"
ENGINE="$PROJECT_DIR/.build/engine/rclone"

if [[ ! -x "$ENGINE" ]]; then
  print "尚未构建文件系统引擎，请先运行“01 构建引擎.command”。"
  exit 1
fi

ENGINE_ARCHES="$(lipo -archs "$ENGINE" 2>/dev/null || true)"
if [[ -z "$ENGINE_ARCHES" ]]; then
  print "无法识别引擎架构。"
  exit 1
fi

ARCHES=()
if [[ "$ENGINE_ARCHES" == *arm64* ]]; then
  ARCHES+=(arm64)
fi
if [[ "$ENGINE_ARCHES" == *x86_64* ]]; then
  ARCHES+=(x86_64)
fi
if (( ${#ARCHES[@]} == 0 )); then
  print "引擎必须包含 arm64 或 x86_64。"
  exit 1
fi

cd "$PROJECT_DIR"
COMPAT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -d "$COMPAT_SDK" ]]; then
  export SDKROOT="$COMPAT_SDK"
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-cache"

SWIFT_FLAGS=(--disable-sandbox --build-system native --manifest-cache local --cache-path "$PROJECT_DIR/.build/spm-cache")
swift run "${SWIFT_FLAGS[@]}" QuarkFSSmokeTests

build_swift() {
  local arch="$1"
  local scratch="$PROJECT_DIR/.build/swift-$arch"
  local triple="$arch-apple-macosx14.0"
  print "正在构建 Swift 应用（$arch）..."
  swift build "${SWIFT_FLAGS[@]}" --scratch-path "$scratch" -c release --triple "$triple"
  print -r -- "$(swift build "${SWIFT_FLAGS[@]}" --scratch-path "$scratch" -c release --triple "$triple" --show-bin-path)/QuarkFS"
}

MAIN_BINARIES=()
for arch in "${ARCHES[@]}"; do
  MAIN_BINARIES+=("$(build_swift "$arch" | tail -1)")
done

TEMP_MAIN="$PROJECT_DIR/.build/QuarkFS-universal"
if (( ${#MAIN_BINARIES[@]} == 2 )); then
  lipo -create "${MAIN_BINARIES[@]}" -output "$TEMP_MAIN"
else
  cp "${MAIN_BINARIES[1]}" "$TEMP_MAIN"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Engine" "$APP_DIR/Contents/Resources/Documentation"
cp "$TEMP_MAIN" "$APP_DIR/Contents/MacOS/QuarkFS"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ENGINE" "$APP_DIR/Contents/Resources/Engine/rclone"
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/Documentation/README.md"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/Documentation/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/Documentation/LICENSE"
cp "$PROJECT_DIR/01 项目说明.md" "$APP_DIR/Contents/Resources/Documentation/PROJECT_OVERVIEW.md"
cp "$PROJECT_DIR/02 安装与使用.md" "$APP_DIR/Contents/Resources/Documentation/INSTALL.md"
cp "$PROJECT_DIR/04 免责声明.md" "$APP_DIR/Contents/Resources/Documentation/DISCLAIMER.md"
chmod 755 "$APP_DIR/Contents/MacOS/QuarkFS" "$APP_DIR/Contents/Resources/Engine/rclone"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

print "应用已生成：$APP_DIR"
print "应用架构：$(lipo -archs "$APP_DIR/Contents/MacOS/QuarkFS")"
print "引擎架构：$(lipo -archs "$APP_DIR/Contents/Resources/Engine/rclone")"
if command -v open >/dev/null 2>&1; then
  open -R "$APP_DIR"
fi
