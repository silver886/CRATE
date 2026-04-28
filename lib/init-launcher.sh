#!/bin/bash
# init-launcher.sh — shared launcher initialization.
# Sourced (not executed) by a bash launcher. Requires: PROJECT_ROOT,
# AGENT (set by caller). bash is required because init-config.sh below
# uses bash arrays + read -d '' for NUL-safe iteration.
#
# Sources agent.sh, init-config.sh, tools.sh, then provides
# init_launcher() which runs credential check, session resolution,
# config init, arch detection, and tool archive build.
#
# Caller sets:
#   OPT_BASE_HASH OPT_TOOL_HASH OPT_AGENT_HASH FORCE_PULL AGENT
#   OPT_NEW_SESSION (1 to force fresh session id)
#   OPT_SESSION_ID  (explicit session id to claim)
#
# init_launcher exports SESSION_ID (8-char base36) and SESSION_DIR
# (host path to <projectDir>/.system/sessions/<id>/).

# pipefail so the background curl|tar pipelines in tools.sh fail loudly
# when the upstream curl exits non-zero (set -e alone only checks the
# tail of the pipeline). Sourced into the bash launcher's parent shell.
set -o pipefail

. "$PROJECT_ROOT/lib/log.sh"
. "$PROJECT_ROOT/lib/common.sh"
. "$PROJECT_ROOT/lib/session.sh"
. "$PROJECT_ROOT/lib/agent.sh"
. "$PROJECT_ROOT/lib/init-config.sh"
. "$PROJECT_ROOT/lib/tools.sh"

# 8 chars base36 → 36^8 ≈ 2.82e12 (~41 bits): birthday collision at ~1.7M
# sessions per workdir, plenty for a dev tool. Source: 6 bytes /dev/urandom
# (48 bits) → modulo 36^8 to fit cleanly into 8 base36 digits, then a
# fixed 8-iteration encode loop so we always emit exactly 8 chars (no
# truncation, no leading-zero loss). The modulo bias is 1 part in 2^48,
# negligible. No external deps (drops the prior bc/awk pipeline).
_gen_session_id() {
  _hex=$(od -An -N6 -tx1 < /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$_hex" ] || [ "${#_hex}" -ne 12 ]; then
    log E launcher session-fail "could not read 6 bytes from /dev/urandom"
    exit 1
  fi
  _n=$((16#$_hex % 2821109907456))   # 2821109907456 = 36^8
  _b36="0123456789abcdefghijklmnopqrstuvwxyz"
  _out=""
  for _i in 1 2 3 4 5 6 7 8; do
    _out="${_b36:$((_n % 36)):1}$_out"
    _n=$((_n / 36))
  done
  printf '%s' "$_out"
}

# _pid_cmdline, _pid_start, _owner_get, _owner_alive live in
# lib/session.sh — shared with script/list-sessions.sh.

# Capture the launcher's "context" — the 6 attributes we use both to
# tag a fresh session and to look up an existing one to reclaim.
# Sets CTX_PPID CTX_PPID_START CTX_PPID_CMD CTX_CWD CTX_USER CTX_HOST.
# Same shell tab + same project + same user → identical CTX_* across
# re-launches, which is what makes default reclaim re-attach
# deterministically. Different tab / new login / moved project → at
# least one field changes → fall through to fresh id.
_capture_ctx() {
  CTX_PPID=$PPID
  CTX_PPID_START=$(_pid_start "$PPID")
  CTX_PPID_CMD=$(_pid_cmdline "$PPID")
  CTX_CWD=$PWD
  CTX_USER=$(id -un 2>/dev/null || printf '%s' "${USER:-?}")
  CTX_HOST=$(hostname 2>/dev/null || printf '%s' "${HOSTNAME:-?}")
}

# Write the session's `owner` metadata file atomically. Single file
# with one `key=value` per line — easier to read in one shot than the
# legacy owner.pid + owner.cmd split, and adds the 6 context fields the
# default-reclaim matcher needs. Newlines in values are collapsed to
# spaces so the KV format stays parsable.
#
# `start` is the launcher's own process start token (`_pid_start $$`),
# recorded so liveness can require pid + start + cmd — the same
# 3-field identity the VM/distro state markers already use to defeat
# PID reuse. cmdline alone collides when a recycled pid happens to be
# running the same launcher command.
#
# `created` is the first-claim epoch, preserved verbatim across
# reclaim so it stays the session's birth time. Used as the
# within-tier tiebreak in _reclaim_session ("oldest matching session
# wins"). Re-stamping it on each reclaim would erase that signal.
# A missing `created` on read (legacy session pre-dating this field)
# is treated as 0, which sorts oldest-first and drains it out cleanly.
#
# Caller must have populated CTX_* via _capture_ctx first AND must
# hold the session's .lock dir, since we read-modify-write the file.
_write_owner_file() {
  _f="$1"
  _own_pid=$$
  _own_start=$(_pid_start "$_own_pid")
  _own_cmd=$(_pid_cmdline "$_own_pid" | tr '\n' ' ')
  _ppid_cmd=$(printf '%s' "$CTX_PPID_CMD" | tr '\n' ' ')
  _created=$(_owner_get "$_f" created)
  [ -n "$_created" ] || _created=$(date +%s)
  _tmp=$(mktemp "$_f.tmp.XXXXXXXX")
  {
    printf 'pid=%s\n'        "$_own_pid"
    printf 'start=%s\n'      "$_own_start"
    printf 'cmd=%s\n'        "$_own_cmd"
    printf 'ppid=%s\n'       "$CTX_PPID"
    printf 'ppid_start=%s\n' "$CTX_PPID_START"
    printf 'ppid_cmd=%s\n'   "$_ppid_cmd"
    printf 'cwd=%s\n'        "$CTX_CWD"
    printf 'user=%s\n'       "$CTX_USER"
    printf 'host=%s\n'       "$CTX_HOST"
    printf 'created=%s\n'    "$_created"
  } > "$_tmp"
  mv -f "$_tmp" "$_f"
}

# True iff the session at $1 has an alive owner. Reads the unified
# `owner` file first and falls back to the legacy owner.pid +
# owner.cmd pair so sessions claimed before the schema change still
# get correct liveness.
_session_alive() {
  _dir="$1"
  _p=""; _s=""; _c=""
  if [ -f "$_dir/owner" ]; then
    _p=$(_owner_get "$_dir/owner" pid)
    _s=$(_owner_get "$_dir/owner" start)
    _c=$(_owner_get "$_dir/owner" cmd)
  elif [ -f "$_dir/owner.pid" ]; then
    # Legacy split format predates start recording — _owner_alive will
    # fall back to pid + cmd (or pid-only) when _s is empty.
    _p=$(head -n1 "$_dir/owner.pid" 2>/dev/null)
    [ -f "$_dir/owner.cmd" ] && _c=$(cat "$_dir/owner.cmd" 2>/dev/null)
  fi
  _owner_alive "$_p" "$_s" "$_c"
}

# Compute the reclaim "match tier" of a session against the current
# launcher's CTX_* (must be populated). Lower tier = stronger match.
# Walk the field ladder from most-stable (host) toward most-volatile
# (ppid); the rightmost mismatch determines the tier. The fields are
# ordered by stability so each tier "releases" only as much identity
# as the launch boundary requires.
#
#   1 — exact (all six match — same shell instance / same tab)
#   2 — only ppid mismatch (parallel launches w/ identical ctx; rare)
#   3 — + ppid_start mismatch (closed tab, opened a new one running
#       the same shell program in the same project)
#   4 — + ppid_cmd mismatch (different shell program — bash↔zsh,
#       xterm↔IDE terminal — same project / user / host)
#   5 — cwd mismatch (project directory was moved or renamed; the
#       .system/ tree traveled with it)
#   6 — user mismatch (cross-user reclaim on a shared box; runtime
#       state from another login flows into your sandbox — see README)
#   7 — host mismatch (cross-host reclaim, e.g. project on a network
#       share accessed from another machine — see README)
#
# Sessions without an `owner` file (legacy / corrupt) tier to 7 so
# they can still be reclaimed but only as a last resort.
_session_match_tier() {
  _dir="$1"
  [ -f "$_dir/owner" ] || { printf '7'; return; }
  [ "$(_owner_get "$_dir/owner" host)"       = "$CTX_HOST" ]       || { printf '7'; return; }
  [ "$(_owner_get "$_dir/owner" user)"       = "$CTX_USER" ]       || { printf '6'; return; }
  [ "$(_owner_get "$_dir/owner" cwd)"        = "$CTX_CWD" ]        || { printf '5'; return; }
  [ "$(_owner_get "$_dir/owner" ppid_cmd)"   = "$CTX_PPID_CMD" ]   || { printf '4'; return; }
  [ "$(_owner_get "$_dir/owner" ppid_start)" = "$CTX_PPID_START" ] || { printf '3'; return; }
  [ "$(_owner_get "$_dir/owner" ppid)"       = "$CTX_PPID" ]       || { printf '2'; return; }
  printf '1'
}

# Atomic claim of a session by id. Uses mkdir(2) of a .lock subdir as
# the exclusivity primitive — atomic on every POSIX filesystem we ship
# on (ext4/xfs/btrfs on Linux, APFS/HFS+ on macOS, drvfs on WSL2). After
# winning the lock, re-check owner liveness (a parallel launcher may
# have just claimed it), then write the unified `owner` file.
# Stale-lock recovery: if the lock dir is older than 30s we treat the
# previous claimer as dead and replace it.
#
# Caller must have populated CTX_* via _capture_ctx first (so
# _write_owner_file can stamp the right context).
#
# Returns 0 if claimed, 1 if another launcher owns it (live or racing).
_try_claim_session() {
  _id="$1"; _sd="$2"
  _dir="$_sd/$_id"
  mkdir -p "$_dir"
  if ! mkdir "$_dir/.lock" 2>/dev/null; then
    _lock_mt=$(stat -c '%Y' "$_dir/.lock" 2>/dev/null || stat -f '%m' "$_dir/.lock" 2>/dev/null || echo 0)
    _now=$(date +%s 2>/dev/null || echo 0)
    if [ "$_lock_mt" -gt 0 ] && [ "$_now" -gt 0 ] && [ $((_now - _lock_mt)) -gt 30 ]; then
      rmdir "$_dir/.lock" 2>/dev/null || true
      mkdir "$_dir/.lock" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  if _session_alive "$_dir"; then
    rmdir "$_dir/.lock" 2>/dev/null
    return 1
  fi
  _write_owner_file "$_dir/owner"
  # Drop the legacy split files now that the unified `owner` is the
  # source of truth — keeps the directory tidy and avoids stale data
  # if a future legacy-aware reader ever falls back.
  rm -f "$_dir/owner.pid" "$_dir/owner.cmd"
  rmdir "$_dir/.lock" 2>/dev/null
  return 0
}

# Walk all session dirs and atomically claim the best-matching
# abandoned one. Score each candidate via _session_match_tier (1-7;
# lower = more specific) and break ties on `created` ascending — the
# oldest session in a tier wins because long-lived sessions
# accumulate more agent context (history, mutable settings) and are
# the more likely "main thread of work" to resume. Race-safe: two
# parallel reclaims of the same id are mediated by
# _try_claim_session's mkdir lock; if the top candidate's claim
# loses the race, fall through to the next.
#
# Returns 0 + prints id on success, 1 if no abandoned session
# remains. Tier 7 is the catch-all and matches any abandoned session
# in the workdir, so this only returns 1 when every session in the
# directory is currently live.
_reclaim_session() {
  _dir="$1"
  _candidates=$(
    for _e in "$_dir"/*; do
      [ -d "$_e" ] || continue
      _session_alive "$_e" && continue
      _tier=$(_session_match_tier "$_e")
      _created=$(_owner_get "$_e/owner" created)
      [ -n "$_created" ] || _created=0
      printf '%s\t%s\t%s\n' "$_tier" "$_created" "$(basename "$_e")"
    done | sort -k1,1n -k2,2n
  )
  [ -n "$_candidates" ] || return 1
  # Iterate via here-string so the loop runs in the current shell —
  # otherwise `return` from inside a piped while would only exit the
  # subshell.
  _tab=$(printf '\t')
  while IFS="$_tab" read -r _tier _created _id; do
    [ -n "$_id" ] || continue
    if _try_claim_session "$_id" "$_dir"; then
      printf '%s' "$_id"
      return 0
    fi
  done <<< "$_candidates"
  return 1
}

# Resolve SESSION_ID via three modes (mutually exclusive flags handled
# in the launcher arg parser):
#   OPT_SESSION_ID set  → claim that exact id (must not be live)
#   OPT_NEW_SESSION set → generate fresh id
#   neither (default)   → reclaim the best-matching abandoned session
#                         under the 7-tier match ladder (see
#                         _session_match_tier); within a tier, oldest
#                         `created` wins. Tier 7 is the catch-all, so
#                         any abandoned session in the workdir will be
#                         reclaimed in default mode — pass
#                         --new-session to force a fresh id.
#
# Always writes the unified `owner` KV file (pid, start, cmd, ppid,
# ppid_start, ppid_cmd, cwd, user, host, created). Session dirs
# persist across launches (no cleanup on exit). A session is
# "abandoned" when its recorded pid is dead OR the process at that
# pid no longer matches the recorded start + cmd (PID reuse).
resolve_session_id() {
  _sessions_dir="$PWD/$AGENT_PROJECT_DIR/.system/sessions"
  mkdir -p "$_sessions_dir"
  _capture_ctx

  if [ -n "${OPT_SESSION_ID:-}" ]; then
    case "$OPT_SESSION_ID" in
      [0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z]) ;;
      *) log E launcher arg-parse "--session ID must be 8 lowercase base36 chars (0-9a-z): '$OPT_SESSION_ID'"; exit 1 ;;
    esac
    SESSION_ID="$OPT_SESSION_ID"
    if ! _try_claim_session "$SESSION_ID" "$_sessions_dir"; then
      _opid=$(_owner_get "$_sessions_dir/$SESSION_ID/owner" pid)
      [ -n "$_opid" ] || [ ! -f "$_sessions_dir/$SESSION_ID/owner.pid" ] || \
        _opid=$(head -n1 "$_sessions_dir/$SESSION_ID/owner.pid" 2>/dev/null)
      log E launcher session-busy "session '$SESSION_ID' is in use by pid ${_opid:-?}; pass --new-session for a fresh one or omit --session to reclaim the best-matching abandoned session"
      exit 1
    fi
    log I launcher session "claim $SESSION_ID (explicit)"
  elif [ -n "${OPT_NEW_SESSION:-}" ]; then
    # Generate + atomic-claim. Re-roll on the vanishingly unlikely
    # collision (36^8 space, parallel launches racing).
    _attempts=0
    while :; do
      SESSION_ID=$(_gen_session_id)
      if _try_claim_session "$SESSION_ID" "$_sessions_dir"; then break; fi
      _attempts=$((_attempts + 1))
      if [ "$_attempts" -ge 5 ]; then
        log E launcher session-fail "could not claim a fresh session id after 5 attempts (filesystem locked?)"
        exit 1
      fi
    done
    log I launcher session "new $SESSION_ID (--new-session)"
  else
    SESSION_ID=$(_reclaim_session "$_sessions_dir" || true)
    if [ -n "$SESSION_ID" ]; then
      log I launcher session "reclaim $SESSION_ID"
    else
      _attempts=0
      while :; do
        SESSION_ID=$(_gen_session_id)
        if _try_claim_session "$SESSION_ID" "$_sessions_dir"; then break; fi
        _attempts=$((_attempts + 1))
        if [ "$_attempts" -ge 5 ]; then
          log E launcher session-fail "could not claim a fresh session id after 5 attempts (filesystem locked?)"
          exit 1
        fi
      done
      log I launcher session "new $SESSION_ID (no abandoned session to reclaim)"
    fi
  fi
  SESSION_DIR="$_sessions_dir/$SESSION_ID"
}

init_launcher() {
  agent_load
  log I launcher start "CRATE ($AGENT) $0"
  "$PROJECT_ROOT/script/ensure-credential.sh" --agent "$AGENT" --log-level "${LOG_LEVEL:-W}"
  resolve_session_id
  init_config_dir
  detect_arch
  build_tool_archives
}
