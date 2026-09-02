#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
PINNED_COMMIT="47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f"
ARCHIVE_SHA256="fce696c6ee13a26f38fa1b1a2ece9479eec771e765f868cd213151cd24e9d596"
ENGINE_DIR="$PROJECT_DIR/.build/engine"
TEMP_SOURCE="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_SOURCE"
}
trap cleanup EXIT

if ! command -v go >/dev/null 2>&1; then
  print "缺少 Go。请先安装 Go 1.22 或更高版本。"
  exit 1
fi

# 默认生成 Apple Silicon + Intel 通用引擎；调试时可用
# QUARKFS_ARCHS="arm64" 或 QUARKFS_ARCHS="x86_64" 只构建一个架构。
ARCHES=(arm64 x86_64)
if [[ -n "${QUARKFS_ARCHS:-}" ]]; then
  ARCHES=(${=QUARKFS_ARCHS})
fi
for arch in "${ARCHES[@]}"; do
  if [[ "$arch" != "arm64" && "$arch" != "x86_64" ]]; then
    print "不支持的架构：$arch（只支持 arm64 或 x86_64）"
    exit 1
  fi
done

BUILD_TAGS=()
CGO_MODE=0
if [[ -d /Library/Filesystems/macfuse.fs ]]; then
  BUILD_TAGS=(-tags cmount)
  CGO_MODE=1
else
  print "提示：尚未安装 macFUSE，将构建只支持 WebDAV 的引擎；安装 macFUSE 后请再运行一次。"
fi

mkdir -p "$ENGINE_DIR"
rm -f "$ENGINE_DIR/rclone" "$ENGINE_DIR/rclone-arm64" "$ENGINE_DIR/rclone-x86_64"

ARCHIVE="$TEMP_SOURCE/rclone.tar.gz"
curl -L --fail --retry 3 --connect-timeout 20 \
  -o "$ARCHIVE" \
  "https://codeload.github.com/zly2006/rclone/tar.gz/$PINNED_COMMIT"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$ARCHIVE_SHA256" ]]; then
  print "引擎源码归档校验失败。"
  exit 1
fi
tar -xzf "$ARCHIVE" -C "$TEMP_SOURCE"
SOURCE_DIR="$TEMP_SOURCE/rclone-$PINNED_COMMIT"

build_one() {
  local arch="$1"
  local go_arch="amd64"
  local output="$ENGINE_DIR/rclone-$arch"
  if [[ "$arch" == "arm64" ]]; then
    go_arch="arm64"
  fi

  print "正在构建 rclone 引擎（$arch）..."
  cd "$SOURCE_DIR"
  if [[ "$CGO_MODE" == "1" ]]; then
    env \
      CGO_ENABLED=1 \
      GOOS=darwin \
      GOARCH="$go_arch" \
      CC=clang \
      CGO_CFLAGS="-arch $arch" \
      CGO_LDFLAGS="-arch $arch" \
      go build "${BUILD_TAGS[@]}" -trimpath -ldflags "-s -w" -o "$output" .
  else
    env \
      CGO_ENABLED=0 \
      GOOS=darwin \
      GOARCH="$go_arch" \
      go build "${BUILD_TAGS[@]}" -trimpath -ldflags "-s -w" -o "$output" .
  fi

  chmod 755 "$output"
  backend_list="$("$output" help backends)"
  if [[ "$backend_list" != *quark* ]]; then
    print "构建结果缺少 Quark Drive 后端（$arch）。"
    exit 1
  fi
  if [[ "$CGO_MODE" == "1" ]]; then
    "$output" cmount --help >/dev/null
  else
    "$output" nfsmount --help >/dev/null
  fi
}

for arch in "${ARCHES[@]}"; do
  build_one "$arch"
done

if (( ${#ARCHES[@]} == 2 )); then
  lipo -create \
    "$ENGINE_DIR/rclone-arm64" \
    "$ENGINE_DIR/rclone-x86_64" \
    -output "$ENGINE_DIR/rclone"
else
  cp "$ENGINE_DIR/rclone-${ARCHES[1]}" "$ENGINE_DIR/rclone"
fi
chmod 755 "$ENGINE_DIR/rclone"

print "QuarkFS 引擎已构建：$ENGINE_DIR/rclone"
print "支持架构：$(lipo -archs "$ENGINE_DIR/rclone")"
