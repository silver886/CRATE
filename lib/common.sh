#!/bin/sh
# common.sh — cross-cutting constants and helpers shared between the
# launcher init chain (lib/init-launcher.sh → lib/tools.sh) and the
# credential dispatcher (script/ensure-credential.sh → lib/cred/*).
# Sourced; no side effects beyond defining names.

# User-Agent for every HTTP call we make (curl in tools.sh + cred
# strategies). One literal so the value can't drift between Windows
# and POSIX paths or between cred refresh and tool fetches. Mirror of
# $crateUserAgent in lib/Common.ps1.
#
# Anthropic intentionally opts out (lib/cred/oauth-anthropic.sh strips
# curl's default UA with `-H "User-Agent:"`) — its OAuth endpoints
# rate-limit non-empty curl-style UAs harder than empty.
CRATE_USER_AGENT='crate/1.0'

# In-place credential write that preserves hardlinks/junctions/bind
# mounts pointing at $1. Reads payload from stdin.
#
# Strategy: stage payload in a tmp sibling first, validate it parses
# as JSON, then overwrite the live inode using `1<>` (open r/w at
# position 0 — POSIX, no O_TRUNC), follow with truncate(1) to drop
# any old tail, then sync(1). The corruption window is narrower than
# `> $target` because the file never starts the operation empty —
# old content stays intact until each byte is overwritten — and the
# new payload is fully built+validated before we touch the live file.
#
# `__ciw_*` prefixes so this helper doesn't trample callers' `_tmp`
# / `_dir` locals (sh functions have no lexical scoping by default).
cred_inplace_write() {
  __ciw_target="$1"
  __ciw_dir=$(dirname "$__ciw_target")
  __ciw_tmp=$(mktemp "$__ciw_dir/.cred.XXXXXXXX") || {
    log E cred fail "failed to create temp file in $__ciw_dir"
    exit 1
  }
  chmod 600 "$__ciw_tmp" 2>/dev/null
  if ! cat > "$__ciw_tmp"; then
    rm -f "$__ciw_tmp"
    log E cred fail "failed to write tmp credentials at $__ciw_tmp"
    exit 1
  fi
  __ciw_size=$(wc -c < "$__ciw_tmp" | tr -d ' ')
  # `jq empty` (no `-e`) is the documented "is this valid JSON" idiom —
  # exits 0 on a parseable document, non-zero on parse error. `jq -e
  # empty` is a different beast: -e makes jq exit 4 when the filter
  # produces no output (which `empty` always does), so it would mis-
  # report every valid JSON as a parse failure. Combine with an
  # explicit size guard because `jq empty` ALSO exits 0 for a totally
  # empty file (no JSON value at all), which is not what we want here.
  if [ "$__ciw_size" -eq 0 ] || ! jq empty < "$__ciw_tmp" >/dev/null 2>&1; then
    rm -f "$__ciw_tmp"
    log E cred fail "refreshed credentials failed JSON parse (size=$__ciw_size); live file untouched"
    exit 1
  fi
  # `1<>` opens the live file r/w at offset 0 without O_TRUNC. cat
  # streams the validated payload over the existing bytes; truncate
  # then drops any tail when the new payload is shorter than the old.
  if ! cat "$__ciw_tmp" 1<>"$__ciw_target"; then
    rm -f "$__ciw_tmp"
    log E cred fail "in-place write to $__ciw_target failed"
    exit 1
  fi
  truncate -s "$__ciw_size" "$__ciw_target" 2>/dev/null
  sync "$__ciw_target" 2>/dev/null || sync
  rm -f "$__ciw_tmp"
}
