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

# QuarkFS 1.1 起仅支持 Apple Silicon。
ARCHES=(arm64)
if [[ -n "${QUARKFS_ARCHS:-}" && "$QUARKFS_ARCHS" != "arm64" ]]; then
  print "当前版本仅支持 Apple Silicon（arm64）。"
  exit 1
fi

BUILD_TAGS=()
CGO_MODE=0
if [[ -d /Library/Filesystems/macfuse.fs ]]; then
  BUILD_TAGS=(-tags cmount)
  CGO_MODE=1
else
  print "提示：尚未安装 macFUSE，将构建只支持 WebDAV 的引擎；安装 macFUSE 后请再运行一次。"
fi

mkdir -p "$ENGINE_DIR"


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
  local go_arch="arm64"
  local output="$TEMP_SOURCE/rclone-$arch"

  print "正在构建 rclone 引擎（$arch）..."
  cd "$SOURCE_DIR"
  if [[ "$CGO_MODE" == "1" ]]; then
    env \
      CGO_ENABLED=1 \
      GOOS=darwin \
      GOARCH="$go_arch" \
      CC=clang \
      MACOSX_DEPLOYMENT_TARGET=14.0 \
      CGO_CFLAGS="-arch $arch -mmacosx-version-min=14.0" \
      CGO_LDFLAGS="-arch $arch -mmacosx-version-min=14.0" \
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

cp "$TEMP_SOURCE/rclone-arm64" "$ENGINE_DIR/rclone-arm64"
cp "$TEMP_SOURCE/rclone-arm64" "$ENGINE_DIR/rclone"
chmod 755 "$ENGINE_DIR/rclone"

print "QuarkFS 引擎已构建：$ENGINE_DIR/rclone"
print "支持架构：$(lipo -archs "$ENGINE_DIR/rclone")"
