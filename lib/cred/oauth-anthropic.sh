#!/bin/sh
# oauth-anthropic.sh — Anthropic (Claude Code) OAuth refresh strategy.
# Sourced by ensure-credential.sh. Requires: CRED_PATH, AGENT_OAUTH_JSON, log().
#
# Anthropic tokens are verified by a live call to the claude_cli roles
# endpoint (HTTP 401 → refresh). This is the same approach the Claude
# Code CLI itself uses and tolerates host-clock skew.

cred_check() {
  ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED_PATH")
  if [ -z "$ACCESS_TOKEN" ]; then
    log E cred fail "no OAuth credentials in $CRED_PATH; run 'claude' to authenticate"
    exit 1
  fi

  # Strip curl's default User-Agent to match ps1 HttpClient (no UA header).
  # Anthropic's OAuth endpoints rate-limit curl/* UAs harder than empty —
  # surfaced as 429 on the refresh POST when the same refresh_token works
  # fine from HttpClient (lib/cred/oauth-anthropic.ps1).
  _status=$(curl -sSL -o /dev/null -w "%{http_code}" \
    -H "User-Agent:" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    'https://api.anthropic.com/api/oauth/claude_cli/roles') || _status="000"

  if [ "$_status" = "200" ]; then
    log I cred ok "access token valid"
    return 0
  fi
  if [ "$_status" != "401" ]; then
    log E cred fail "credential check failed (HTTP $_status)"
    exit 1
  fi

  log I cred refresh "access token expired (HTTP 401)"
  REFRESH_TOKEN=$(jq -r '.claudeAiOauth.refreshToken // empty' "$CRED_PATH")
  if [ -z "$REFRESH_TOKEN" ]; then
    log E cred fail "token expired and no refresh token; run 'claude' to re-authenticate"
    exit 1
  fi

  _cid=$(jq -r '.client_id'      "$AGENT_OAUTH_JSON")
  _scope=$(jq -r '.scope'        "$AGENT_OAUTH_JSON")
  _endpoint=$(jq -r '.token_endpoint' "$AGENT_OAUTH_JSON")
  _body=$(jq -nc \
    --arg rt "$REFRESH_TOKEN" \
    --arg cid "$_cid" \
    --arg scope "$_scope" \
    '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid,scope:$scope}')

  # Capture body → tmp file, status → stdout in one call so we can gate on
  # HTTP status before trusting the JSON. Mirrors ps1 IsSuccessStatusCode
  # (lib/cred/oauth-anthropic.ps1:62-65). Without this gate, any non-2xx
  # body is reported as a generic "OAuth refresh failed" with no code.
  #
  # mktemp (not "$$") so a multi-user host can't pre-create the path as a
  # symlink and have curl follow it, and can't read the response body
  # before we delete it. mktemp uses O_CREAT|O_EXCL with mode 600 — the
  # filename is unguessable and unreadable by other local users. The
  # EXIT/INT/HUP/TERM trap is a safety net for SIGTERM-mid-curl scenarios
  # where the explicit `rm -f` after parsing is bypassed.
  _tmp=$(mktemp "${TMPDIR:-/tmp}/cred-anthropic.XXXXXXXX") || {
    log E cred fail "failed to create temp file under ${TMPDIR:-/tmp}"
    exit 1
  }
  trap 'rm -f "$_tmp"' EXIT INT HUP TERM
  _rstatus=$(curl -sSL -o "$_tmp" -w "%{http_code}" -X POST "$_endpoint" \
    -H "User-Agent:" \
    -H 'Content-Type: application/json' \
    -d "$_body") || _rstatus="000"

  case "$_rstatus" in
    2??) ;;
    *)
      log E cred fail "OAuth refresh failed (HTTP $_rstatus); run 'claude' to re-authenticate"
      exit 1
      ;;
  esac

  _new_access=$(jq  -r '.access_token  // empty' "$_tmp")
  _expires_in=$(jq  -r '.expires_in    // empty' "$_tmp")
  _new_refresh=$(jq -r '.refresh_token // empty' "$_tmp")
  rm -f "$_tmp"

  if [ -z "$_new_access" ] || [ -z "$_expires_in" ]; then
    log E cred fail "OAuth refresh response missing access_token or expires_in"
    exit 1
  fi

  _now_ms=$(($(date +%s) * 1000))
  _expires_at=$((_now_ms + _expires_in * 1000))
  _cred_new=$(jq -c \
    --arg at "$_new_access" \
    --argjson ea "$_expires_at" \
    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.expiresAt = $ea' \
    "$CRED_PATH")
  if [ -n "$_new_refresh" ]; then
    _cred_new=$(printf '%s' "$_cred_new" | jq -c --arg rt "$_new_refresh" '.claudeAiOauth.refreshToken = $rt')
  fi
  # cred_inplace_write (lib/common.sh) overwrites the live inode
  # without truncating it first, so hardlinks/junctions/bind mounts
  # to $CRED_PATH stay live AND the file never appears empty during
  # the write window. tmp + JSON validate before touching the live
  # file gates against an upstream that returned a partial body.
  printf '%s' "$_cred_new" | cred_inplace_write "$CRED_PATH"
  log I cred ok "refreshed (expires in ${_expires_in}s)"
}
