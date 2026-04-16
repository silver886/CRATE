#!/bin/sh
# setup-tools.sh — extract tool archives and set up the claude binary.
# Usage: setup-tools.sh [--exec] [--log-level I|W|E] <archive.tar.xz>...
#
# Extracts each archive into CLAUDE_BIN_DIR (default: $HOME/.local/bin),
# makes all files executable, then renames the claude binary so the
# shell wrapper (claude-wrapper.sh) can take over the "claude" name.
#
# With --exec, launches claude --dangerously-skip-permissions after setup.
#
# --log-level is passed through to the wrapper under --exec and
# controls our own logger threshold for the extract/done lines.
# LOG_LEVEL is never read from env — every caller passes it as an arg.
set -eu

# Inline structured logger — same format, threshold, and color
# semantics as lib/log.sh. $LOG_LEVEL is a local shell var only, set
# by --log-level parsing below. Colors disabled when $NO_COLOR is set
# or stderr is not a tty, so log files never get escape bytes.
if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then _LOG_C=1; else _LOG_C=; fi
log() {
  _ll=${LOG_LEVEL:-W}
  case "$_ll" in i) _ll=I ;; w) _ll=W ;; e) _ll=E ;; esac
  _t=2; case "$_ll" in I) _t=1 ;; E) _t=3 ;; esac
  _m=1; case "$1"   in W) _m=2 ;; E) _m=3 ;; esac
  [ "$_m" -lt "$_t" ] && return 0
  if [ -n "$_LOG_C" ]; then
    case "$1" in
      I) _lc='\033[1;36mI\033[0m' ;;
      W) _lc='\033[1;33mW\033[0m' ;;
      E) _lc='\033[1;31mE\033[0m' ;;
    esac
    printf '\033[90m%s\033[0m %b \033[32m%-16s\033[0m \033[35m%-14s\033[0m %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$_lc" "$2" "$3" "$4" >&2
  else
    printf '%s %s %-16s %-14s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$4" >&2
  fi
}

LAUNCH=""
_ARCHIVES=""
_ARCHIVE_COUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --exec) LAUNCH=1; shift ;;
    --log-level)
      case "${2:-}" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E archive arg-parse "invalid --log-level: ${2:-} (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) _ARCHIVES="$_ARCHIVES $1"; _ARCHIVE_COUNT=$((_ARCHIVE_COUNT + 1)); shift ;;
  esac
done
: "${LOG_LEVEL:=W}"

BIN_DIR="${CLAUDE_BIN_DIR:-$HOME/.local/bin}"
log I archive extract "$BIN_DIR ($_ARCHIVE_COUNT archives)"
mkdir -p "$BIN_DIR"
# Unquoted expansion intentional: $_ARCHIVES is a space-separated list
# of archive paths (all under the cache dir, no spaces in practice).
for archive in $_ARCHIVES; do
  tar -xJf "$archive" -C "$BIN_DIR/"
done
# Only chmod the known set extracted from the three tool archives —
# `chmod +x "$BIN_DIR"/*` would also flip mode on any pre-existing
# files in $BIN_DIR.
for _f in node rg micro claude-wrapper pnpm uv uvx claude; do
  [ -e "$BIN_DIR/$_f" ] && chmod +x "$BIN_DIR/$_f"
done
mv "$BIN_DIR/claude" "$BIN_DIR/claude-bin"
mv "$BIN_DIR/claude-wrapper" "$BIN_DIR/claude"
log I archive done "$BIN_DIR"

if [ -n "$LAUNCH" ]; then
  log I run launch "$BIN_DIR/claude --log-level $LOG_LEVEL --dangerously-skip-permissions"
  exec "$BIN_DIR/claude" --log-level "$LOG_LEVEL" --dangerously-skip-permissions
fi
