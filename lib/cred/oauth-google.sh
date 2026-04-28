#!/bin/sh
# oauth-google.sh — Google OAuth refresh strategy (Gemini CLI).
# Sourced by ensure-credential.sh. Requires: CRED_PATH, AGENT_OAUTH_JSON, log().
#
# Live-probe: hit the Google userinfo endpoint with the access token in
# a Bearer header. HTTP 200 = valid, HTTP 401 = expired (refresh). This
# avoids timestamp math and tolerates host-clock skew — same approach
# the Anthropic strategy uses.
#
# Auth file schema matches google-auth-library `Credentials`:
#   { access_token, refresh_token, id_token, token_type, scope, expiry_date }

cred_check() {
  ACCESS_TOKEN=$(jq -r '.access_token // empty' "$CRED_PATH")
  if [ -z "$ACCESS_TOKEN" ]; then
    log E cred fail "no OAuth credentials in $CRED_PATH; run 'gemini' to authenticate"
    exit 1
  fi

  _status=$(curl -sSL -o /dev/null -w "%{http_code}" \
    -A "$CRATE_USER_AGENT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    'https://www.googleapis.com/oauth2/v3/userinfo') || _status="000"

  if [ "$_status" = "200" ]; then
    log I cred ok "access token valid"
    return 0
  fi
  if [ "$_status" != "401" ]; then
    log E cred fail "credential check failed (HTTP $_status)"
    exit 1
  fi

  log I cred refresh "access token expired (HTTP 401)"
  _refresh=$(jq -r '.refresh_token // empty' "$CRED_PATH")
  if [ -z "$_refresh" ]; then
    log E cred fail "token expired and no refresh token; run 'gemini' to re-authenticate"
    exit 1
  fi

  _cid=$(jq -r '.client_id'          "$AGENT_OAUTH_JSON")
  _secret=$(jq -r '.client_secret'   "$AGENT_OAUTH_JSON")
  _endpoint=$(jq -r '.token_endpoint' "$AGENT_OAUTH_JSON")

  # url-encode the refresh token. Google issues tokens with slashes and
  # sometimes `+`/`=` — all of which have meaning in form bodies. Use
  # jq's @uri for a POSIX-safe encode (no perl/python dependency).
  _rt_enc=$(printf '%s' "$_refresh" | jq -sRr '@uri')
  _cid_enc=$(printf '%s' "$_cid"    | jq -sRr '@uri')
  _sec_enc=$(printf '%s' "$_secret" | jq -sRr '@uri')

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
  _tmp=$(mktemp "${TMPDIR:-/tmp}/cred-google.XXXXXXXX") || {
    log E cred fail "failed to create temp file under ${TMPDIR:-/tmp}"
    exit 1
  }
  trap 'rm -f "$_tmp"' EXIT INT HUP TERM
  _rstatus=$(curl -sSL -o "$_tmp" -w "%{http_code}" -X POST "$_endpoint" \
    -A "$CRATE_USER_AGENT" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "grant_type=refresh_token&refresh_token=${_rt_enc}&client_id=${_cid_enc}&client_secret=${_sec_enc}") \
    || _rstatus="000"

  case "$_rstatus" in
    2??) ;;
    *)
      log E cred fail "OAuth refresh failed (HTTP $_rstatus); run 'gemini' to re-authenticate"
      exit 1
      ;;
  esac

  _new_access=$(jq -r '.access_token // empty' "$_tmp" 2>/dev/null)
  if [ -z "$_new_access" ]; then
    rm -f "$_tmp"
    log E cred fail "OAuth refresh response missing access_token; run 'gemini' to re-authenticate"
    exit 1
  fi
  # Fall back to Google's documented default access-token lifetime (1h)
  # when the response omits expires_in. expiry_date is kept in sync so
  # google-auth-library's own probes still see a valid-looking stamp.
  # https://developers.google.com/identity/protocols/oauth2#expiration
  _expires_in=$(jq -r '.expires_in // 3600' "$_tmp")
  _new_id=$(jq -r '.id_token // empty' "$_tmp")
  rm -f "$_tmp"
  _now_ms=$(($(date +%s) * 1000))
  _new_expiry=$((_now_ms + _expires_in * 1000))

  _cred_new=$(jq -c \
    --arg at   "$_new_access" \
    --argjson  ea "$_new_expiry" \
    '.access_token = $at | .expiry_date = $ea' \
    "$CRED_PATH")
  if [ -n "$_new_id" ]; then
    _cred_new=$(printf '%s' "$_cred_new" | jq -c --arg it "$_new_id" '.id_token = $it')
  fi
  # See oauth-anthropic.sh for why we use cred_inplace_write instead
  # of `>` redirect or tmp+rename.
  printf '%s' "$_cred_new" | cred_inplace_write "$CRED_PATH"
  log I cred ok "refreshed (expires in ${_expires_in}s)"
}
