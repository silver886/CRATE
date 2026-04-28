#!/bin/bash
# list-sessions.sh — enumerate CRATE sessions in the current working
# directory across all known agents, or one if `--agent NAME` is given.
#
# Usage: list-sessions.sh [--agent NAME] [--columns COL[,COL...]]
#   --agent NAME       Restrict listing to one agent (claude|codex|gemini).
#                      Default: list every agent that has a session dir.
#   --columns COLS     Comma-separated list of columns to print.
#                      Default: id,agent,age,cwd
#                      Available: id agent state pid cmd ppid ppid_start
#                                 ppid_cmd cwd user host created age
#
# Each agent has its own per-workdir staging dir (see manifest's
# `projectDir`); we walk every agent/<name>/manifest.json under the
# repo, compute the staging path, and list every session under it.
# Liveness uses the shared `_owner_alive` helper from lib/session.sh
# (pid + start + cmdline match) so the displayed `state` matches what
# the launcher would do at reclaim time — start defeats PID reuse on
# long-uptime hosts where the OS pid space wraps and a recycled pid
# could otherwise be tagged `alive` by a pid-only or pid+cmd check.

set -e
PROJECT_ROOT=$(cd -- "$(dirname "$0")/.." && pwd)
. "$PROJECT_ROOT/lib/session.sh"   # _owner_get and process-introspection helpers

# Default columns picked for at-a-glance session identity. Override
# with --columns to surface ctx fields when debugging reclaim
# mismatches.
DEFAULT_COLUMNS="id,agent,age,cwd"
ALL_COLUMNS="id agent state pid cmd ppid ppid_start ppid_cmd cwd user host created age"
OPT_AGENT=""
OPT_COLUMNS="$DEFAULT_COLUMNS"

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   OPT_AGENT="$2";   shift 2 ;;
    --columns) OPT_COLUMNS="$2"; shift 2 ;;
    *) echo "unknown arg: $1 (see header comment for usage)" >&2; exit 1 ;;
  esac
done

if [ -n "$OPT_AGENT" ]; then
  if [ ! -d "$PROJECT_ROOT/agent/$OPT_AGENT" ]; then
    echo "unknown agent: $OPT_AGENT" >&2
    exit 1
  fi
  agents="$OPT_AGENT"
else
  agents=$(ls "$PROJECT_ROOT/agent" 2>/dev/null)
fi

# Validate the requested columns up front so a typo doesn't silently
# render blank fields all the way through the loop. Reject anything
# not in $ALL_COLUMNS.
IFS=',' read -ra COLS <<< "$OPT_COLUMNS"
for c in "${COLS[@]}"; do
  [ -n "$c" ] || continue
  case " $ALL_COLUMNS " in
    *" $c "*) ;;
    *) echo "unknown column: '$c' (available: $ALL_COLUMNS)" >&2; exit 1 ;;
  esac
done

now=$(date +%s 2>/dev/null || echo 0)

# SOH (\x01) as inter-column separator: vanishingly unlikely to occur
# in any session field (paths, cmdlines, hostnames are all printable
# ASCII in practice). Pipe rows to awk which auto-computes column
# widths and pads — no hand-rolled width table, no truncation.
SEP=$'\1'

# Emit one row of $SEP-separated values for the requested columns.
# $1 = header | body. Header writes the uppercase column names.
_emit_row() {
  _mode=$1
  _line=""
  for c in "${COLS[@]}"; do
    [ -n "$c" ] || continue
    if [ "$_mode" = h ]; then
      _v=$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')
    else
      # Bash indirect expansion (not eval) — ROW_* values come from real
      # process command lines / cwds, where a crafted `$(…)` or backtick
      # would shell-execute under eval. $c is already validated against
      # $ALL_COLUMNS above, so the indirect name is constrained.
      _ref="ROW_$c"
      _v=${!_ref:--}
    fi
    _line="$_line$SEP$_v"
  done
  printf '%s\n' "${_line#$SEP}"
}

{
  _emit_row h
  for agent in $agents; do
    manifest="$PROJECT_ROOT/agent/$agent/manifest.json"
    [ -f "$manifest" ] || continue
    if command -v jq >/dev/null 2>&1; then
      projdir=$(jq -r .projectDir "$manifest")
    else
      # Fallback if jq is unavailable (jq is a host requirement, but the
      # listing tool should still work for diagnosis when it's missing).
      projdir=".$agent"
    fi
    # Same single-segment whitelist agent_load applies. Without it a
    # hostile manifest's `.projectDir` (e.g. '../../etc') would
    # traverse out of $PWD and make this tool stat arbitrary host
    # directories. Skip-with-warning instead of exiting so a single
    # bad manifest doesn't blank the entire listing.
    case "$projdir" in
      ''|.|..|*[!A-Za-z0-9._-]*)
        echo "skipping $agent: invalid .projectDir in $manifest: '$projdir' (must match [A-Za-z0-9._-]+)" >&2
        continue
        ;;
    esac
    sdir="$PWD/$projdir/.system/sessions"
    [ -d "$sdir" ] || continue
    for s in "$sdir"/*; do
      [ -d "$s" ] || continue
      ROW_id=$(basename "$s")
      ROW_agent=$agent
      ROW_pid=""; ROW_cmd=""; ROW_ppid=""; ROW_ppid_start=""
      ROW_ppid_cmd=""; ROW_cwd=""; ROW_user=""; ROW_host=""
      ROW_created=""
      _row_start=""
      mt_src="$s"
      if [ -f "$s/owner" ]; then
        ROW_pid=$(_owner_get        "$s/owner" pid)
        _row_start=$(_owner_get     "$s/owner" start)
        ROW_cmd=$(_owner_get        "$s/owner" cmd)
        ROW_ppid=$(_owner_get       "$s/owner" ppid)
        ROW_ppid_start=$(_owner_get "$s/owner" ppid_start)
        ROW_ppid_cmd=$(_owner_get   "$s/owner" ppid_cmd)
        ROW_cwd=$(_owner_get        "$s/owner" cwd)
        ROW_user=$(_owner_get       "$s/owner" user)
        ROW_host=$(_owner_get       "$s/owner" host)
        ROW_created=$(_owner_get    "$s/owner" created)
        mt_src="$s/owner"
      elif [ -f "$s/owner.pid" ]; then
        ROW_pid=$(head -n1 "$s/owner.pid" 2>/dev/null)
        [ -f "$s/owner.cmd" ] && ROW_cmd=$(cat "$s/owner.cmd" 2>/dev/null)
        mt_src="$s/owner.pid"
      fi
      if _owner_alive "$ROW_pid" "$_row_start" "$ROW_cmd"; then
        ROW_state="alive"
      else
        ROW_state="dead"
      fi
      mt=$(stat -c '%Y' "$mt_src" 2>/dev/null || stat -f '%m' "$mt_src" 2>/dev/null || echo "$now")
      if [ "$now" -gt 0 ] && [ "$mt" -gt 0 ]; then
        secs=$((now - mt))
        if   [ "$secs" -lt 60 ];     then ROW_age="${secs}s"
        elif [ "$secs" -lt 3600 ];   then ROW_age="$((secs / 60))m"
        elif [ "$secs" -lt 86400 ];  then ROW_age="$((secs / 3600))h"
        else                              ROW_age="$((secs / 86400))d"
        fi
      else
        ROW_age="?"
      fi
      _emit_row b
    done
  done
} | awk -v FS="$SEP" '
  # Two-pass: first record widths and stash all cells, then print
  # padded. Same idiom as `column -t` but POSIX-portable (no util-linux
  # column dependency). Empty fields render as "-" so blank columns
  # stay visible.
  {
    if (NF > maxnf) maxnf = NF
    for (i = 1; i <= NF; i++) {
      v = ($i == "") ? "-" : $i
      if (length(v) > w[i]) w[i] = length(v)
      cell[NR, i] = v
    }
    nrows = NR
  }
  END {
    for (r = 1; r <= nrows; r++) {
      for (i = 1; i <= maxnf; i++) {
        printf "%-*s%s", w[i], cell[r, i], (i == maxnf ? "\n" : "  ")
      }
    }
  }
'
