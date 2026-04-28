#!/bin/bash
# setup-system-mounts.sh — assemble the agent's in-sandbox config dir
# from a project's $PWD/<projectDir>/.system/{ro,rw,cr} layout, and
# bind-mask .system/ from project scope using the empty .system/.mask.
#
# Run as root inside the sandbox (via `sudo` on the VM/WSL backends —
# the agent itself NEVER runs as root). Container backends do not need
# this script: podman -v flags do the equivalent assembly directly.
#
# Args:
#   --workdir     DIR    host workdir mount point (default: /var/workdir)
#   --project-dir NAME   agent's project dir basename, e.g. ".claude",
#                        ".gemini", ".codex"
#   --session-id  ID     8-char base36 session id (resolved on host).
#                        Selects which sessions/<id>/cr/ to bind as base.
#   --target      DIR    sandbox config dir (e.g. /usr/local/etc/crate/claude
#                        when the agent honors a config-dir env var, or
#                        /home/agent/.gemini for agents that don't)
#   --config-files B64   base64 of NUL-delimited rw file basenames
#   --ro-files    B64    base64 of NUL-delimited ro file basenames
#   --ro-dirs     B64    base64 of NUL-delimited ro dir  basenames
#   --log-level   I|W|E  log threshold. Passed as an arg (not env) because
#                        sudo env_check strips unknown LOG_LEVEL values on
#                        Fedora CoreOS even with --preserve-env=LOG_LEVEL.
#
# Each list value is base64-encoded so it survives SSH/WSL command-string
# interpolation as opaque ASCII; once decoded, items are split on NUL so
# filenames containing spaces/quotes/newlines round-trip exactly. Empty
# values decode to an empty array.
#
# Assembly steps (same rationale as before — see plan doc):
#   1. mkdir target
#   2. bind cr/ as base  (runtime writes land back in host cr/)
#   3. per-file rw overlay — bind rw/$f → target/$f  (EBUSY → in-place
#      writeFileSync → hardlink preserved → host sync)
#   4. per-file/per-subdir ro overlay — bind + remount,bind,ro
#   5. mask project-scope .system by bind-mounting .system/.mask over it
set -euo pipefail

. /usr/local/lib/crate/log.sh

WORKDIR=/var/workdir
PROJECT_DIR=""
SESSION_ID=""
TARGET=""
_CF_B64=""
_RF_B64=""
_RD_B64=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir)      WORKDIR="$2"; shift 2 ;;
    --project-dir)  PROJECT_DIR="$2"; shift 2 ;;
    --session-id)   SESSION_ID="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --config-files) _CF_B64="$2"; shift 2 ;;
    --ro-files)     _RF_B64="$2"; shift 2 ;;
    --ro-dirs)      _RD_B64="$2"; shift 2 ;;
    --log-level)
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E mounts arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E mounts arg-parse "unknown option: $1"; exit 1 ;;
  esac
done
: "${LOG_LEVEL:=W}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TARGET" ] || [ -z "$SESSION_ID" ]; then
  log E mounts arg-parse "--project-dir, --target, and --session-id are required"
  exit 1
fi
case "$SESSION_ID" in
  [0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z]) ;;
  *) log E mounts arg-parse "--session-id must be 8 lowercase base36 chars: '$SESSION_ID'"; exit 1 ;;
esac

# Decode base64 → NUL-delimited bytes → bash array. Empty input ⇒ empty
# array (skipping the read loop entirely so set -u doesn't choke on a
# missing variable in older bash).
CONFIG_FILES=()
RO_FILES=()
RO_DIRS=()
if [ -n "$_CF_B64" ]; then
  while IFS= read -r -d '' _f; do CONFIG_FILES+=("$_f"); done \
    < <(printf '%s' "$_CF_B64" | base64 -d)
fi
if [ -n "$_RF_B64" ]; then
  while IFS= read -r -d '' _f; do RO_FILES+=("$_f"); done \
    < <(printf '%s' "$_RF_B64" | base64 -d)
fi
if [ -n "$_RD_B64" ]; then
  while IFS= read -r -d '' _d; do RO_DIRS+=("$_d"); done \
    < <(printf '%s' "$_RD_B64" | base64 -d)
fi

SYSTEM="$WORKDIR/$PROJECT_DIR/.system"
SESSION_CR="$SYSTEM/sessions/$SESSION_ID/cr"

log I mounts start "target=$TARGET source=$SESSION_CR"

mkdir -p "$TARGET"

_rollback_mounts() {
  umount -R "$TARGET" 2>/dev/null || true
  umount -R "$SYSTEM" 2>/dev/null || true
}

_ASSEMBLED=0
trap '
  if [ "$_ASSEMBLED" = 0 ]; then
    log W mounts rollback "partial assembly; unwinding binds"
    _rollback_mounts
  fi
' EXIT

if mountpoint -q "$TARGET" 2>/dev/null; then
  _complete=1
  for _f in ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"} ${RO_FILES[@]+"${RO_FILES[@]}"}; do
    mountpoint -q "$TARGET/$_f" 2>/dev/null || { _complete=0; break; }
  done
  if [ "$_complete" = 1 ]; then
    for _d in ${RO_DIRS[@]+"${RO_DIRS[@]}"}; do
      mountpoint -q "$TARGET/$_d" 2>/dev/null || { _complete=0; break; }
    done
  fi
  if [ "$_complete" = 1 ] && mountpoint -q "$SYSTEM" 2>/dev/null; then
    log I mounts skip "$TARGET fully assembled"
    _ASSEMBLED=1
    exit 0
  fi
  log W mounts partial "$TARGET partially assembled; tearing down"
  _rollback_mounts
fi

# Step 2: per-session cr/ as the base mount.
mount --bind "$SESSION_CR" "$TARGET"

# Step 3: writable file overlay.
# Manifest validation allows nested entries (e.g. `rules/foo/bar.json`);
# create the dirname before touch+bind so a nested overlay assembles.
_RW_COUNT=0
for _f in ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"}; do
  mkdir -p "$(dirname "$TARGET/$_f")"
  touch "$TARGET/$_f"
  mount --bind "$SYSTEM/rw/$_f" "$TARGET/$_f"
  _RW_COUNT=$((_RW_COUNT + 1))
done

# Step 4a: read-only single files
_RO_FILE_COUNT=0
for _f in ${RO_FILES[@]+"${RO_FILES[@]}"}; do
  mkdir -p "$(dirname "$TARGET/$_f")"
  touch "$TARGET/$_f"
  mount --bind "$SYSTEM/ro/$_f" "$TARGET/$_f"
  mount -o remount,bind,ro "$TARGET/$_f"
  _RO_FILE_COUNT=$((_RO_FILE_COUNT + 1))
done

# Step 4b: read-only directories
_RO_DIR_COUNT=0
for _d in ${RO_DIRS[@]+"${RO_DIRS[@]}"}; do
  mkdir -p "$TARGET/$_d"
  mount --bind "$SYSTEM/ro/$_d" "$TARGET/$_d"
  mount -o remount,bind,ro "$TARGET/$_d"
  _RO_DIR_COUNT=$((_RO_DIR_COUNT + 1))
done

# Step 5: mask .system/ from project scope.
mount --bind "$SYSTEM/.mask" "$SYSTEM"
mount -o remount,bind,ro "$SYSTEM"

_ASSEMBLED=1
log I mounts done "session=$SESSION_ID rw=$_RW_COUNT ro-files=$_RO_FILE_COUNT ro-dirs=$_RO_DIR_COUNT"
