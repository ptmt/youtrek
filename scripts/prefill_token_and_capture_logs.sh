#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"

TOKEN_FILE="${TOKEN_FILE:-$HOME/.youtrek.token}"
BASE_URL="${YOUTRACK_BASE_URL:-}"
BASE_URL_FILE="${BASE_URL_FILE:-$HOME/.youtrek.base_url}"

LOOPS="${LOOPS:-2}"
WAIT_SECONDS="${WAIT_SECONDS:-5}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/build/logs}"
LOG_STYLE="${LOG_STYLE:-compact}"
LOG_PREDICATE="${LOG_PREDICATE:-subsystem == \"com.potomushto.youtrek.app\"}"
INCLUDE_DEBUG="${INCLUDE_DEBUG:-true}"
BUILD="${BUILD:-false}"

usage() {
  cat <<'USAGE'
Usage: scripts/prefill_token_and_capture_logs.sh [options]

Options:
  --token-file <path>   Path to file containing token (default: ~/.youtrek.token)
  --base-url <url>      YouTrack base URL (or set YOUTRACK_BASE_URL)
  --base-url-file <path>Path to file containing base URL (default: ~/.youtrek.base_url)
  --loops <n>           Number of relaunch loops (default: 2)
  --wait <seconds>      Wait time between launch/quit (default: 5)
  --log-dir <path>      Directory for captured logs (default: build/logs)
  --build               Build the app before running
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
    --loops)
      LOOPS="$2"
      shift 2
      ;;
    --wait)
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --build)
      BUILD=true
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

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/keychain_prefill_$(date +%Y%m%d_%H%M%S).log"

LOG_ARGS=(stream --style "$LOG_STYLE" --predicate "$LOG_PREDICATE")
if [[ "$INCLUDE_DEBUG" == "true" ]]; then
  LOG_ARGS+=(--info --debug)
fi

echo "Capturing logs to $LOG_FILE"
/usr/bin/log "${LOG_ARGS[@]}" >"$LOG_FILE" 2>&1 &
LOG_PID=$!

cleanup() {
  if [[ -n "${LOG_PID:-}" ]]; then
    kill "$LOG_PID" >/dev/null 2>&1 || true
    wait "$LOG_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for ((i=1; i<=LOOPS; i++)); do
  echo "=== Loop $i/$LOOPS ===" | tee -a "$LOG_FILE"
  /usr/bin/osascript -e 'tell application "YouTrek" to if it is running then quit' >/dev/null 2>&1 || true
  sleep 1

  if [[ "$BUILD" == true ]]; then
    "$SCRIPT_DIR/prefill_token.sh" --token-file "$TOKEN_FILE" --base-url "$BASE_URL" --no-launch --build
  else
    "$SCRIPT_DIR/prefill_token.sh" --token-file "$TOKEN_FILE" --base-url "$BASE_URL" --no-launch
  fi

  open "$ROOT_DIR/build/DerivedData/Build/Products/Debug/YouTrek.app"
  sleep "$WAIT_SECONDS"
  /usr/bin/osascript -e 'tell application "YouTrek" to if it is running then quit' >/dev/null 2>&1 || true
  sleep 1
done

echo "Log capture complete: $LOG_FILE"
