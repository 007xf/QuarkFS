#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_APP="${1:-$PROJECT_DIR/.build/QuarkFS.app}"
TARGET_APP="/Applications/QuarkFS.app"
BACKUP_DIR="$PROJECT_DIR/01 升级备份"
INSTALL_STAGE=""
STAGED=0
INSTALL_VERIFIED=0

# verify_app <app> [existing]: the new app must be arm64-only; the installed
# app being replaced only has to contain arm64 (1.0.x shipped as Universal).
verify_app() {
  local candidate="$1" role="${2:-new}" value
  [[ -d "$candidate" && ! -L "$candidate" ]] || { print -u2 "未找到完整应用：$candidate"; return 1; }
  value="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null)" || value=""
  [[ "$value" == "com.holmes.QuarkFS" ]] || { print -u2 "不是 QuarkFS 应用（标识为 ${value:-未知}）：$candidate"; return 1; }
  value="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$candidate/Contents/Info.plist" 2>/dev/null)" || value=""
  [[ "$value" == "QuarkFS" ]] || { print -u2 "应用主程序名称不符（${value:-未知}）：$candidate"; return 1; }
  [[ -x "$candidate/Contents/MacOS/QuarkFS" && -x "$candidate/Contents/Resources/Engine/rclone" ]] || {
    print -u2 "应用缺少主程序或文件系统引擎：$candidate"; return 1; }
  value="$(lipo -archs "$candidate/Contents/MacOS/QuarkFS" 2>/dev/null)" || value=""
  if [[ "$role" == existing ]]; then
    [[ " $value " == *" arm64 "* ]] || { print -u2 "已安装的应用不支持 Apple Silicon（${value:-未知}）：$candidate"; return 1; }
  else
    [[ "$value" == "arm64" ]] || { print -u2 "新应用必须只包含 Apple Silicon（arm64），当前为 ${value:-未知}：$candidate"; return 1; }
  fi
  codesign --verify --deep --strict "$candidate" || { print -u2 "应用签名校验失败：$candidate"; return 1; }
}

require_stopped() {
  local executable
  while IFS= read -r executable; do
    if [[ "${executable:t}" == "QuarkFS" || "$executable" == */QuarkFS*.app/Contents/Resources/Engine/rclone ]]; then
      print -u2 "请先停止播放，在 QuarkFS 中卸载磁盘并退出应用，然后重新运行本安装脚本。如果应用已退出但引擎仍在运行，请重新打开 QuarkFS 再正常退出。"
      return 1
    fi
  done < <(/bin/ps -axo comm=)
}

# Decides from the filesystem, not from flags set after each move: a signal
# can arrive after a move has completed but before a flag could record it.
cleanup() {
  local exit_code="$1"
  local previous_app="$INSTALL_STAGE/previous/QuarkFS.app"
  if [[ "$INSTALL_VERIFIED" == 0 && -n "$INSTALL_STAGE" ]]; then
    # Once staged, the new app only leaves the stage by moving into place.
    if [[ "$STAGED" == 1 && ! -e "$INSTALL_STAGE/QuarkFS.app" && -d "$TARGET_APP" ]]; then
      /bin/rm -rf "$TARGET_APP"
    fi
    if [[ -d "$previous_app" ]]; then
      if [[ ! -e "$TARGET_APP" ]]; then
        /bin/mv "$previous_app" "$TARGET_APP" || {
          print -u2 "自动恢复失败，原应用仍保存在：$previous_app"
          exit 1
        }
        print -u2 "安装未完成，已恢复原应用。"
      else
        print -u2 "目标位置被其他程序占用，原应用保存在：$previous_app"
        exit 1
      fi
    fi
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
STAGED=1

if [[ -e "$TARGET_APP" ]]; then
  verify_app "$TARGET_APP" existing
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")"
  [[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,3}$' ]] || { print -u2 "旧版版本号不符合预期。"; exit 1; }
  mkdir -p "$BACKUP_DIR"
  ARCHIVE="$BACKUP_DIR/01 QuarkFS $VERSION $(date +%Y%m%d-%H%M%S)-$$.zip"
  ditto -c -k --sequesterRsrc --keepParent "$TARGET_APP" "$ARCHIVE.partial"
  unzip -tq "$ARCHIVE.partial" >/dev/null
  mkdir -p "$INSTALL_STAGE/restore-check"
  ditto -x -k "$ARCHIVE.partial" "$INSTALL_STAGE/restore-check"
  verify_app "$INSTALL_STAGE/restore-check/QuarkFS.app" existing
  diff -qr "$TARGET_APP" "$INSTALL_STAGE/restore-check/QuarkFS.app" >/dev/null
  /bin/mv "$ARCHIVE.partial" "$ARCHIVE"
  (cd "$BACKUP_DIR" && shasum -a 256 "${ARCHIVE:t}" > "${ARCHIVE:t}.sha256")
  print "已验证可恢复的旧版 ZIP：$ARCHIVE"
fi

require_stopped
# Do not let Ctrl-C or closing the window split the two moves. Should either
# move fail, cleanup restores the previous app from the stage.
trap '' INT TERM HUP
if [[ -e "$TARGET_APP" ]]; then
  mkdir "$INSTALL_STAGE/previous"
  /bin/mv "$TARGET_APP" "$INSTALL_STAGE/previous/QuarkFS.app"
fi
/bin/mv "$INSTALL_STAGE/QuarkFS.app" "$TARGET_APP"
trap 'exit 130' INT TERM HUP
verify_app "$TARGET_APP"
INSTALL_VERIFIED=1

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$TARGET_APP" || print -u2 "安装已完成；系统搜索索引稍后会自动更新。"
fi
print "安装完成：$TARGET_APP"
print "以后升级始终替换这个应用；保留 ZIP 备份即可，不要把旧版 .app 另存到文稿或下载目录。"
