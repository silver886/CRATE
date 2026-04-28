#!/usr/bin/env sh
# agent-wrapper.sh — generic launcher wrapper packed into every tier-3
# archive. Sources its per-agent agent-manifest.sh (baked in alongside
# it) to load AGENT_BINARY, the exec_agent_with_flags function, and
# per-agent env exports, then execs the real agent binary.

. /usr/local/lib/crate/log.sh

# Parse --log-level off the front of the arg list before forwarding
# the rest to the agent binary. We don't read LOG_LEVEL from env at
# all: every launcher passes the level as an explicit `--log-level X`
# arg so no env var ever leaks across a process boundary.
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

# Load per-agent manifest (AGENT_BINARY, exec_agent_with_flags, exports).
# Resolve the wrapper's own directory robustly: $0 may be absolute,
# cwd-relative, or a bare basename when invoked via PATH. The agent
# always installs to $HOME/.local/bin, so fall back there if the
# discovered dir doesn't contain the sibling manifest.
_dir=$(dirname -- "$0")
case "$_dir" in
  /*) ;;
  *)  _dir=$(cd -- "$_dir" 2>/dev/null && pwd) ;;
esac
[ -f "${_dir:-}/agent-manifest.sh" ] || _dir="$HOME/.local/bin"
. "$_dir/agent-manifest.sh"

if [ -x /usr/local/lib/crate/enable-dnf ]; then
  # Always call enable-dnf --purge to drop the bootstrap sudoers rule
  # before the agent starts — so the agent can't invoke enable-dnf
  # later to grant itself dnf. Add --yes only when the user opted in
  # with CRATE_ALLOW_DNF=1 (set by the launcher's --allow-dnf flag).
  # Pass log level as an explicit arg: Fedora sudoers env_check
  # strips unknown env vars even with --preserve-env=, and adding
  # LOG_LEVEL to env_keep would widen the bootstrap sudoers rule.
  #
  # Failure here means the bootstrap sudoers rule may still be in
  # place — fail loudly rather than exec the agent with a latent
  # privilege-escalation path still available.
  _DNF_LVL="--log-level $LOG_LEVEL"
  if [ -n "${CRATE_ALLOW_DNF:-}" ]; then
    sudo /usr/local/lib/crate/enable-dnf $_DNF_LVL --yes --purge
  else
    sudo /usr/local/lib/crate/enable-dnf $_DNF_LVL --purge
  fi
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    log E run fail "enable-dnf failed (exit $_rc); bootstrap sudoers rule may not be purged"
    exit "$_rc"
  fi
fi

export PATH="$HOME/.local/bin:$PATH"
[ -f "$HOME/.shrc" ] && . "$HOME/.shrc"
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

export EDITOR=micro

_bin="$_dir/${AGENT_BINARY}-bin"
[ -x "$_bin" ] || { log E run fail "$AGENT_BINARY binary not found at $_bin"; exit 1; }

# Launch flags are baked into exec_agent_with_flags() (defined in
# agent-manifest.sh) as discrete positional arguments so each flag
# preserves its boundary even if it contains whitespace or is empty.
exec_agent_with_flags "$_bin" "$@"
