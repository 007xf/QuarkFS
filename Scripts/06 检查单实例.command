#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
COMPAT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -d "$COMPAT_SDK" ]]; then
  export SDKROOT="$COMPAT_SDK"
fi
swift build --disable-sandbox --build-system native --product QuarkFSSmokeTests
BIN_DIR="$(swift build --disable-sandbox --build-system native --show-bin-path)"
# Link only the objects of the current core sources. An incremental build
# keeps the object of a renamed or deleted source, which would otherwise be
# linked as a duplicate or stale definition.
CORE_OBJECTS=()
for source in Sources/QuarkFSCore/*.swift; do
  CORE_OBJECTS+=("$BIN_DIR/QuarkFSCore.build/${source:t}.o")
done
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -I "$BIN_DIR/Modules" -I "$BIN_DIR" \
  Tests/QuarkFSCoreTests/InstanceLockChecks.swift \
  "${CORE_OBJECTS[@]}" \
  -o "$BIN_DIR/QuarkFSInstanceLockTests"
"$BIN_DIR/QuarkFSInstanceLockTests"
