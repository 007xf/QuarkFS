#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_APP="$PROJECT_DIR/.build/QuarkFS.app"
PACKAGING_STAGE=""
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

ARCHES=(arm64)
if [[ "$ENGINE_ARCHES" != *arm64* ]]; then
  print "引擎必须支持 Apple Silicon（arm64）。"
  exit 1
fi

# Do not accidentally ship an engine that only runs on the build machine's OS.
ENGINE_MIN_OS="$(otool -l -arch arm64 "$ENGINE" | awk '/minos / {print $2; exit}')"
if [[ -z "$ENGINE_MIN_OS" || "${ENGINE_MIN_OS%%.*}" -gt 14 ]]; then
  print "引擎要求 macOS $ENGINE_MIN_OS，请重新运行“01 构建引擎.command”，将最低版本设为 macOS 14。"
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
"$PROJECT_DIR/Scripts/04 检查应用行为.command"
"$PROJECT_DIR/Scripts/06 检查单实例.command"

build_swift() {
  local arch="$1"
  local scratch="$PROJECT_DIR/.build/swift-$arch"
  local triple="$arch-apple-macosx14.0"
  print -u2 "正在构建 Swift 应用（$arch）..."
  swift build "${SWIFT_FLAGS[@]}" --scratch-path "$scratch" -c release --triple "$triple" >&2
  print -r -- "$(swift build "${SWIFT_FLAGS[@]}" --scratch-path "$scratch" -c release --triple "$triple" --show-bin-path)/QuarkFS"
}

MAIN_BINARIES=()
for arch in "${ARCHES[@]}"; do
  MAIN_BINARIES+=("$(build_swift "$arch")")
done

TEMP_MAIN="$PROJECT_DIR/.build/QuarkFS-arm64"
cp "${MAIN_BINARIES[1]}" "$TEMP_MAIN"

PACKAGING_STAGE="$(mktemp -d "$PROJECT_DIR/.build/packaging.XXXXXX")"
trap '[[ -z "$PACKAGING_STAGE" ]] || rm -rf "$PACKAGING_STAGE"' EXIT
touch "$PACKAGING_STAGE/.metadata_never_index"
APP_DIR="$PACKAGING_STAGE/QuarkFS.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/Engine" "$APP_DIR/Contents/Resources/Documentation"
cp "$TEMP_MAIN" "$APP_DIR/Contents/MacOS/QuarkFS"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
if [[ "$ENGINE_ARCHES" == "arm64" ]]; then
  cp "$ENGINE" "$APP_DIR/Contents/Resources/Engine/rclone"
else
  lipo "$ENGINE" -thin arm64 -output "$APP_DIR/Contents/Resources/Engine/rclone"
fi
cp "$PROJECT_DIR/README.md" "$APP_DIR/Contents/Resources/Documentation/README.md"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/Documentation/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_DIR/05 更新记录.md" "$APP_DIR/Contents/Resources/Documentation/CHANGELOG.md"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/Documentation/LICENSE"
cp "$PROJECT_DIR/01 项目说明.md" "$APP_DIR/Contents/Resources/Documentation/PROJECT_OVERVIEW.md"
cp "$PROJECT_DIR/02 安装与使用.md" "$APP_DIR/Contents/Resources/Documentation/INSTALL.md"
cp "$PROJECT_DIR/04 免责声明.md" "$APP_DIR/Contents/Resources/Documentation/DISCLAIMER.md"
chmod 755 "$APP_DIR/Contents/MacOS/QuarkFS" "$APP_DIR/Contents/Resources/Engine/rclone"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# Only replace the reproducible build artifact after signing verification. The
# installed application is managed exclusively by the safe upgrade script.
rm -rf "$OUTPUT_APP"
mv "$APP_DIR" "$OUTPUT_APP"
APP_DIR="$OUTPUT_APP"

print "应用已生成：$APP_DIR"
print "应用架构：$(lipo -archs "$APP_DIR/Contents/MacOS/QuarkFS")"
print "引擎架构：$(lipo -archs "$APP_DIR/Contents/Resources/Engine/rclone")"
print "安装或升级请运行“05 安全安装升级.command”，保持应用程序中只有一个 QuarkFS.app。"
if [[ "${QUARKFS_REVEAL_BUILD:-0}" == 1 ]] && command -v open >/dev/null 2>&1; then
  open -R "$APP_DIR"
fi
