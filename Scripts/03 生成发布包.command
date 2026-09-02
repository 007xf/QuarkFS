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
if [[ "$APP_ARCHES" == *arm64* && "$APP_ARCHES" == *x86_64* ]]; then
  ARCHIVE_NAME="QuarkFS-macOS-universal.zip"
elif [[ "$APP_ARCHES" == *arm64* ]]; then
  ARCHIVE_NAME="QuarkFS-macOS-arm64.zip"
else
  ARCHIVE_NAME="QuarkFS-macOS-x86_64.zip"
fi

mkdir -p "$RELEASE_DIR"
rm -f "$RELEASE_DIR/$ARCHIVE_NAME" "$RELEASE_DIR/$ARCHIVE_NAME.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$RELEASE_DIR/$ARCHIVE_NAME"
(cd "$RELEASE_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")

print "发布包已生成：$RELEASE_DIR/$ARCHIVE_NAME"
print "校验文件：$RELEASE_DIR/$ARCHIVE_NAME.sha256"
cat "$RELEASE_DIR/$ARCHIVE_NAME.sha256"
