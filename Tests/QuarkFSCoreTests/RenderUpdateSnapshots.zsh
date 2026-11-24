#!/bin/zsh
# Development-only off-screen snapshot renderer for the update-check UI.
# Never shipped in QuarkFS.app; uses temporary paths, fake credentials,
# the fixture engine, and stubbed update responses.
set -euo pipefail

PROJECT_DIR="${0:A:h:h:h}"
cd "$PROJECT_DIR"

if [[ $# -eq 0 ]]; then
  ARGS=("$PROJECT_DIR/.build/update-shots")
else
  ARGS=("$@")
fi

if [[ -n "${QUARKFS_SDKROOT:-}" ]]; then
  export SDKROOT="$QUARKFS_SDKROOT"
elif [[ -z "${SDKROOT:-}" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

swift build --disable-sandbox --build-system native --product QuarkFSSmokeTests
BIN_DIR="$(swift build --disable-sandbox --build-system native --show-bin-path)"

CORE_OBJECTS=()
for source in Sources/QuarkFSCore/*.swift; do
  CORE_OBJECTS+=("$BIN_DIR/QuarkFSCore.build/${source:t}.o")
done

swiftc -parse-as-library -D QUARKFS_SNAPSHOTS -target "$(uname -m)-apple-macosx14.0" \
  -I "$BIN_DIR/Modules" -I "$BIN_DIR" \
  Sources/QuarkFS/AppModel.swift \
  Sources/QuarkFS/ShortcutPreferences.swift \
  Sources/QuarkFS/MenuBarGlyph.swift \
  Sources/QuarkFS/QRLoginView.swift \
  Sources/QuarkFS/ContentView.swift \
  Tests/QuarkFSCoreTests/RenderUpdateSnapshots.swift \
  "${CORE_OBJECTS[@]}" \
  -framework AppKit -framework CoreImage \
  -o "$BIN_DIR/QuarkFSUpdateSnapshots"

QUARKFS_ENGINE_PATH="$PROJECT_DIR/Tests/QuarkFSCoreTests/EngineFixture.py" \
  "$BIN_DIR/QuarkFSUpdateSnapshots" "${ARGS[@]}"
