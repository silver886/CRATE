#!/bin/sh
# setup-system-mounts.sh — assemble CLAUDE_CONFIG_DIR inside a sandbox
# from a project's $PWD/.claude/.system/{ro,rw,cr} layout, and bind-mask
# .system/ from project scope using the empty .system/.mask dir.
#
# Run as root inside the sandbox (via `sudo` on the VM/WSL backends —
# claude itself NEVER runs as root). Container backends do not need this
# script: podman -v flags do the equivalent assembly directly.
#
# Args:
#   --workdir DIR        host workdir mount point (default: /var/workdir)
#   --target  DIR        sandbox config dir       (default: /etc/claude-code-sandbox)
#   --config-files "..." space-separated rw file basenames (from $CONFIG_FILES).
#                        Sourced from $WORKDIR/.claude/.system/rw/<f>, which
#                        init-config.sh populates with hardlinks to the
#                        canonical $CONFIG_DIR/<f> on every launch.
#   --ro-files    "..." space-separated ro file basenames (from $RO_FILES)
#   --ro-dirs     "..." space-separated ro dir  basenames (from $RO_DIRS)
#   --log-level   I|W|E  log threshold. Passed as an arg (not env) because
#                        sudo env_check strips unknown LOG_LEVEL values on
#                        Fedora CoreOS even with --preserve-env=LOG_LEVEL.
#                        Same rationale as bin/enable-dnf.sh.
#
# Assembly steps (in order — see plan doc for the vfkit rationale):
#   1. mkdir target
#   2. bind cr/ as base — Claude's runtime writes (projects/, todos/, …)
#      land back in $PWD/.claude/.system/cr on the host
#   3. per-file rw overlay — bind rw/$f → target/$f. Mount-point gives
#      EBUSY → in-place writeFileSync → hardlink preserved → host sync
#   4. per-file/per-subdir ro overlay — bind + remount,bind,ro
#   5. mask $workdir/.claude/.system by bind-mounting .system/.mask
#      (empty dir) on top of it, then remount,bind,ro. Hides system
#      scope from project-scope reads under .claude/. Done LAST so
#      the binds in 2-4 capture the real host inodes before the mask
set -eu

# Inline structured logger — same format, threshold, and color
# semantics as lib/log.sh. $LOG_LEVEL is set from --log-level arg
# parsing below; never inherited from env. Colors disabled when
# $NO_COLOR is set or stderr is not a tty, so log files never get
# escape bytes.
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

WORKDIR=/var/workdir
TARGET=/etc/claude-code-sandbox
CONFIG_FILES=""
RO_FILES=""
RO_DIRS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir)      WORKDIR="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --config-files) CONFIG_FILES="$2"; shift 2 ;;
    --ro-files)     RO_FILES="$2"; shift 2 ;;
    --ro-dirs)      RO_DIRS="$2"; shift 2 ;;
    --log-level)
      # Accept any case and normalize. Downstream consumers (the inline
      # logger above) are now case-tolerant too, but we still normalize
      # here so a single canonical value reaches child processes.
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

SYSTEM="$WORKDIR/.claude/.system"

log I mounts start "target=$TARGET source=$SYSTEM"

mkdir -p "$TARGET"

# Count args positionally (no subshell, no echo|wc pipeline).
_count_words() { echo $#; }
_RW_COUNT=$(_count_words $CONFIG_FILES)
_RO_FILE_COUNT=$(_count_words $RO_FILES)
_RO_DIR_COUNT=$(_count_words $RO_DIRS)

# Roll back all binds under $TARGET and $SYSTEM, in reverse order, so
# a retry starts from a clean slate. umount -R unwinds nested binds in
# one shot. Safe to call when nothing is mounted: `|| true` swallows
# the "not mounted" error.
_rollback_mounts() {
  umount -R "$TARGET" 2>/dev/null || true
  umount -R "$SYSTEM" 2>/dev/null || true
}

# Trap-based teardown: if we fail mid-assembly (any step 2–5 errors
# under `set -e`), the trap runs and rolls back whatever binds we
# managed to lay down. A retry from the launcher then starts clean
# instead of stacking another layer on top of the half-assembled tree.
# _ASSEMBLED is flipped to 1 on successful completion so the trap
# becomes a no-op on the happy path.
_ASSEMBLED=0
trap '
  if [ "$_ASSEMBLED" = 0 ]; then
    log W mounts rollback "partial assembly; unwinding binds"
    _rollback_mounts
  fi
' EXIT

# Idempotency / completeness check: if $TARGET is already a mountpoint
# we've either fully assembled it previously (skip) or a prior run
# crashed mid-way (tear down + re-assemble). Verify every expected
# bind is in place before trusting the fast path.
if mountpoint -q "$TARGET" 2>/dev/null; then
  _complete=1
  for _f in $CONFIG_FILES $RO_FILES; do
    mountpoint -q "$TARGET/$_f" 2>/dev/null || { _complete=0; break; }
  done
  if [ "$_complete" = 1 ]; then
    for _d in $RO_DIRS; do
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

# Step 2: cr/ as the base mount. Anything Claude creates under
# CLAUDE_CONFIG_DIR (sessions, backups, …) is written to this bucket and
# persists on the host across sandbox launches.
mount --bind "$SYSTEM/cr" "$TARGET"

# Step 3: writable file overlay. Source is the rw/ hardlink staged by
# init-config (which always populates rw/ with hardlinks to the
# canonical $CONFIG_DIR/<f>). `touch` first because cr/ doesn't contain
# these names — the mount target must exist for `mount --bind`.
for _f in $CONFIG_FILES; do
  touch "$TARGET/$_f"
  mount --bind "$SYSTEM/rw/$_f" "$TARGET/$_f"
done

# Step 4a: read-only single files
for _f in $RO_FILES; do
  touch "$TARGET/$_f"
  mount --bind "$SYSTEM/ro/$_f" "$TARGET/$_f"
  mount -o remount,bind,ro "$TARGET/$_f"
done

# Step 4b: read-only directories
for _d in $RO_DIRS; do
  mkdir -p "$TARGET/$_d"
  mount --bind "$SYSTEM/ro/$_d" "$TARGET/$_d"
  mount -o remount,bind,ro "$TARGET/$_d"
done

# Step 5: mask .system/ from project scope by bind-mounting the empty
# .mask/ dir over it. After this, anything reading under
# $WORKDIR/.claude/.system sees an empty dir — but the binds set up
# above continue to serve real content via $TARGET because mount --bind
# captures the source inode at bind time, not on every access.
# Bind-of-empty-dir instead of tmpfs because tmpfs has been observed to
# silently no-op when nested inside another bind in some environments.
mount --bind "$SYSTEM/.mask" "$SYSTEM"
mount -o remount,bind,ro "$SYSTEM"

_ASSEMBLED=1
log I mounts done "rw=$_RW_COUNT ro-files=$_RO_FILE_COUNT ro-dirs=$_RO_DIR_COUNT"
