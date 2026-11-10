#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
RELEASE_DIR="$PROJECT_DIR/.build/releases"
APP_DIR="$PROJECT_DIR/.build/QuarkFS.app"

"$PROJECT_DIR/Scripts/01 构建引擎.command"
"$PROJECT_DIR/Scripts/02 打包应用.command"

if [[ ! -d "$APP_DIR" ]]; then
  print "未找到已打包的 QuarkFS.app。"
  exit 1
fi

APP_ARCHES="$(lipo -archs "$APP_DIR/Contents/MacOS/QuarkFS")"
if [[ "$APP_ARCHES" != "arm64" ]]; then
  print "发布包必须只包含 Apple Silicon（arm64）。"
  exit 1
fi

# Without macFUSE, 01 builds a WebDAV-only engine for diagnostics. A release
# must also mount in Finder, so refuse an engine without the Quark backend or cmount.
PACKAGED_ENGINE="$APP_DIR/Contents/Resources/Engine/rclone"
BACKENDS="$("$PACKAGED_ENGINE" help backends 2>&1)" || BACKENDS=""
if [[ "$BACKENDS" != *quark* ]]; then
  print "发布包中的引擎缺少 Quark Drive 后端，已停止生成发布包。"
  exit 1
fi
if ! "$PACKAGED_ENGINE" cmount --help >/dev/null 2>&1; then
  print "发布包中的引擎缺少本地磁盘挂载（cmount）功能，已停止生成发布包。请先安装并允许 macFUSE，再重新运行本脚本。"
  exit 1
fi
ARCHIVE_NAME="QuarkFS-macOS-arm64.zip"

mkdir -p "$RELEASE_DIR"
TEMP_ARCHIVE="$RELEASE_DIR/.$ARCHIVE_NAME.$$.partial"
trap 'rm -f "$TEMP_ARCHIVE"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$TEMP_ARCHIVE"
unzip -tq "$TEMP_ARCHIVE" >/dev/null
mv -f "$TEMP_ARCHIVE" "$RELEASE_DIR/$ARCHIVE_NAME"
(cd "$RELEASE_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")

print "发布包已生成：$RELEASE_DIR/$ARCHIVE_NAME"
print "校验文件：$RELEASE_DIR/$ARCHIVE_NAME.sha256"
cat "$RELEASE_DIR/$ARCHIVE_NAME.sha256"
