#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="YouTrek"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
DERIVED_DATA="${DERIVED_DATA_PATH:-"$ROOT_DIR/build/DerivedData"}"

xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/YouTrek.app"
BIN_PATH="$APP_PATH/Contents/MacOS/YouTrek"

if [[ $# -eq 0 ]]; then
  open "$APP_PATH"
else
  "$BIN_PATH" "$@"
fi
