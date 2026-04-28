#!/bin/sh
# agent.sh — manifest loader for multi-agent sandbox.
# Sourced (not executed). Requires: PROJECT_ROOT, AGENT (from launcher)
# Requires jq on the host (already required by ensure-credential).
#
# Sets after agent_load:
#   AGENT_DIR           — $PROJECT_ROOT/agent/$AGENT
#   AGENT_MANIFEST      — path to manifest.json
#   AGENT_BINARY        — e.g. "claude"
#   AGENT_PROJECT_DIR   — e.g. ".claude" (host staging dir base)
#   AGENT_CONFIG_DIR    — expanded host config dir path (respects env override)
#   CRATE_DIR           — in-sandbox config dir (mount target)
#   CRATE_ENV           — name of the env var the wrapper exports inside
#                         the sandbox to point the agent at CRATE_DIR
#                         (empty for agents without such an env var)
#
# Sandbox-side path policy:
#   - If the manifest declares configDir.env (Claude CLAUDE_CONFIG_DIR,
#     Codex CODEX_HOME, …) we stage config at a fixed system path
#     /usr/local/etc/crate/<agent> and set that env var in the
#     wrapper so the binary reads from there. Keeps /home/agent clean
#     and removes the podman-machine /home/agent→/home/core rewrite
#     for agents that honor the env.
#   - Otherwise we mount the staged config directly at the agent's
#     hard-coded default path (with $HOME=/home/agent).
#
# Helpers:
#   agent_get <jq-expr>          — single string value (empty if missing)
#   agent_get_list <jq-expr>     — space-joined array elements
#   agent_get_list_nul <jq-expr> — NUL-terminated array elements (read -d '')
#   agent_get_kv <jq-expr>       — space-joined K=V pairs from an object

agent_load() {
  # Validate AGENT before it joins a path. Same single-segment whitelist
  # as the manifest fields below; otherwise '../foo' as --agent would
  # escape $PROJECT_ROOT/agent/ and point us at an arbitrary sibling
  # manifest.json/oauth.json before any later check could catch it.
  case "$AGENT" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      log E launcher fail "invalid --agent value: '$AGENT' (must match [A-Za-z0-9._-]+ and not be '.' or '..')"
      exit 1
      ;;
  esac
  AGENT_DIR="$PROJECT_ROOT/agent/$AGENT"
  AGENT_MANIFEST="$AGENT_DIR/manifest.json"
  if [ ! -f "$AGENT_MANIFEST" ]; then
    log E launcher fail "unknown agent: $AGENT (no $AGENT_MANIFEST)"
    exit 1
  fi

  # Both values flow into host paths, mount targets, and (via
  # AGENT_BINARY) remote shell strings (ssh / sh -c) where SSH/wsl
  # require a single command string and there is no argv to escape
  # into. Whitelist alphanumerics + `.` `_` `-`; reject empty, '.',
  # '..', and anything else, so a hostile manifest can't smuggle
  # path-traversal or shell metachars across that boundary.
  AGENT_BINARY=$(agent_get .binary)
  case "$AGENT_BINARY" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      log E launcher fail "invalid .binary in $AGENT_MANIFEST: '$AGENT_BINARY' (must match [A-Za-z0-9._-]+ and not be '.' or '..')"
      exit 1
      ;;
  esac
  AGENT_PROJECT_DIR=$(agent_get .projectDir)
  case "$AGENT_PROJECT_DIR" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      log E launcher fail "invalid .projectDir in $AGENT_MANIFEST: '$AGENT_PROJECT_DIR' (must be a single safe relative segment like '.claude')"
      exit 1
      ;;
  esac

  # Resolve the host-side config dir: respect the per-agent env override
  # if the manifest declares one AND it's set; else expand the default.
  # Validate the env name against the POSIX shell-name grammar
  # ([A-Za-z_][A-Za-z0-9_]*) and look it up via `printenv` rather than
  # `eval`. A malicious manifest could otherwise smuggle shell through
  # configDir.env (e.g. "$(rm -rf ~)") and run it on the host before
  # the sandbox is even built.
  _env_name=$(agent_get .configDir.env)
  _default=$(agent_get .configDir.default)
  AGENT_CONFIG_DIR=""
  _config_dir_from_env=""
  if [ -n "$_env_name" ]; then
    case "$_env_name" in
      [A-Za-z_]*)
        # Reject anything outside [A-Za-z0-9_] in any position.
        case "$_env_name" in
          *[!A-Za-z0-9_]*)
            log E launcher fail "invalid configDir.env in $AGENT_MANIFEST: '$_env_name' (must match [A-Za-z_][A-Za-z0-9_]*)"
            exit 1
            ;;
        esac
        AGENT_CONFIG_DIR=$(printenv -- "$_env_name" 2>/dev/null || true)
        # Mark the source so the containment policy below can give env-
        # supplied paths a wider allowlist (user environment is trusted)
        # than manifest-supplied defaults (must stay under $HOME).
        [ -n "$AGENT_CONFIG_DIR" ] && _config_dir_from_env=1
        ;;
      *)
        log E launcher fail "invalid configDir.env in $AGENT_MANIFEST: '$_env_name' (must match [A-Za-z_][A-Za-z0-9_]*)"
        exit 1
        ;;
    esac
  fi
  if [ -z "$AGENT_CONFIG_DIR" ]; then
    # Expand $HOME (and only $HOME) in default. Manifest authors can't
    # sneak arbitrary vars through — we hard-substitute a single token.
    case "$_default" in
      '$HOME'*) AGENT_CONFIG_DIR="$HOME${_default#\$HOME}" ;;
      *)        AGENT_CONFIG_DIR="$_default" ;;
    esac
  fi

  # Canonicalise the resolved config dir. `cd -P` collapses '..'/'.'
  # and follows symlinks, so '$HOME/../etc' or a layout where
  # '$HOME/.claude' is a symlink to '/var/secrets' surfaces as the
  # real target before we apply containment.
  #
  # First-run is fine: a brand-new install has no config dir yet, but
  # the user-facing "use the <agent> CLI to log in on the host" hint
  # is owned by ensure-credential.sh (which runs next in the launcher
  # chain). Failing here on a missing dir would short-circuit that
  # message with a generic canonicalisation error. Walk up to the
  # nearest existing ancestor instead, canonicalise that, and re-
  # append the missing tail so the containment policy below still
  # applies.
  if [ -d "$AGENT_CONFIG_DIR" ]; then
    _canon=$(cd -P -- "$AGENT_CONFIG_DIR" 2>/dev/null && pwd) || {
      log E launcher fail "agent config dir cannot be canonicalised: $AGENT_CONFIG_DIR"
      exit 1
    }
  else
    _head=$AGENT_CONFIG_DIR
    _tail=""
    while [ -n "$_head" ] && [ "$_head" != "/" ] && [ ! -d "$_head" ]; do
      _seg=${_head##*/}
      case "$_head" in
        */*) _head=${_head%/*}; [ -z "$_head" ] && _head=/ ;;
        *)   _head="" ;;
      esac
      if [ -n "$_tail" ]; then _tail="$_seg/$_tail"; else _tail=$_seg; fi
    done
    if [ -z "$_head" ] || [ ! -d "$_head" ]; then
      log E launcher fail "agent config dir cannot be canonicalised (no existing ancestor): $AGENT_CONFIG_DIR"
      exit 1
    fi
    _canon_head=$(cd -P -- "$_head" 2>/dev/null && pwd) || {
      log E launcher fail "agent config dir ancestor cannot be canonicalised: $_head"
      exit 1
    }
    if [ "$_canon_head" = "/" ]; then
      _canon="/$_tail"
    else
      _canon="$_canon_head/$_tail"
    fi
  fi

  # Reject filesystem root only — a malformed manifest like
  # `default="/"` or env override `=/` would otherwise let later
  # stage operations roam the whole disk. We don't gate the
  # individual segment characters here: AGENT_CONFIG_DIR is host-
  # side, used only with proper argv-quoting in [-f]/[-d]/cp/ln/jq
  # invocations and never interpolated into ssh / sh -c / wsl
  # command strings, so spaces and other normally-shell-sensitive
  # characters in absolute paths (e.g. macOS '/Users/Jane Doe/.claude')
  # are safe to allow. Traversal is already collapsed by `cd -P`.
  if [ -z "$_canon" ] || [ "$_canon" = "/" ]; then
    log E launcher fail "agent config dir resolves to filesystem root: $AGENT_CONFIG_DIR"
    exit 1
  fi

  # Containment policy:
  #   - Manifest-supplied default → must canonicalise under $HOME so a
  #     hostile manifest can't relocate the staging root to /etc, /var,
  #     etc. (the per-file relative-path checks would otherwise resolve
  #     under the attacker-chosen base).
  #   - Env-supplied override → any absolute path. Env vars are part of
  #     the user's trusted environment; a user who deliberately exports
  #     CLAUDE_CONFIG_DIR=/srv/agents/claude has chosen that location.
  if [ -z "$_config_dir_from_env" ]; then
    _canon_home=$(cd -P -- "$HOME" 2>/dev/null && pwd) || _canon_home=$HOME
    case "$_canon" in
      "$_canon_home"|"$_canon_home"/*) ;;
      *)
        log E launcher fail "manifest configDir.default must canonicalise under \$HOME ($_canon_home), got: $_canon"
        exit 1
        ;;
    esac
  fi

  # Use the canonical form everywhere downstream. Eliminates symlink/'..'
  # ambiguity in later prefix checks (e.g. _assert_under_config in
  # init-config.sh).
  AGENT_CONFIG_DIR=$_canon

  CRATE_ENV="$_env_name"
  if [ -n "$_env_name" ]; then
    CRATE_DIR="/usr/local/etc/crate/$AGENT"
  else
    case "$_default" in
      '$HOME'*) CRATE_DIR="/home/agent${_default#\$HOME}" ;;
      *)        CRATE_DIR="$_default" ;;
    esac
  fi

  agent_validate_manifest_paths
}

# Validate every manifest-supplied relative path (files.rw, files.ro,
# files.roDirs entries, plus credential.file) in a single jq pass.
# A hostile manifest could otherwise smuggle '../etc/passwd' into the
# files lists — init-config.sh would happily hardlink it into the
# sandbox stage; ensure-credential.sh would read/overwrite the host
# file. Validation lives here (in the shared loader) so both the bash
# launcher chain and the standalone POSIX `ensure-credential.sh` get
# the same check before any path use.
#
# Allowed: relative paths whose every '/'-delimited segment matches
# [A-Za-z0-9._-]+ and is not '.' or '..'. Rejects empty strings,
# absolute paths, backslashes, control chars, and traversal segments.
# Validation runs entirely inside jq so embedded newlines/tabs in a
# crafted entry can't slip past shell-side splitting.
agent_validate_manifest_paths() {
  _bad=$(jq -r '
    def safe:
      type == "string"
      and length > 0
      and (split("/") | all(. != "" and . != "." and . != ".." and test("^[A-Za-z0-9._-]+$")));
    [(.files.rw // [])[],
     (.files.ro // [])[],
     (.files.roDirs // [])[],
     (.credential.file // empty)]
    | map(select(safe | not))
    | (.[0] // null) | tojson
  ' "$AGENT_MANIFEST")
  if [ "$_bad" != "null" ]; then
    log E launcher fail "$AGENT_MANIFEST has unsafe path entry: $_bad (allowed: relative paths with [A-Za-z0-9._-] segments, no '.' / '..' / absolute / empty)"
    exit 1
  fi
}

agent_get()      { jq -r "$1 // empty"            "$AGENT_MANIFEST"; }
agent_get_list() { jq -r "$1 // [] | join(\" \")" "$AGENT_MANIFEST"; }
agent_get_kv()   { jq -r "$1 // {} | to_entries | map(\"\(.key)=\(.value)\") | join(\" \")" "$AGENT_MANIFEST"; }

# NUL-delimited variant for callers that need to handle filenames with
# whitespace, quotes, or other shell metacharacters. Pipe into:
#   while IFS= read -r -d '' x; do …; done < <(agent_get_list_nul .files.rw)
# Each element is followed by a NUL byte; empty list emits nothing.
agent_get_list_nul() {
  jq -j "$1 // [] | map(. + \"\\u0000\") | add // \"\"" "$AGENT_MANIFEST"
}
