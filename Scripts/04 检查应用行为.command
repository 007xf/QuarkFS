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
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -I "$BIN_DIR/Modules" -I "$BIN_DIR" \
  Sources/QuarkFS/AppModel.swift Sources/QuarkFS/ShortcutPreferences.swift \
  Tests/QuarkFSCoreTests/AppBehaviorChecks.swift \
  "$BIN_DIR"/QuarkFSCore.build/*.o \
  -o "$BIN_DIR/QuarkFSBehaviorTests"
QUARKFS_ENGINE_PATH="$PROJECT_DIR/Tests/QuarkFSCoreTests/EngineFixture.py" "$BIN_DIR/QuarkFSBehaviorTests"
