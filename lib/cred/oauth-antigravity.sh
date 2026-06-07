#!/bin/sh
# oauth-antigravity.sh — Google OAuth refresh strategy for the
# antigravity-cli agent. Sourced by ensure-credential.sh. Requires:
# CRED_PATH, AGENT_OAUTH_JSON, log().
#
# antigravity-cli authenticates through Google's installed-app OAuth flow
# (PKCE, access_type=offline) against the same token endpoint as Gemini,
# but stores credentials in a different on-disk shape, so it needs its
# own strategy rather than reusing oauth-google.sh:
#
#   { "token": { "access_token", "token_type", "refresh_token",
#                "expiry" (RFC3339 string) },
#     "auth_method": "consumer" }
#
# vs Gemini's flat google-auth-library `Credentials` object with an
# `expiry_date` epoch-ms field. The refresh call is identical
# (client_secret_post: form POST to oauth2.googleapis.com/token); only
# the read/write paths into the JSON differ.
#
# Live-probe: hit the Google v2 userinfo endpoint with the access token
# in a Bearer header. HTTP 200 = valid, HTTP 401 = expired (refresh).
# The access_token is an opaque `ya29.` token (not a JWT), so there's no
# embedded exp to decode; we deliberately do NOT parse the RFC3339
# `expiry` string either — Go's nanosecond + numeric-offset stamp
# (e.g. 2026-06-06T19:45:11.950456377-07:00) is not portably parseable
# across GNU/BSD `date`, and the live probe both tolerates host-clock
# skew and catches server-side revocation. Same approach as
# oauth-google.sh.

cred_check() {
  ACCESS_TOKEN=$(jq -r '.token.access_token // empty' "$CRED_PATH")
  if [ -z "$ACCESS_TOKEN" ]; then
    log E cred fail "no OAuth credentials in $CRED_PATH; run 'antigravity' to authenticate"
    exit 1
  fi

  _status=$(curl -sSL -o /dev/null -w "%{http_code}" \
    -A "$CRATE_USER_AGENT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    'https://www.googleapis.com/oauth2/v2/userinfo') || _status="000"

  if [ "$_status" = "200" ]; then
    log I cred ok "access token valid"
    return 0
  fi
  if [ "$_status" != "401" ]; then
    log E cred fail "credential check failed (HTTP $_status)"
    exit 1
  fi

  log I cred refresh "access token expired (HTTP 401)"
  _refresh=$(jq -r '.token.refresh_token // empty' "$CRED_PATH")
  if [ -z "$_refresh" ]; then
    log E cred fail "token expired and no refresh token; run 'antigravity' to re-authenticate"
    exit 1
  fi

  _cid=$(jq -r '.client_id'           "$AGENT_OAUTH_JSON")
  _secret=$(jq -r '.client_secret'    "$AGENT_OAUTH_JSON")
  _endpoint=$(jq -r '.token_endpoint' "$AGENT_OAUTH_JSON")

  # url-encode the form fields. Google issues tokens with slashes and
  # sometimes `+`/`=` — all of which have meaning in form bodies. Use
  # jq's @uri for a POSIX-safe encode (no perl/python dependency).
  # Mirrors lib/cred/oauth-google.sh.
  _rt_enc=$(printf '%s' "$_refresh" | jq -sRr '@uri')
  _cid_enc=$(printf '%s' "$_cid"    | jq -sRr '@uri')
  _sec_enc=$(printf '%s' "$_secret" | jq -sRr '@uri')

  # Capture body → tmp file, status → stdout in one call so we can gate
  # on HTTP status before trusting the JSON. mktemp (not "$$") so a
  # multi-user host can't pre-create the path as a symlink and have curl
  # follow it, and can't read the response body before we delete it.
  # mktemp uses O_CREAT|O_EXCL with mode 600. Mirrors oauth-google.sh.
  _tmp=$(mktemp "${TMPDIR:-/tmp}/cred-antigravity.XXXXXXXX") || {
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
      log E cred fail "OAuth refresh failed (HTTP $_rstatus); run 'antigravity' to re-authenticate"
      exit 1
      ;;
  esac

  # Read every needed field out of the response before deleting the tmp.
  _new_access=$(jq -r '.access_token // empty' "$_tmp" 2>/dev/null)
  _expires_in=$(jq -r '.expires_in // 3600' "$_tmp")
  _new_refresh=$(jq -r '.refresh_token // empty' "$_tmp")
  rm -f "$_tmp"

  if [ -z "$_new_access" ]; then
    log E cred fail "OAuth refresh response missing access_token; run 'antigravity' to re-authenticate"
    exit 1
  fi
  case "$_expires_in" in ''|*[!0-9]*) _expires_in=3600 ;; esac

  # antigravity stores expiry as an RFC3339 timestamp (Go time.Time).
  # Compute the new expiry as now + expires_in and format it with jq's
  # todateiso8601 — a UTC 'Z' stamp that Go's time.Parse(RFC3339[Nano])
  # accepts, without reproducing the original nanosecond/offset form and
  # without the GNU/BSD `date -d @`/`-r` portability split.
  _now=$(date +%s)
  _expiry=$(jq -nr --argjson now "$_now" --argjson ttl "$_expires_in" '($now + $ttl) | todateiso8601')

  # Update access_token + expiry in place, preserving the rest of the
  # file's shape (token_type, auth_method, account fields the binary may
  # add). Update refresh_token only when Google rotated it — installed-
  # app refreshes usually don't, but persisting a rotated one keeps the
  # next refresh from failing.
  _cred_new=$(jq -c \
    --arg at  "$_new_access" \
    --arg exp "$_expiry" \
    '.token.access_token = $at | .token.expiry = $exp' \
    "$CRED_PATH")
  if [ -n "$_new_refresh" ]; then
    _cred_new=$(printf '%s' "$_cred_new" | jq -c --arg rt "$_new_refresh" '.token.refresh_token = $rt')
  fi
  # See oauth-anthropic.sh for why we use cred_inplace_write instead of
  # a `>` redirect or tmp+rename (preserves the rw/ hardlink into the
  # sandbox and never leaves the live file empty mid-write).
  printf '%s' "$_cred_new" | cred_inplace_write "$CRED_PATH"
  log I cred ok "refreshed (expires in ${_expires_in}s)"
}
