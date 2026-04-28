#!/bin/sh
# ensure-credential.sh — multi-agent credential dispatcher.
#
# Sources lib/cred/<strategy>.sh based on the agent manifest's
# credential.strategy field, then invokes cred_check() to verify /
# refresh the auth file in place.
#
# Args: --agent NAME [--log-level I|W|E]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
. "$PROJECT_ROOT/lib/log.sh"
. "$PROJECT_ROOT/lib/common.sh"

AGENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --log-level)
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E cred arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E cred arg-parse "unknown option: $1"; exit 1 ;;
  esac
done
: "${LOG_LEVEL:=W}"

if [ -z "$AGENT" ]; then
  log E cred arg-parse "--agent is required"
  exit 1
fi

. "$PROJECT_ROOT/lib/agent.sh"
agent_load

_strategy=$(agent_get .credential.strategy)
# Allowlist before path construction: a hostile manifest could otherwise
# path-traverse out of lib/cred/ via credential.strategy (e.g.
# '../../etc/evil') and trigger arbitrary host-side code execution when
# the dispatcher dot-sources $_strategy_sh below — well before any
# sandboxing runs.
case "$_strategy" in
  oauth-anthropic|oauth-google|oauth-openai) ;;
  *)
    log E cred fail "unknown credential strategy: $_strategy (allowed: oauth-anthropic, oauth-google, oauth-openai)"
    exit 1
    ;;
esac
_strategy_sh="$PROJECT_ROOT/lib/cred/$_strategy.sh"
if [ ! -f "$_strategy_sh" ]; then
  log E cred fail "credential strategy file missing: $_strategy_sh"
  exit 1
fi

# The auth file the refresh strategy operates on is named explicitly by
# the manifest's `credential.file` (NOT positional in files.rw, which a
# manifest reorder would silently break). It must also appear in
# files.rw so the rest of the launcher (init-config staging) hardlinks
# it into the sandbox.
_cred_file=$(jq -r '.credential.file // empty' "$AGENT_MANIFEST")
if [ -z "$_cred_file" ]; then
  log E cred fail "manifest has no credential.file"
  exit 1
fi
if ! jq -e --arg f "$_cred_file" '.files.rw // [] | index($f) != null' "$AGENT_MANIFEST" >/dev/null; then
  log E cred fail "credential.file '$_cred_file' must also be listed in files.rw"
  exit 1
fi
CRED_PATH="$AGENT_CONFIG_DIR/$_cred_file"
AGENT_OAUTH_JSON="$AGENT_DIR/oauth.json"

log I cred check "$CRED_PATH ($_strategy)"
if [ ! -f "$CRED_PATH" ]; then
  log E cred fail "credentials file not found: $CRED_PATH; use the $AGENT_BINARY CLI to log in on the host"
  exit 1
fi

. "$_strategy_sh"
cred_check
