#!/bin/sh
# log.sh — structured logger for launcher and lib scripts. Sourced
# (not executed). Provides `log` with a fixed-width 5-column format:
#
#   <TS>                     <LVL> <STAGE>          <EVENT>        <MSG>
#   2026-04-14T15:04:05.123Z I     tools.base       cache-hit      base-2e029a8…
#
# Columns (fixed width — every line has identical layout regardless
# of how long the launcher has been running, what host it's on, etc):
#   TS       — RFC 3339 UTC timestamp with millisecond precision
#              (`yyyy-MM-ddTHH:mm:ss.fffZ`, always 24 chars). We use
#              `.000`-style fixed three-digit ms rather than Go's
#              `.999` (which strips trailing zeros) so the column
#              width is constant.
#   LVL      — single char: I (info) | W (warn) | E (error)
#   STAGE    — top-level area (cred, config, tools.base, image, vm,
#              distro, mounts, run, launcher, …) padded to 16. Sized
#              with headroom over the longest current stage so future
#              stages don't desync the message column.
#   EVENT    — verb (cache-hit, cache-pin, downloading, packing,
#              cached, start, done, ok, skip, fail, …) padded to 14
#   MSG      — free-form trailing string
#
# All output goes to stderr so stdout pipelines from the launchers
# stay clean.

# Probe sub-second support. POSIX `date +%N` is a GNU extension; BSD
# date returns the literal "N". On BSD-only hosts we fall back to a
# literal `.000` so the column width is preserved.
_log_probe=$(date +%3N 2>/dev/null)
case "$_log_probe" in
  ''|N|*[!0-9]*) _log_has_ms="" ;;
  *)             _log_has_ms=1 ;;
esac
unset _log_probe

if [ -n "$_log_has_ms" ]; then
  _log_ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
else
  _log_ts() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
fi

# ── ANSI color setup ──
#
# Each column gets its own hue so the eye can scan vertically:
#   TS    gray    (90)        — visually recedes; you only read it
#                               when correlating with another log
#   LVL   bold per-level      — I cyan, W yellow, E red, all bold
#                               so error rows pop in a wall of text
#   STAGE green   (32)        — "where it happened"
#   EVENT magenta (35)        — "what happened"
#   MSG   default             — free-form, terminal default color
#
# Probed once at sourcing time. Disabled when:
#   - $NO_COLOR is set (https://no-color.org/), or
#   - stderr (fd 2) is not a tty (piped to a file / captured)
# In the disabled case, the format degrades to the original
# uncolored fixed-width layout — no escape bytes leak into logs.
if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then
  _LOG_C=1
else
  _LOG_C=
fi

# Threshold filtering reads `$LOG_LEVEL` as a plain shell variable
# (not an env var) — it lives in the launcher process and dies with
# it. LOG_LEVEL is NEVER exported as an env var or passed via
# `--env` / `env VAR=…`. Every process boundary uses an explicit
# `--log-level X` arg so the env is never polluted:
#
#   ensure-credential.sh   ./lib/ensure-credential.sh --log-level $LOG_LEVEL
#   podman container       setup-tools.sh parses --log-level from CMD tail
#   podman machine ssh     /tmp/setup-tools.sh --log-level $LOG_LEVEL …
#   wsl -u root            sh $wslSetup --log-level $LogLevel …
#   sudo (in sandbox)      enable-dnf.sh --log-level $LOG_LEVEL
#
# Each bin/* script parses --log-level into its own local LOG_LEVEL
# shell var for the inline logger. No env var inheritance is involved.
#
# Levels:
#   LOG_LEVEL=I   show everything (verbose; opt-in)
#   LOG_LEVEL=W   show warnings + errors (default; quiet on success)
#   LOG_LEVEL=E   show errors only
#
# $LOG_LEVEL is read on every call so the launcher can parse
# --log-level after sourcing this file.

# log <lvl> <stage> <event> <message>
log() {
  # Normalize to uppercase so a stray lowercase value doesn't silently
  # fall through to the default W threshold. Matches the inline loggers
  # in bin/*.sh which do the same normalization.
  _ll=${LOG_LEVEL:-W}
  case "$_ll" in i) _ll=I ;; w) _ll=W ;; e) _ll=E ;; esac
  _t=2; case "$_ll" in I) _t=1 ;; E) _t=3 ;; esac
  _m=1; case "$1"               in W) _m=2 ;; E) _m=3 ;; esac
  [ "$_m" -lt "$_t" ] && return 0
  if [ -n "$_LOG_C" ]; then
    # Pre-build the colored level cell as a single %b arg so the
    # rest of the format string can stay constant. %-16s/%-14s pad
    # the *visible* text before the trailing reset escape, so column
    # alignment is preserved while invisible escape bytes ride along
    # outside the padding window.
    case "$1" in
      I) _lc='\033[1;36mI\033[0m' ;;
      W) _lc='\033[1;33mW\033[0m' ;;
      E) _lc='\033[1;31mE\033[0m' ;;
    esac
    printf '\033[90m%s\033[0m %b \033[32m%-16s\033[0m \033[35m%-14s\033[0m %s\n' \
      "$(_log_ts)" "$_lc" "$2" "$3" "$4" >&2
  else
    printf '%s %s %-16s %-14s %s\n' "$(_log_ts)" "$1" "$2" "$3" "$4" >&2
  fi
}
