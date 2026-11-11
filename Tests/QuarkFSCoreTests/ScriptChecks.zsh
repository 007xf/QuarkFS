#!/bin/zsh
# Account-free checks for the build, release and install scripts.
# Every check works in temporary folders. Scripts/05 is never executed: its
# functions are extracted and exercised against temporary application paths.
set -euo pipefail

PROJECT_DIR="${0:A:h:h:h}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/private/var/tmp}/QuarkFS-ScriptChecks.XXXXXX")"
FAILURES=0
STALE_OBJECT=""

finish() {
  [[ -z "$STALE_OBJECT" ]] || /bin/rm -f "$STALE_OBJECT"
  /bin/rm -rf "$WORK_DIR"
}
trap finish EXIT

pass() { print -r -- "PASS: $1"; }
fail() { print -ru2 -- "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

export SDKROOT="${SDKROOT:-}"
if [[ -z "$SDKROOT" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
[[ -n "$SDKROOT" ]] || unset SDKROOT

# A renamed or deleted QuarkFSCore source leaves its old object behind in an
# incremental build. The behaviour and single-instance checks must link only
# the objects of the current sources, as SwiftPM itself does.
check_stale_core_objects() {
  cd "$PROJECT_DIR"
  swift build --disable-sandbox --build-system native --product QuarkFSSmokeTests >/dev/null 2>&1
  local bin_dir
  bin_dir="$(swift build --disable-sandbox --build-system native --show-bin-path 2>/dev/null)"
  STALE_OBJECT="$bin_dir/QuarkFSCore.build/QuarkFSScriptCheckRenamed.swift.o"
  /bin/cp "$bin_dir/QuarkFSCore.build/WebDAVHealth.swift.o" "$STALE_OBJECT"
  if "$PROJECT_DIR/Scripts/06 检查单实例.command" >"$WORK_DIR/stale-object.log" 2>&1; then
    pass "a stale QuarkFSCore object from a renamed source does not break the linked checks"
  else
    fail "a stale QuarkFSCore object from a renamed source breaks Scripts/06: $(grep -m1 'duplicate symbol' "$WORK_DIR/stale-object.log" || tail -1 "$WORK_DIR/stale-object.log")"
  fi
  /bin/rm -f "$STALE_OBJECT"
  STALE_OBJECT=""
}

# Test binaries and bundles. Built once per run, in WORK_DIR only.
BINARY_DIR="$WORK_DIR/binaries"
build_binaries() {
  [[ -x "$BINARY_DIR/arm64" ]] && return 0
  mkdir -p "$BINARY_DIR"
  print 'int main(void) { return 0; }' > "$BINARY_DIR/main.c"
  clang -arch arm64 -o "$BINARY_DIR/arm64" "$BINARY_DIR/main.c"
  clang -arch x86_64 -arch arm64 -o "$BINARY_DIR/universal" "$BINARY_DIR/main.c"
}

# Writes an engine stand-in that has the Quark backend and, optionally, cmount.
make_engine() {
  local engine="$1" with_cmount="$2"  # Not "path": zsh ties it to PATH.
  cat > "$engine" <<ENGINE
#!/bin/zsh
case "\$*" in
  "help backends") print quark ;;
  "cmount --help") [[ "$with_cmount" == 1 ]] || { print -u2 'unknown command "cmount"'; exit 1 } ;;
  "nfsmount --help"|version) print engine ;;
  *) exit 1 ;;
esac
ENGINE
  chmod 755 "$engine"
}

# A signed QuarkFS.app stand-in with the given main binary.
make_app() {
  local app="$1" binary="$2" identifier="${3:-com.holmes.QuarkFS}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Engine"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" \
    -c 'Add :CFBundleExecutable string QuarkFS' -c 'Add :CFBundleShortVersionString string 1.0.4' \
    "$app/Contents/Info.plist" >/dev/null
  cp "$binary" "$app/Contents/MacOS/QuarkFS"
  make_engine "$app/Contents/Resources/Engine/rclone" 1
  codesign --force --deep --sign - "$app" >/dev/null 2>&1
}

# The release script is the only gate before distribution. An engine built
# without macFUSE has no cmount; shipping it disables Finder mounting for
# every user of the release.
check_release_requires_mount_engine() {
  build_binaries
  local with_cmount project release rc
  for with_cmount in 0 1; do
    project="$WORK_DIR/release-$with_cmount"
    mkdir -p "$project/Scripts"
    cp "$PROJECT_DIR/Scripts/03 生成发布包.command" "$project/Scripts/"
    make_engine "$project/engine" "$with_cmount"
    print '#!/bin/zsh\nexit 0' > "$project/Scripts/01 构建引擎.command"
    cat > "$project/Scripts/02 打包应用.command" <<PACKAGE
#!/bin/zsh
set -euo pipefail
APP="\${0:A:h:h}/.build/QuarkFS.app"
mkdir -p "\$APP/Contents/MacOS" "\$APP/Contents/Resources/Engine"
cp "$BINARY_DIR/arm64" "\$APP/Contents/MacOS/QuarkFS"
cp "$project/engine" "\$APP/Contents/Resources/Engine/rclone"
PACKAGE
    chmod 755 "$project/Scripts/"*.command
    rc=0
    "$project/Scripts/03 生成发布包.command" >"$project/release.log" 2>&1 || rc=$?
    release="$project/.build/releases/QuarkFS-macOS-arm64.zip"
    if [[ "$with_cmount" == 0 ]]; then
      if [[ "$rc" != 0 && ! -e "$release" ]]; then
        pass "the release script refuses an engine without cmount: $(tail -1 "$project/release.log")"
      else
        fail "the release script shipped an engine without cmount (exit $rc, archive present: $([[ -e "$release" ]] && print yes || print no))"
      fi
    elif [[ "$rc" == 0 && -e "$release" ]]; then
      pass "the release script packages an engine with cmount"
    else
      fail "the release script rejected an engine with cmount: $(tail -1 "$project/release.log")"
    fi
  done
}

# Loads only the function definitions of the installer. Its top level, which
# operates on /Applications, is never executed by these checks.
load_installer_functions() {
  local definitions="$WORK_DIR/installer-functions.zsh"
  awk '/^[a-z_]+\(\) \{$/ { inside = 1 } inside { print } inside && /^\}$/ { inside = 0 }' \
    "$PROJECT_DIR/Scripts/05 安全安装升级.command" > "$definitions"
  source "$definitions"
}

# 1.0.x shipped as a Universal app. The installed app being replaced may
# contain x86_64; only the new app must be arm64-only. Failures must say why.
check_installer_verification() {
  build_binaries
  load_installer_functions
  local apps="$WORK_DIR/verify-apps" output rc
  make_app "$apps/arm64/QuarkFS.app" "$BINARY_DIR/arm64"
  make_app "$apps/universal/QuarkFS.app" "$BINARY_DIR/universal"
  make_app "$apps/foreign/QuarkFS.app" "$BINARY_DIR/arm64" com.example.Other
  if verify_app "$apps/arm64/QuarkFS.app" >/dev/null 2>&1 && verify_app "$apps/arm64/QuarkFS.app" existing >/dev/null 2>&1; then
    pass "an arm64 QuarkFS app verifies as new and as installed"
  else
    fail "an arm64 QuarkFS app does not verify"
  fi
  if verify_app "$apps/universal/QuarkFS.app" existing >/dev/null 2>&1; then
    pass "an installed 1.0.x Universal app can be replaced"
  else
    fail "an installed 1.0.x Universal app blocks the upgrade"
  fi
  output="$(verify_app "$apps/universal/QuarkFS.app" 2>&1 >/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" != 0 && "$output" == *arm64* ]]; then
    pass "a new app that is not arm64-only is refused with a reason: $output"
  else
    fail "a new Universal app was not refused with a reason (exit $rc, message: ${output:-none})"
  fi
  output="$(verify_app "$apps/foreign/QuarkFS.app" existing 2>&1 >/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" != 0 && -n "$output" ]]; then
    pass "a foreign bundle is refused with a reason: $output"
  else
    fail "a foreign bundle was not refused with a reason (exit $rc, message: ${output:-none})"
  fi
}

# Runs the installer's cleanup on a simulated interruption and prints the
# marker of the app left at the target, or "missing".
run_cleanup() {
  local scenario="$1" previous_moved="$2" new_installed="$3" staged_new="$4" target="$5" previous="$6"
  local root="$WORK_DIR/cleanup-$scenario"
  mkdir -p "$root/stage"
  [[ -z "$target" ]] || { mkdir -p "$root/QuarkFS.app"; print "$target" > "$root/QuarkFS.app/marker" }
  [[ -z "$previous" ]] || { mkdir -p "$root/stage/previous/QuarkFS.app"; print "$previous" > "$root/stage/previous/QuarkFS.app/marker" }
  [[ "$staged_new" == 0 ]] || { mkdir -p "$root/stage/QuarkFS.app"; print new > "$root/stage/QuarkFS.app/marker" }
  (
    TARGET_APP="$root/QuarkFS.app"
    INSTALL_STAGE="$root/stage"
    STAGED=1
    PREVIOUS_MOVED="$previous_moved"
    NEW_INSTALLED="$new_installed"
    INSTALL_VERIFIED=0
    cleanup 130
  ) >"$root/cleanup.log" 2>&1 || true
  if [[ -f "$root/QuarkFS.app/marker" ]]; then cat "$root/QuarkFS.app/marker"; else print missing; fi
}

# A signal can arrive after a move has completed but before the flag that
# records it. The installed app must never be deleted or left in hiding.
check_installer_interrupt_recovery() {
  load_installer_functions
  local result
  result="$(run_cleanup moved-old-before-flag 0 0 1 "" old)"
  [[ "$result" == old ]] && pass "an interrupt right after moving the old app restores it" \
    || fail "an interrupt right after moving the old app leaves the target: $result"
  result="$(run_cleanup moved-new-before-flag 1 0 0 new old)"
  [[ "$result" == old ]] && pass "an interrupt right after moving the new app restores the old app" \
    || fail "an interrupt right after moving the new app leaves the target: $result"
  result="$(run_cleanup fresh-install-before-flag 0 0 0 new "")"
  [[ "$result" == missing ]] && pass "an interrupted fresh install removes the unverified app" \
    || fail "an interrupted fresh install leaves the unverified app: $result"
  result="$(run_cleanup verification-failed 1 1 0 new old)"
  [[ "$result" == old ]] && pass "a failed verification restores the old app" \
    || fail "a failed verification leaves the target: $result"
  result="$(run_cleanup before-swap 0 0 1 old "")"
  [[ "$result" == old ]] && pass "an interrupt before the swap keeps the installed app" \
    || fail "an interrupt before the swap changed the target: $result"
  local swap_start
  swap_start="$(grep -n '/bin/mv "\$TARGET_APP"' "$PROJECT_DIR/Scripts/05 安全安装升级.command" | head -1 | cut -d: -f1)"
  if awk -v limit="$swap_start" "NR < limit && /^trap '' INT TERM HUP\$/ { found = 1 } END { exit !found }" \
      "$PROJECT_DIR/Scripts/05 安全安装升级.command"; then
    pass "the installer ignores interrupts while it swaps the applications"
  else
    fail "the installer can be interrupted between the two application moves"
  fi
}

# Since macOS 15, Control-click > Open no longer bypasses Gatekeeper.
check_gatekeeper_documentation() {
  local document
  for document in README.zh-CN.md "01 项目说明.md" "02 安装与使用.md"; do
    if grep -q '仍要打开' "$PROJECT_DIR/$document" && grep -q 'macOS 15' "$PROJECT_DIR/$document"; then
      pass "$document explains the macOS 15+ Open Anyway step"
    else
      fail "$document only explains Control-click > Open, which macOS 15+ no longer allows"
    fi
  done
  if grep -q 'Open Anyway' "$PROJECT_DIR/README.md" && grep -q 'macOS 15' "$PROJECT_DIR/README.md"; then
    pass "README.md explains the macOS 15+ Open Anyway step"
  else
    fail "README.md only explains Control-click > Open, which macOS 15+ no longer allows"
  fi
}

run_check() {
  case "$1" in
    stale-objects) check_stale_core_objects ;;
    release-gate) check_release_requires_mount_engine ;;
    installer-verification) check_installer_verification ;;
    installer-interrupts) check_installer_interrupt_recovery ;;
    gatekeeper-docs) check_gatekeeper_documentation ;;
    *) fail "unknown check: $1" ;;
  esac
}

CHECKS=("$@")
(( ${#CHECKS} )) || CHECKS=(stale-objects release-gate installer-verification installer-interrupts gatekeeper-docs)
for name in "${CHECKS[@]}"; do
  run_check "$name"
done

if (( FAILURES > 0 )); then
  print -u2 "$FAILURES script check(s) failed"
  exit 1
fi
print "PASS: script checks (${CHECKS[*]})"
