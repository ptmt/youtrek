#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOKEN_FILE="${TOKEN_FILE:-$HOME/.youtrek.token}"
BASE_URL="${YOUTRACK_BASE_URL:-}"
BASE_URL_FILE="${BASE_URL_FILE:-$HOME/.youtrek.base_url}"
BOARD_ID=""
BOARD_NAME=""
SPRINT_ID=""
SPRINT_NAME=""
LOOPS=5
INTERVAL=5
TOP=500

usage() {
  cat <<'USAGE'
Usage: scripts/board_diagnostics_loop.sh [options]

Options:
  --board-id <id>       Agile board ID (required for sprint ID fetch)
  --board-name <name>   Agile board name (required for issue queries)
  --sprint-id <id>      Sprint ID for sprint issue IDs (optional)
  --sprint-name <name>  Sprint name for sprint query (optional)
  --loops <n>           Number of iterations (0 = infinite, default: 5)
  --interval <seconds>  Delay between iterations (default: 5)
  --top <n>             Max issues to fetch per query (default: 500)
  --token-file <path>   Path to file containing token (default: ~/.youtrek.token)
  --base-url <url>      YouTrack base URL (or set YOUTRACK_BASE_URL)
  --base-url-file <path>Path to file containing base URL (default: ~/.youtrek.base_url)
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
    --board-id)
      BOARD_ID="$2"
      shift 2
      ;;
    --board-name)
      BOARD_NAME="$2"
      shift 2
      ;;
    --sprint-id)
      SPRINT_ID="$2"
      shift 2
      ;;
    --sprint-name)
      SPRINT_NAME="$2"
      shift 2
      ;;
    --loops)
      LOOPS="$2"
      shift 2
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    --top)
      TOP="$2"
      shift 2
      ;;
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

BOARD_NAME="$(trim "$BOARD_NAME")"
BOARD_ID="$(trim "$BOARD_ID")"
SPRINT_NAME="$(trim "$SPRINT_NAME")"
SPRINT_ID="$(trim "$SPRINT_ID")"

if [[ -z "$BOARD_NAME" ]]; then
  echo "Missing --board-name"
  exit 1
fi

API_BASE="${BASE_URL%/}"
if [[ "${API_BASE##*/}" != "api" ]]; then
  API_BASE="$API_BASE/api"
fi

json_count() {
  local label="$1"
  python3 - "$label" <<'PY'
import json
import sys

label = sys.argv[1]
raw = sys.stdin.read().strip()
if not raw:
    print(f"{label}: empty response")
    sys.exit(0)
try:
    payload = json.loads(raw)
except Exception as exc:
    snippet = raw.replace("\n", " ")[:200]
    print(f"{label}: JSON error: {exc} | {snippet}")
    sys.exit(0)

items = []
if isinstance(payload, list):
    items = payload
elif isinstance(payload, dict) and isinstance(payload.get("issues"), list):
    items = payload.get("issues")

print(f"{label}: {len(items)}")
PY
}

issue_query() {
  local label="$1"
  local query="$2"
  local response
  response=$(curl -sS --get \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$API_BASE/issues" \
    --data-urlencode "fields=idReadable" \
    --data-urlencode "\$top=$TOP" \
    --data-urlencode "query=$query" \
  ) || response=""
  echo "$response" | json_count "$label"
}

sprint_issue_ids() {
  local label="$1"
  local response
  response=$(curl -sS --get \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$API_BASE/agiles/$BOARD_ID/sprints/$SPRINT_ID" \
    --data-urlencode "fields=issues(idReadable)" \
  ) || response=""
  echo "$response" | json_count "$label"
}

board_query="has: {Board $BOARD_NAME}"
if [[ -n "$SPRINT_NAME" ]]; then
  sprint_query="{Board $BOARD_NAME}: {$SPRINT_NAME}"
else
  sprint_query=""
fi

iteration=1
while true; do
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$timestamp] board=\"$BOARD_NAME\""
  echo "  query: $board_query"
  issue_query "  issues(has board)" "$board_query"
  if [[ -n "$sprint_query" ]]; then
    echo "  query: $sprint_query"
    issue_query "  issues(board+sprint)" "$sprint_query"
  fi
  if [[ -n "$BOARD_ID" && -n "$SPRINT_ID" ]]; then
    sprint_issue_ids "  sprint issue IDs"
  fi
  if [[ "$LOOPS" -ne 0 && "$iteration" -ge "$LOOPS" ]]; then
    break
  fi
  iteration=$((iteration + 1))
  sleep "$INTERVAL"
done
