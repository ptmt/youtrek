#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOKEN_FILE="${TOKEN_FILE:-$HOME/.youtrek.token}"
BASE_URL="${YOUTRACK_BASE_URL:-}"
BASE_URL_FILE="${BASE_URL_FILE:-$HOME/.youtrek.base_url}"
DERIVED_DATA="${DERIVED_DATA_PATH:-"$ROOT_DIR/build/DerivedData"}"
APP_PATH="${APP_PATH:-"$DERIVED_DATA/Build/Products/Debug/YouTrek.app"}"
BIN_PATH="${BIN_PATH:-"$APP_PATH/Contents/MacOS/YouTrek"}"
BUILD=false
LAUNCH=true
RELAUNCH=true

usage() {
  cat <<'USAGE'
Usage: scripts/prefill_token.sh [options]

Options:
  --token-file <path>   Path to file containing token (default: ~/.youtrek.token)
  --base-url <url>      YouTrack base URL (or set YOUTRACK_BASE_URL)
  --base-url-file <path>Path to file containing base URL (default: ~/.youtrek.base_url)
  --build               Build the app if the binary is missing
  --no-launch           Do not open the app after saving the token
  --no-relaunch         Do not quit/relaunch the app before opening
  --help                Show this help
USAGE
}

trim() {
  local value="$1"
  value="${value//$'\r'/}"
  value="${value//$'\n'/}"
  printf "%s" "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

read_defaults_base_url() {
  local value=""
  value="$(/usr/bin/defaults read com.potomushto.youtrek.shared com.potomushto.youtrek.config.base-url 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$(/usr/bin/defaults read com.potomushto.youtrek com.potomushto.youtrek.config.base-url 2>/dev/null || true)"
  fi
  printf "%s" "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token-file)
      TOKEN_FILE="$2"
      shift 2
      ;;
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --base-url-file)
      BASE_URL_FILE="$2"
      shift 2
      ;;
    --build)
      BUILD=true
      shift
      ;;
    --no-launch)
      LAUNCH=false
      shift
      ;;
    --no-relaunch)
      RELAUNCH=false
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$BASE_URL" && -f "$BASE_URL_FILE" ]]; then
  BASE_URL="$(<"$BASE_URL_FILE")"
fi
if [[ -z "$BASE_URL" ]]; then
  BASE_URL="$(read_defaults_base_url)"
fi
BASE_URL="$(trim "$BASE_URL")"

if [[ -z "$BASE_URL" ]]; then
  echo "Missing base URL. Pass --base-url, set YOUTRACK_BASE_URL, or create $BASE_URL_FILE."
  exit 1
fi

if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "Token file not found: $TOKEN_FILE"
  exit 1
fi

TOKEN="$(<"$TOKEN_FILE")"
TOKEN="$(trim "$TOKEN")"
if [[ -z "$TOKEN" ]]; then
  echo "Token file is empty: $TOKEN_FILE"
  exit 1
fi

if [[ ! -x "$BIN_PATH" ]]; then
  if [[ "$BUILD" == true ]]; then
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
      -scheme "YouTrek" \
      -configuration "Debug" \
      -destination "platform=macOS" \
      -derivedDataPath "$DERIVED_DATA" \
      build
  else
    echo "App binary not found at $BIN_PATH"
    echo "Build the app first (./youtrek.sh) or pass --build."
    exit 1
  fi
fi

echo "Saving token to keychain (token not printed)."
"$BIN_PATH" auth login --base-url "$BASE_URL" --token "$TOKEN"

if [[ "$LAUNCH" == true ]]; then
  if [[ "$RELAUNCH" == true ]]; then
    /usr/bin/osascript -e 'tell application "YouTrek" to if it is running then quit' >/dev/null 2>&1 || true
    sleep 1
  fi
  open "$APP_PATH"
fi
