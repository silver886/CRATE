#!/bin/sh

# Inline structured logger — same format, threshold, and color
# semantics as lib/log.sh. $LOG_LEVEL is NOT inherited from env; it
# is set by --log-level parsing below. Colors disabled when $NO_COLOR
# is set or stderr is not a tty, so log files never get escape bytes.
if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then _LOG_C=1; else _LOG_C=; fi
log() {
  # Normalize LOG_LEVEL to uppercase so a stray lowercase value doesn't
  # silently fall through to the default W threshold and hide I logs.
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

# Parse --log-level off the front of the arg list before forwarding
# the rest to claude. We don't read LOG_LEVEL from env at all: every
# launcher passes the level as an explicit `--log-level X` arg so no
# env var ever leaks across a process boundary or into claude itself.
if [ "${1:-}" = "--log-level" ]; then
  case "${2:-}" in
    I|i) LOG_LEVEL=I ;;
    W|w) LOG_LEVEL=W ;;
    E|e) LOG_LEVEL=E ;;
    *) log E run arg-parse "invalid --log-level: ${2:-} (want I, W, or E)"; exit 1 ;;
  esac
  shift 2
fi
: "${LOG_LEVEL:=W}"

if [ -x /usr/local/lib/claude-code-sandbox/enable-dnf ]; then
  # Pass log level as an explicit arg rather than a preserved env
  # var. Fedora sudoers `env_check` blocks unknown env vars even
  # with --preserve-env=, and adding LOG_LEVEL to env_keep would
  # widen the bootstrap sudoers rule unnecessarily.
  _DNF_LVL="--log-level $LOG_LEVEL"
  if [ -n "${CLAUDE_ENABLE_DNF:-}" ]; then
    sudo /usr/local/lib/claude-code-sandbox/enable-dnf $_DNF_LVL --yes --purge
  else
    sudo /usr/local/lib/claude-code-sandbox/enable-dnf $_DNF_LVL --purge
  fi
fi

export PATH="$HOME/.local/bin:$PATH"
[ -f "$HOME/.shrc" ] && . "$HOME/.shrc"
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

CLAUDE_BIN="$HOME/.local/bin/claude-bin"
[ -x "$CLAUDE_BIN" ] || { log E run fail "claude binary not found at $CLAUDE_BIN"; exit 1; }

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1
export EDITOR=micro

exec "$CLAUDE_BIN" "$@"
