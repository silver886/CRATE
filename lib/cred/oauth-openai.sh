#!/bin/sh
# oauth-openai.sh — OpenAI Codex PKCE public-client refresh strategy.
# Sourced by ensure-credential.sh. Requires: CRED_PATH, AGENT_OAUTH_JSON, log().
#
# Live-probe: hit auth.openai.com/oauth/userinfo with the access token
# in a Bearer header. HTTP 200 = valid, HTTP 401 = expired (refresh).
# Same pattern as Anthropic/Google — tolerant of host-clock skew.
#
# Auth file schema (per codex-rs/login/src/auth/storage.rs +
# token_data.rs custom serde):
#   { auth_mode, tokens: { id_token (JWT string), access_token,
#     refresh_token, account_id? }, last_refresh }
# id_token is stored on disk as the raw JWT string. Codex parses the
# struct fields out of the JWT on load — we don't decode it here.
# PKCE public-client: no client_secret on refresh, and scope is not sent.

cred_check() {
  ACCESS_TOKEN=$(jq -r '.tokens.access_token // empty' "$CRED_PATH")
  if [ -z "$ACCESS_TOKEN" ]; then
    log E cred fail "no OAuth credentials in $CRED_PATH; run 'codex login' to authenticate"
    exit 1
  fi

  _status=$(curl -sSL -o /dev/null -w "%{http_code}" \
    -A "$CRATE_USER_AGENT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    'https://auth.openai.com/oauth/userinfo') || _status="000"

  if [ "$_status" = "200" ]; then
    log I cred ok "access token valid"
    return 0
  fi
  if [ "$_status" != "401" ]; then
    log E cred fail "credential check failed (HTTP $_status)"
    exit 1
  fi

  log I cred refresh "access token expired (HTTP 401)"
  _refresh=$(jq -r '.tokens.refresh_token // empty' "$CRED_PATH")
  if [ -z "$_refresh" ]; then
    log E cred fail "token expired and no refresh token; run 'codex login' to re-authenticate"
    exit 1
  fi

  _cid=$(jq -r '.client_id'           "$AGENT_OAUTH_JSON")
  _endpoint=$(jq -r '.token_endpoint' "$AGENT_OAUTH_JSON")

  _body=$(jq -nc \
    --arg rt "$_refresh" \
    --arg cid "$_cid" \
    '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid}')

  # Capture body → tmp file, status → stdout in one call so we can gate
  # on HTTP status before trusting the JSON. Mirrors lib/cred/oauth-
  # anthropic.sh:54-67 and the .ps1 IsSuccessStatusCode check; without
  # this gate, 429/5xx/proxy-error bodies all collapse into the same
  # generic "re-authenticate" path and hide the real failure.
  #
  # mktemp (not "$$") so a multi-user host can't pre-create the path as a
  # symlink and have curl follow it, and can't read the response body
  # before we delete it. mktemp uses O_CREAT|O_EXCL with mode 600 — the
  # filename is unguessable and unreadable by other local users.
  _tmp=$(mktemp "${TMPDIR:-/tmp}/cred-openai.XXXXXXXX") || {
    log E cred fail "failed to create temp file under ${TMPDIR:-/tmp}"
    exit 1
  }
  trap 'rm -f "$_tmp"' EXIT INT HUP TERM
  _rstatus=$(curl -sSL -o "$_tmp" -w "%{http_code}" -X POST "$_endpoint" \
    -A "$CRATE_USER_AGENT" \
    -H 'Content-Type: application/json' \
    -d "$_body") || _rstatus="000"

  case "$_rstatus" in
    2??) ;;
    *)
      log E cred fail "OAuth refresh failed (HTTP $_rstatus); run 'codex login' to re-authenticate"
      exit 1
      ;;
  esac

  _new_access=$(jq -r '.access_token // empty' "$_tmp")
  _new_id=$(jq     -r '.id_token     // empty' "$_tmp")
  if [ -z "$_new_access" ] || [ -z "$_new_id" ]; then
    rm -f "$_tmp"
    log E cred fail "OAuth refresh response missing access_token or id_token; run 'codex login' to re-authenticate"
    exit 1
  fi
  _new_refresh=$(jq -r '.refresh_token // empty' "$_tmp")
  rm -f "$_tmp"

  # Reuse the lib/log.sh ms-support probe ($_log_has_ms); the launcher
  # chain sources log.sh before this strategy is dispatched. A bare
  # `date … || date …` fallback would silently store an invalid RFC
  # 3339 timestamp on BSD/macOS where `date` prints the literal "%3N"
  # instead of failing.
  if [ -n "${_log_has_ms:-}" ]; then
    _now_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  else
    _now_iso=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  fi
  _cred_new=$(jq -c \
    --arg at  "$_new_access" \
    --arg it  "$_new_id" \
    --arg now "$_now_iso" \
    '.tokens.access_token = $at
     | .tokens.id_token = $it
     | .last_refresh = $now' \
    "$CRED_PATH")
  if [ -n "$_new_refresh" ]; then
    _cred_new=$(printf '%s' "$_cred_new" | jq -c --arg rt "$_new_refresh" '.tokens.refresh_token = $rt')
  fi
  # See oauth-anthropic.sh for why we use cred_inplace_write instead
  # of `>` redirect or tmp+rename.
  printf '%s' "$_cred_new" | cred_inplace_write "$CRED_PATH"
  log I cred ok "refreshed"
}
