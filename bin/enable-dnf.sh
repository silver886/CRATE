#!/bin/sh
# enable-dnf.sh — grant the claude user passwordless sudo dnf.
# Runs inside the sandbox as root; called by claude-wrapper.sh.
set -eu

# Inline structured logger — same format, threshold, and color
# semantics as lib/log.sh. LOG_LEVEL is set from `--log-level` arg
# parsing below; never inherited from env. Passed by the caller
# (claude-wrapper.sh) as an explicit arg because sudo env_check
# strips unknown env vars. Colors disabled when $NO_COLOR is set
# or stderr is not a tty.
if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then _LOG_C=1; else _LOG_C=; fi
log() {
  # Normalize LOG_LEVEL to uppercase so `LOG_LEVEL=i` from env (or any
  # future path that forgets to normalize upstream) doesn't silently
  # fall through to the default W threshold and hide I-level logs.
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

if [ "$(id -u)" -ne 0 ]; then
  log E dnf fail "must be run as root"
  exit 1
fi

ENABLE=""
PURGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)       ENABLE=1; shift ;;
    --purge)     PURGE=1; shift ;;
    --log-level)
      # Accept any case — log.sh's threshold case is case-SENSITIVE.
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E dnf arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E dnf arg-parse "unknown option: $1"; exit 1 ;;
  esac
done

if [ -n "$ENABLE" ]; then
  printf 'claude ALL=(root) NOPASSWD: /usr/bin/dnf\n' > /etc/sudoers.d/claude-dnf
  chmod 0440 /etc/sudoers.d/claude-dnf
  log I dnf enabled "passwordless sudo dnf granted to claude"
fi

if [ -n "$PURGE" ]; then
  # Remove the bootstrap sudoers rule so the agent cannot invoke this script later
  rm -f /etc/sudoers.d/claude-enable-dnf
  log I dnf purged "bootstrap sudoers rule removed"
fi
