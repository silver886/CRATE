#!/bin/bash
# init-config.sh — stage system-scope agent config into the project's
# <projectDir>/.system directory. Sourced (not executed) by a bash
# launcher (bash arrays + read -d '' are required for NUL-safe iteration).
#
# Requires (from agent.sh):     AGENT_CONFIG_DIR, AGENT_PROJECT_DIR, AGENT_MANIFEST.
# Requires (from init-launcher): SESSION_ID, SESSION_DIR (resolve_session_id).
# Sets:   SYSTEM_DIR
# Sets (bash arrays): CONFIG_FILES, RO_FILES, RO_DIRS
#
# Layout (inside each project being sandboxed):
#
#   $PWD/<projectDir>/             — project scope, untouched
#   $PWD/<projectDir>/.system/     — system scope, managed here
#     ├── ro/                          (shared; wiped + re-copied each launch)
#     ├── rw/                          (shared; wiped + re-linked each launch)
#     ├── .mask/                       (shared; empty dir — masks .system/ from proj scope)
#     └── sessions/<id>/
#         ├── cr/                          (per-session runtime state; persists across launches)
#         └── owner                        (KV: pid, start, cmd, ppid, ppid_start, ppid_cmd,
#                                            cwd, user, host, created; written by
#                                            lib/init-launcher.sh; legacy
#                                            owner.pid/owner.cmd are still read as a fallback)
#
# RW files are hardlinked so writes inside the sandbox propagate to the
# canonical host config. RO files + dirs are copied (wiped each launch,
# protecting the host from in-session mutation). The cr/ bucket is per-
# session so two same-agent launches in one workdir don't share runtime
# state (history, locks, mutable settings).

# Resolve a path through all symlinks to the final target.
_SYMLOOP_MAX=$(getconf SYMLOOP_MAX 2>/dev/null) || _SYMLOOP_MAX=""
case "$_SYMLOOP_MAX" in ''|undefined|-1) _SYMLOOP_MAX=40 ;; esac

_realpath() {
  _p="$1" _n=0
  while [ -L "$_p" ]; do
    _n=$((_n + 1))
    if [ "$_n" -gt "$_SYMLOOP_MAX" ]; then
      log E config fail "symlink chain too deep: $1"; return 1
    fi
    _d=$(cd -P "$(dirname "$_p")" && pwd)
    _p=$(readlink "$_p")
    case "$_p" in /*) ;; *) _p="$_d/$_p" ;; esac
  done
  _d=$(cd -P "$(dirname "$_p")" && pwd)
  printf '%s/%s' "$_d" "$(basename "$_p")"
}

# Assert a symlink-resolved path stays under a trusted root: the
# canonical agent config dir, or any path declared in the manifest's
# `trustedSymlinkRoots` array (canonicalised in agent_load). /etc/...,
# ~/.ssh, browser tokens, etc. all fail by default — the previous
# blanket "all of $HOME" widening let an LLM agent with write access
# to its own config dir plant a symlink to any home-resident secret
# and have it staged into the next session. See code-review-handoff.md
# CR-001. To re-enable a known cross-app layout (e.g. scoop persist
# on Windows), declare it explicitly in the agent manifest.
#
# AGENT_TRUSTED_ROOTS is newline-delimited (entries validated to
# contain no LF/CR in agent_load). Iterate via IFS=newline so paths
# with spaces survive intact — `for x in $var` would split on the
# default IFS otherwise.
_assert_under_config() {
  case "$1" in
    "$_real_config_dir"|"$_real_config_dir"/*) return 0 ;;
  esac
  if [ -n "$AGENT_TRUSTED_ROOTS" ]; then
    _OLD_IFS=$IFS
    IFS='
'
    for _root in $AGENT_TRUSTED_ROOTS; do
      [ -z "$_root" ] && continue
      case "$1" in
        "$_root"|"$_root"/*) IFS=$_OLD_IFS; return 0 ;;
      esac
    done
    IFS=$_OLD_IFS
  fi
  log E config fail "manifest entry resolves outside trusted dirs: $2 -> $1 (must stay under $_real_config_dir or a manifest-declared trustedSymlinkRoots entry)"
  exit 1
}

_stage_ro_file() {
  _src=$(_realpath "$1"); _dest="$2"
  _assert_under_config "$_src" "$1"
  # Create parent dirs first — manifest validation accepts nested
  # entries like `rules/foo/bar.json`, but cp would fail if rw/foo/
  # didn't already exist.
  mkdir -p "$(dirname "$_dest")"
  cp -f "$_src" "$_dest"
}

_stage_rw_file() {
  _src=$(_realpath "$1"); _dest="$2"
  _assert_under_config "$_src" "$1"
  mkdir -p "$(dirname "$_dest")"
  ln -f "$_src" "$_dest" || {
    log E config fail "cannot hardlink $_src -> $_dest (cross-filesystem?); writable config requires same filesystem for host sync"
    exit 1
  }
}

_resolve_dir() { (cd -P "$1" 2>/dev/null && pwd); }

# Walk a source directory (following symlinks per the original
# `cp -RL` intent) into dest, rejecting any entry whose resolved path
# escapes the agent config root. Replaces a bare `cp -RL .` which
# would silently dereference a symlink pointing to /etc/, ~/.ssh/,
# etc. and stage host secrets into the sandbox. find -L returns
# entries by their src-rooted path; _realpath gives the canonical
# resolved path which is what we gate on.
_stage_ro_dir() {
  _src_root="$1"; _dest_root="$2"
  mkdir -p "$_dest_root"
  while IFS= read -r -d '' _entry; do
    _real=$(_realpath "$_entry")
    _assert_under_config "$_real" "$_entry"
    [ "$_entry" = "$_src_root" ] && continue
    _rel=${_entry#"$_src_root"/}
    if [ -d "$_real" ]; then
      mkdir -p "$_dest_root/$_rel"
    elif [ -f "$_real" ]; then
      mkdir -p "$(dirname "$_dest_root/$_rel")"
      cp -f "$_real" "$_dest_root/$_rel"
    fi
  done < <(find -L "$_src_root" -print0)
}

init_config_dir() {
  log I config start "staging $PWD/$AGENT_PROJECT_DIR/.system"
  if [ ! -d "$AGENT_CONFIG_DIR" ]; then
    log E config fail "$AGENT config directory not found: $AGENT_CONFIG_DIR"
    exit 1
  fi

  # Canonical agent config root, resolved through any symlinks. Used by
  # _assert_under_config below to gate every manifest-supplied entry —
  # without this, a symlink in files.{rw,ro,roDirs} could redirect the
  # stage to arbitrary host files (the per-file relative-path check in
  # agent_validate_manifest_paths only validates the manifest string,
  # not the actual symlink target).
  _real_config_dir=$(cd -P -- "$AGENT_CONFIG_DIR" 2>/dev/null && pwd) || {
    log E config fail "$AGENT config directory cannot be canonicalized: $AGENT_CONFIG_DIR"
    exit 1
  }

  SYSTEM_DIR="$PWD/$AGENT_PROJECT_DIR/.system"

  # Warn if the project is a git repo (or worktree) and nothing in
  # .gitignore excludes the system bucket — credentials and per-project
  # session history live there and should not be committed. Match the
  # agent's own project dir ('/.claude/.system', '/.gemini/.system', …)
  # or any parent that already excludes it (e.g. '.claude', '.claude/').
  #
  # Walk upward from $PWD to find the repo top-level: the launcher may
  # run from a subdir of a larger repo (e.g. `~/myrepo/subproj/`), in
  # which case `.system/` is still commit-visible from the parent and
  # the warning must still fire. The previous `[ -e "$PWD/.git" ]` check
  # missed that. Stop at filesystem root. Both regular `.git` dirs and
  # worktree pointer files (`.git` is a regular file) are detected via
  # `-e`. See code-review-handoff.md CR-003.
  #
  # Only `.` needs escaping: agent_load whitelists $AGENT_PROJECT_DIR to
  # [A-Za-z0-9._-]+, so the rest is regex-inert in both rg's Rust regex
  # and ERE. The previous blanket-meta sed (`'s#[][.*^$\\/+?{}()|]#\\&#g'`)
  # tripped BSD sed on macOS — its bracket-expression parser doesn't
  # treat a leading `]` as literal even though POSIX says it should.
  # Keep the rule narrow and portable.
  _pd="$AGENT_PROJECT_DIR"
  _pd_re=$(printf '%s' "$_pd" | sed 's/\./\\./g')
  _has_gitignore_entry() {
    if command -v rg >/dev/null 2>&1; then
      rg -q "^[[:space:]]*/?${_pd_re}(/(\.system)?/?)?[[:space:]]*\$" "$1" 2>/dev/null
    else
      grep -qE "^[[:space:]]*/?${_pd_re}(/(\.system)?/?)?[[:space:]]*\$" "$1" 2>/dev/null
    fi
  }
  _git_top=""
  _walk=$PWD
  while [ -n "$_walk" ]; do
    if [ -e "$_walk/.git" ]; then
      _git_top=$_walk
      break
    fi
    [ "$_walk" = "/" ] && break
    _next=${_walk%/*}
    [ -z "$_next" ] && _next=/
    _walk=$_next
  done
  if [ -n "$_git_top" ] && { [ ! -f "$_git_top/.gitignore" ] || \
       ! _has_gitignore_entry "$_git_top/.gitignore"; }; then
    log W config gitignore "$_git_top/.gitignore does not exclude $_pd/.system/; add a '$_pd/.system/' entry to keep credentials and session history out of commits"
  fi

  mkdir -p "$SYSTEM_DIR/.mask" "$SESSION_DIR/cr"
  # Wipe ro/ AND rw/ each launch so removing or renaming a files.{rw,ro,roDirs}
  # entry doesn't leave a stale alias pointing at host config — for rw/
  # specifically that would mean a dropped credentials file remaining
  # hardlinked into the staging tree (and bind-mounted into the
  # sandbox) on subsequent launches. rw/ entries are hardlinks; rm only
  # decrements the inode's link count and never touches the host
  # original (which keeps its own reference).
  rm -rf "$SYSTEM_DIR/ro" "$SYSTEM_DIR/rw"
  mkdir -p "$SYSTEM_DIR/ro" "$SYSTEM_DIR/rw"

  # Writable files → rw/ (hardlinks).
  CONFIG_FILES=()
  while IFS= read -r -d '' _f; do
    [ -f "$AGENT_CONFIG_DIR/$_f" ] || continue
    CONFIG_FILES+=("$_f")
    _stage_rw_file "$AGENT_CONFIG_DIR/$_f" "$SYSTEM_DIR/rw/$_f"
  done < <(agent_get_list_nul .files.rw)

  # Read-only single files → ro/
  RO_FILES=()
  while IFS= read -r -d '' _f; do
    [ -f "$AGENT_CONFIG_DIR/$_f" ] || continue
    RO_FILES+=("$_f")
    _stage_ro_file "$AGENT_CONFIG_DIR/$_f" "$SYSTEM_DIR/ro/$_f"
  done < <(agent_get_list_nul .files.ro)

  # Read-only directories (recursive copy). Handles both flat dirs
  # (rules/, commands/, …) and nested ones (skills/<name>/<files>)
  # uniformly. _stage_ro_dir walks with symlink-deref but checks each
  # resolved entry stays under $_real_config_dir.
  RO_DIRS=()
  while IFS= read -r -d '' _d; do
    [ -d "$AGENT_CONFIG_DIR/$_d" ] || continue
    _src_dir=$(_resolve_dir "$AGENT_CONFIG_DIR/$_d")
    [ -n "$_src_dir" ] || continue
    _assert_under_config "$_src_dir" "$_d"
    RO_DIRS+=("$_d")
    _stage_ro_dir "$_src_dir" "$SYSTEM_DIR/ro/$_d"
  done < <(agent_get_list_nul .files.roDirs)

  # Per-session cr/ placeholders for the mount points. Use the
  # ${arr[@]+…} guard so set -u doesn't choke on empty arrays in older
  # bash (3.2 on macOS). Reclaimed sessions keep their existing cr/
  # contents — these only create missing entries.
  for _f in ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"} ${RO_FILES[@]+"${RO_FILES[@]}"}; do
    mkdir -p "$(dirname "$SESSION_DIR/cr/$_f")"
    [ -e "$SESSION_DIR/cr/$_f" ] || : > "$SESSION_DIR/cr/$_f"
  done
  for _d in ${RO_DIRS[@]+"${RO_DIRS[@]}"}; do
    mkdir -p "$SESSION_DIR/cr/$_d"
  done
  log I config done "session=$SESSION_ID rw=${#CONFIG_FILES[@]} ro-files=${#RO_FILES[@]} ro-dirs=${#RO_DIRS[@]}"
}
