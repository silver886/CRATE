#!/bin/bash
# session.sh — small read-side helpers for the per-session `owner` KV
# file plus the process-introspection primitives the launcher and
# listing tools both need. Sourced (not executed) by:
#
#   lib/init-launcher.sh  — uses these for ctx capture, liveness, and
#                           reclaim matching during launch
#   script/list-sessions.sh — uses _owner_get and pid-aliveness to
#                           render the listing without re-implementing
#                           the schema
#
# Anything specific to *claiming* a session (locking, atomic write,
# matching against the current launcher's ctx) lives in init-launcher.sh
# alongside the resolver — it's not reusable.

# Read the cmdline of a pid as a single space-collapsed string. Empty
# if the pid is gone or unreadable. Linux exposes /proc/<pid>/cmdline
# (NUL-separated argv); macOS/BSD do not, so fall back to `ps -o
# command=`. Trailing spaces are trimmed so the same live pid produces
# byte-identical output across reads.
_pid_cmdline() {
  _p="$1"
  [ -n "$_p" ] || return 0
  if [ -r "/proc/$_p/cmdline" ]; then
    tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | sed 's/ *$//'
  else
    ps -p "$_p" -o command= 2>/dev/null | sed 's/ *$//'
  fi
}

# Process start-time, stable for the lifetime of the process and
# unique vs PID reuse. Linux: field 22 of /proc/<pid>/stat (start time
# in clock ticks since boot). macOS/BSD: ps -o lstart= (human-readable
# UTC timestamp). The output format differs per platform and we don't
# care — same-process re-reads must be byte-identical, that's all.
_pid_start() {
  _p="$1"
  [ -n "$_p" ] || return 0
  if [ -r "/proc/$_p/stat" ]; then
    awk '{print $22}' "/proc/$_p/stat" 2>/dev/null
  else
    ps -p "$_p" -o lstart= 2>/dev/null | sed 's/  */ /g; s/^ //; s/ $//'
  fi
}

# Read a single field from an `owner` KV file. Splits on the FIRST
# `=`, so values may contain `=` but not newlines (collapsed on write
# by the launcher). Empty if the file or key is missing.
_owner_get() {
  _f="$1"; _k="$2"
  [ -f "$_f" ] || return 0
  awk -v k="$_k" 'BEGIN{FS="="} $1==k {sub(/^[^=]*=/, ""); print; exit}' "$_f" 2>/dev/null
}

# True iff pid is alive AND its start-time matches the recorded one
# AND its cmdline matches the recorded one. The 3-field tuple
# (pid + start + cmd) is unique per process lifetime — same identity
# we already use for VM/distro state markers (see
# script/podman-machine.sh's reclaim_abandoned_machines and
# script/wsl.ps1's distro markers). Cmdline alone is insufficient
# under PID reuse on long-uptime hosts: a recycled pid running the
# same launcher command would be indistinguishable from the original.
# start (Linux: /proc/<pid>/stat field 22; macOS: ps -o lstart=)
# disambiguates because no two processes can share both pid and start.
#
# Backwards-compat fallbacks for legacy owner files:
#   - empty $_expected_start  → fall back to pid + cmdline
#   - empty $_expected_cmd    → fall back to pid-only
_owner_alive() {
  _p="$1"; _expected_start="$2"; _expected_cmd="$3"
  [ -n "$_p" ] || return 1
  kill -0 "$_p" 2>/dev/null || return 1
  if [ -n "$_expected_start" ]; then
    _cur_start=$(_pid_start "$_p")
    [ "$_cur_start" = "$_expected_start" ] || return 1
  fi
  [ -n "$_expected_cmd" ] || return 0
  _cur_cmd=$(_pid_cmdline "$_p")
  [ "$_cur_cmd" = "$_expected_cmd" ]
}
