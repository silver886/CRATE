#!/bin/sh
# oauth-openai.sh — OpenAI Codex PKCE public-client refresh strategy.
# Sourced by ensure-credential.sh. Requires: CRED_PATH, AGENT_OAUTH_JSON, log().
#
# Validity check is two-stage: first decode the access_token AND id_token
# JWTs and refresh pre-emptively when EITHER one is absent or its `exp`
# claim is at/past expiry (Codex itself validates both on load); else live-probe
# auth.openai.com/oauth/userinfo with the access token in a Bearer header
# (HTTP 200 = valid, HTTP 401 = expired → refresh). The probe still runs
# when both JWTs are unexpired, to catch server-side revocation that
# `exp` alone can't see. Same probe pattern as Anthropic/Google.
#
# Auth file schema (per codex-rs/login/src/auth/storage.rs +
# token_data.rs custom serde):
#   { auth_mode, tokens: { id_token (JWT string), access_token,
#     refresh_token, account_id? }, last_refresh }
# id_token is stored on disk as the raw JWT string. Codex parses the
# struct fields out of the JWT on load — we don't decode it here.
# PKCE public-client: no client_secret on refresh, and scope is not sent.

# Extract the `exp` (expiry, Unix seconds) claim from a JWT, or empty
# when the argument is not a well-formed JWT carrying a numeric exp.
# Decode the payload (2nd dot-segment) from base64url: jq's @base64d
# wants the standard alphabet, so translate '-_' → '+/' first; @base64d
# tolerates the missing '=' padding. `numbers` drops a non-numeric exp,
# and `2>/dev/null || true` keeps a malformed token from aborting the
# `set -e` caller — an undecodable token just yields empty and falls
# through to the live probe.
_jwt_exp() {
  _je_payload=${1#*.}            # strip the header segment
  _je_payload=${_je_payload%%.*} # keep the payload, drop the signature
  [ -n "$_je_payload" ] || return 0
  printf '%s' "$_je_payload" | tr '_-' '/+' \
    | jq -Rr '(@base64d | fromjson | .exp | numbers) // empty' 2>/dev/null || true
}

cred_check() {
  ACCESS_TOKEN=$(jq -r '.tokens.access_token // empty' "$CRED_PATH")
  if [ -z "$ACCESS_TOKEN" ]; then
    log E cred fail "no OAuth credentials in $CRED_PATH; run 'codex login' to authenticate"
    exit 1
  fi

  # Codex treats BOTH tokens as expiry-bearing: the access_token
  # authorizes API calls and the id_token carries identity claims Codex
  # validates from the JWT on load. Mirror that — refresh pre-emptively
  # when EITHER JWT's own `exp` is at/past expiry, instead of relying on
  # the userinfo probe, which authenticates only the access_token and
  # can't see a stale id_token at all. Refreshing on an elapsed exp skips
  # a guaranteed-401 round-trip and the brief window where host/server
  # clock skew lets a dying token still probe 200; 60s of slack refreshes
  # marginally early rather than handing the agent a token that expires
  # mid-request. An ABSENT token also forces a refresh — Codex needs both,
  # so a missing one is an incomplete pair to repopulate. A token that is
  # present but carries no decodable numeric exp (opaque / missing claim)
  # is left to the live probe instead; if neither token triggers a
  # refresh, that probe runs unchanged.
  _need_refresh=0
  _now=$(date +%s)
  for _jwt_field in access_token id_token; do
    _jwt_val=$(jq -r ".tokens.$_jwt_field // empty" "$CRED_PATH")
    if [ -z "$_jwt_val" ]; then
      log I cred refresh "$_jwt_field missing; refreshing"
      _need_refresh=1
      continue
    fi
    _exp=$(_jwt_exp "$_jwt_val")
    case "$_exp" in ''|*[!0-9]*) continue ;; esac
    if [ "$_now" -ge $(( _exp - 60 )) ]; then
      log I cred refresh "$_jwt_field jwt exp $(( _exp - _now ))s away (<=60s); refreshing"
      _need_refresh=1
    fi
  done

  if [ "$_need_refresh" -eq 0 ]; then
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
  fi

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
