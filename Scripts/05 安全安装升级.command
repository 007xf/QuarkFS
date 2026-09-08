#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_APP="${1:-$PROJECT_DIR/.build/QuarkFS.app}"
TARGET_APP="/Applications/QuarkFS.app"
BACKUP_DIR="$PROJECT_DIR/01 升级备份"
INSTALL_STAGE=""
PREVIOUS_MOVED=0
NEW_INSTALLED=0
INSTALL_VERIFIED=0

verify_app() {
  local candidate="$1"
  [[ -d "$candidate" && ! -L "$candidate" ]] || { print -u2 "未找到完整应用：$candidate"; return 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$candidate/Contents/Info.plist")" == "com.holmes.QuarkFS" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$candidate/Contents/Info.plist")" == "QuarkFS" ]] || return 1
  [[ -x "$candidate/Contents/MacOS/QuarkFS" && -x "$candidate/Contents/Resources/Engine/rclone" ]] || return 1
  [[ "$(lipo -archs "$candidate/Contents/MacOS/QuarkFS")" == "arm64" ]] || return 1
  codesign --verify --deep --strict "$candidate"
}

require_stopped() {
  local executable
  while IFS= read -r executable; do
    if [[ "${executable:t}" == "QuarkFS" || "$executable" == */QuarkFS*.app/Contents/Resources/Engine/rclone ]]; then
      print -u2 "请先停止播放，在 QuarkFS 中卸载磁盘并退出应用，然后重新运行本安装脚本。"
      return 1
    fi
  done < <(/bin/ps -axo comm=)
}

cleanup() {
  local exit_code="$1"
  if [[ "$INSTALL_VERIFIED" == 0 && "$PREVIOUS_MOVED" == 1 ]]; then
    if [[ "$NEW_INSTALLED" == 1 && -d "$TARGET_APP" ]]; then
      /bin/rm -rf "$TARGET_APP"
    fi
    if [[ ! -e "$TARGET_APP" ]]; then
      /bin/mv "$INSTALL_STAGE/previous/QuarkFS.app" "$TARGET_APP" || {
        print -u2 "自动恢复失败，原应用仍保存在：$INSTALL_STAGE/previous/QuarkFS.app"
        exit 1
      }
      print -u2 "安装未完成，已恢复原应用。"
    else
      print -u2 "目标位置被其他程序占用，原应用保存在：$INSTALL_STAGE/previous/QuarkFS.app"
      exit 1
    fi
  elif [[ "$INSTALL_VERIFIED" == 0 && "$NEW_INSTALLED" == 1 && -d "$TARGET_APP" ]]; then
    /bin/rm -rf "$TARGET_APP"
  fi
  [[ -z "$INSTALL_STAGE" ]] || /bin/rm -rf "$INSTALL_STAGE"
  exit "$exit_code"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT TERM HUP

SOURCE_APP="${SOURCE_APP:A}"
[[ "$SOURCE_APP" != "$TARGET_APP" ]] || { print -u2 "来源不能是已安装的应用。"; exit 1; }
[[ ! -L "$TARGET_APP" ]] || { print -u2 "应用程序中的 QuarkFS 是链接，请先检查实际安装位置。"; exit 1; }
verify_app "$SOURCE_APP"
require_stopped
[[ -w /Applications ]] || { print -u2 "当前用户没有应用程序文件夹的写入权限。"; exit 1; }

# Hidden staging on the same volume allows a rollback without exposing another
# launchable app to Spotlight. Only verified ZIP archives survive the install.
INSTALL_STAGE="$(mktemp -d /Applications/.QuarkFS-install.XXXXXX)"
touch "$INSTALL_STAGE/.metadata_never_index"
ditto "$SOURCE_APP" "$INSTALL_STAGE/QuarkFS.app"
verify_app "$INSTALL_STAGE/QuarkFS.app"

if [[ -e "$TARGET_APP" ]]; then
  verify_app "$TARGET_APP"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")"
  [[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,3}$' ]] || { print -u2 "旧版版本号不符合预期。"; exit 1; }
  mkdir -p "$BACKUP_DIR"
  ARCHIVE="$BACKUP_DIR/01 QuarkFS $VERSION $(date +%Y%m%d-%H%M%S)-$$.zip"
  ditto -c -k --sequesterRsrc --keepParent "$TARGET_APP" "$ARCHIVE.partial"
  unzip -tq "$ARCHIVE.partial" >/dev/null
  mkdir -p "$INSTALL_STAGE/restore-check"
  ditto -x -k "$ARCHIVE.partial" "$INSTALL_STAGE/restore-check"
  verify_app "$INSTALL_STAGE/restore-check/QuarkFS.app"
  diff -qr "$TARGET_APP" "$INSTALL_STAGE/restore-check/QuarkFS.app" >/dev/null
  /bin/mv "$ARCHIVE.partial" "$ARCHIVE"
  (cd "$BACKUP_DIR" && shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256")
  print "已验证可恢复的旧版 ZIP：$ARCHIVE"
fi

require_stopped
if [[ -e "$TARGET_APP" ]]; then
  mkdir "$INSTALL_STAGE/previous"
  /bin/mv "$TARGET_APP" "$INSTALL_STAGE/previous/QuarkFS.app"
  PREVIOUS_MOVED=1
fi
/bin/mv "$INSTALL_STAGE/QuarkFS.app" "$TARGET_APP"
NEW_INSTALLED=1
verify_app "$TARGET_APP"
INSTALL_VERIFIED=1

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$TARGET_APP" || print -u2 "安装已完成；系统搜索索引稍后会自动更新。"
fi
print "安装完成：$TARGET_APP"
print "以后升级始终替换这个应用；保留 ZIP 备份即可，不要把旧版 .app 另存到文稿或下载目录。"
