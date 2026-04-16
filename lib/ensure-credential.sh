#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$(dirname "$SCRIPT_DIR")/lib/log.sh"

# --log-level arg: the launcher calls us with an explicit --log-level
# arg (init_launcher passes `--log-level $LOG_LEVEL`). LOG_LEVEL is
# never inherited from env — every boundary passes it as an arg.
while [ $# -gt 0 ]; do
  case "$1" in
    --log-level)
      # Accept any case and normalize. Downstream consumers
      # (log.sh itself) are case-SENSITIVE.
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E cred arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E cred arg-parse "unknown option: $1"; exit 1 ;;
  esac
done
: "${LOG_LEVEL:=W}"

CRED_PATH="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

log I cred check "$CRED_PATH"

if [ ! -f "$CRED_PATH" ]; then
  log E cred fail "credentials file not found; run 'claude' to authenticate"
  exit 1
fi

ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED_PATH")
if [ -z "$ACCESS_TOKEN" ]; then
  log E cred fail "no OAuth credentials; run 'claude' to authenticate"
  exit 1
fi

TEST_STATUS=$(curl -sSL -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  'https://api.anthropic.com/api/oauth/claude_cli/roles') || TEST_STATUS="000"

if [ "$TEST_STATUS" = "401" ]; then
  log I cred refresh "access token expired (HTTP 401)"
  REFRESH_TOKEN=$(jq -r '.claudeAiOauth.refreshToken // empty' "$CRED_PATH")
  if [ -z "$REFRESH_TOKEN" ]; then
    log E cred fail "token expired and no refresh token; run 'claude' to re-authenticate"
    exit 1
  fi

  OAUTH=$(jq -r '"\(.client_id)\n\(.scope)"' "$(dirname "$SCRIPT_DIR")/config/oauth.json")
  OAUTH_CLIENT_ID=$(printf '%s' "$OAUTH" | head -1)
  OAUTH_SCOPE=$(printf '%s' "$OAUTH" | tail -1)
  BODY=$(jq -nc \
    --arg rt "$REFRESH_TOKEN" \
    --arg cid "$OAUTH_CLIENT_ID" \
    --arg scope "$OAUTH_SCOPE" \
    '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid,scope:$scope}')
  RESPONSE=$(curl -sSL -X POST 'https://platform.claude.com/v1/oauth/token' \
    -H 'Content-Type: application/json' \
    -d "$BODY" 2>/dev/null) || RESPONSE=""
  PARSED=$(printf '%s' "$RESPONSE" | jq -r '"\(.access_token // "")\n\(.expires_in // "")\n\(.refresh_token // "")"' 2>/dev/null)

  NEW_ACCESS=$(printf '%s' "$PARSED" | sed -n '1p')
  if [ -z "$NEW_ACCESS" ]; then
    log E cred fail "OAuth refresh failed; run 'claude' to re-authenticate"
    exit 1
  fi

  EXPIRES_IN=$(printf '%s' "$PARSED" | sed -n '2p')
  if [ -z "$EXPIRES_IN" ]; then
    log E cred fail "OAuth refresh response missing expires_in"
    exit 1
  fi

  NOW_MS=$(($(date +%s) * 1000))
  EXPIRES_AT=$((NOW_MS + EXPIRES_IN * 1000))
  NEW_REFRESH=$(printf '%s' "$PARSED" | sed -n '3p')
  CRED_NEW=$(jq -c \
    --arg at "$NEW_ACCESS" \
    --argjson ea "$EXPIRES_AT" \
    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.expiresAt = $ea' \
    "$CRED_PATH")
  if [ -n "$NEW_REFRESH" ]; then
    CRED_NEW=$(printf '%s' "$CRED_NEW" | jq -c --arg rt "$NEW_REFRESH" '.claudeAiOauth.refreshToken = $rt')
  fi
  printf '%s\n' "$CRED_NEW" > "$CRED_PATH"
  log I cred ok "refreshed (expires in ${EXPIRES_IN}s)"
elif [ "$TEST_STATUS" = "200" ]; then
  log I cred ok "access token valid"
else
  log E cred fail "credential check failed (HTTP $TEST_STATUS)"
  exit 1
fi
