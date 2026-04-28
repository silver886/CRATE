#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source init-launcher.sh first (which sources lib/log.sh) so `log` is
# available for option-parse errors and stage markers below.
. "$PROJECT_ROOT/lib/init-launcher.sh"

AGENT="claude"
OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_AGENT_HASH=""
FORCE_PULL=""
BASE_IMAGE="fedora:latest"
ALLOW_DNF=""
OPT_NEW_SESSION=""
OPT_SESSION_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)        AGENT="$2"; shift 2 ;;
    --base-hash)    OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)    OPT_TOOL_HASH="$2"; shift 2 ;;
    --agent-hash)   OPT_AGENT_HASH="$2"; shift 2 ;;
    --force-pull)   FORCE_PULL=1; shift ;;
    --image)        BASE_IMAGE="$2"; shift 2 ;;
    --allow-dnf)    ALLOW_DNF=1; shift ;;
    --new-session)  OPT_NEW_SESSION=1; shift ;;
    --session)      OPT_SESSION_ID="$2"; shift 2 ;;
    --log-level)
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E launcher arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E launcher arg-parse "unknown option: $1"; exit 1 ;;
  esac
done
: "${LOG_LEVEL:=W}"
if [ -n "$OPT_NEW_SESSION" ] && [ -n "$OPT_SESSION_ID" ]; then
  log E launcher arg-parse "--new-session and --session are mutually exclusive"
  exit 1
fi

# Podman parses `-v "src:dst[:opts]"` by colon — a host path containing
# `:` (legal on Linux/macOS) silently re-routes the mount or breaks
# the launch. Reject upfront on every base that bind sources derive
# from in this script: $PWD ($SESSION_DIR / $SYSTEM_DIR under
# $PWD/$AGENT_PROJECT_DIR/.system), $HOME (default cache root), and
# $TOOLS_DIR (where the three archive binds resolve — set via
# $XDG_CACHE_HOME if exported, so $HOME alone doesn't cover it).
# Clearer than letting Podman fail mid-launch.
for _hp in "$PWD" "${HOME:-}" "$TOOLS_DIR"; do
  case "$_hp" in
    *:*) log E launcher fail "host path '$_hp' contains ':' — Podman uses ':' as the volume source/destination separator. Move the project (or your cache/HOME) to a path without colons and retry."; exit 1 ;;
  esac
done

# SELinux detection
SELINUX_OPT=""
_SELINUX_STATE=""
if command -v getenforce >/dev/null 2>&1; then
  _SELINUX_STATE=$(getenforce 2>/dev/null)
elif [ -r /sys/fs/selinux/enforce ]; then
  case "$(cat /sys/fs/selinux/enforce 2>/dev/null)" in
    1) _SELINUX_STATE=Enforcing ;;
    0) _SELINUX_STATE=Permissive ;;
  esac
fi
if [ -n "$_SELINUX_STATE" ] && [ "$_SELINUX_STATE" != "Disabled" ]; then
  SELINUX_OPT="--security-opt label=disable"
  log I launcher selinux "detected $_SELINUX_STATE; using --security-opt label=disable"
fi

init_launcher

# ── Build base image ──

_IMG_HASHES=""
for _f in Containerfile .containerignore lib/log.sh bin/enable-dnf.sh bin/setup-tools.sh config/sudoers-enable-dnf.tmpl; do
  _IMG_HASHES="$_IMG_HASHES$(sha256_file "$PROJECT_ROOT/$_f")"
done
IMAGE_TAG="crate-base-$(sha256 "$_IMG_HASHES-$BASE_IMAGE")"
if podman image exists "$IMAGE_TAG" 2>/dev/null && [ -z "${FORCE_PULL:-}" ]; then
  log I image cache-hit "$IMAGE_TAG"
else
  log I image build "$IMAGE_TAG"
  _BUILD_ARGS=""
  [ -n "${FORCE_PULL:-}" ] && _BUILD_ARGS="--no-cache"
  podman image build $_BUILD_ARGS $SELINUX_OPT --build-arg "BASE_IMAGE=$BASE_IMAGE" --tag "$IMAGE_TAG" "$PROJECT_ROOT"
  log I image built "$IMAGE_TAG"
fi

# ── Run ──
#
# System config assembly via podman -v stacking:
#   1. sessions/<id>/cr/ as the base of $CRATE_DIR (rw, persists per session)
#   2. rw/<f> per-file mounts (EBUSY → in-place writeFileSync → host sync)
#   3. ro/<x>:ro per-file/per-subdir (read-only)
#   4. .mask/ bind (read-only) over /var/workdir/<projectDir>/.system
#      to mask system scope from project scope

set -- -v "$SESSION_DIR/cr:$CRATE_DIR"
for _f in ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"}; do
  set -- "$@" -v "$SYSTEM_DIR/rw/$_f:$CRATE_DIR/$_f"
done
for _f in ${RO_FILES[@]+"${RO_FILES[@]}"}; do
  set -- "$@" -v "$SYSTEM_DIR/ro/$_f:$CRATE_DIR/$_f:ro"
done
for _d in ${RO_DIRS[@]+"${RO_DIRS[@]}"}; do
  set -- "$@" -v "$SYSTEM_DIR/ro/$_d:$CRATE_DIR/$_d:ro"
done

log I run launch "podman container run $IMAGE_TAG ($AGENT)"
podman container run --interactive --tty --rm \
  --userns=keep-id:uid=24368,gid=24368 \
  $SELINUX_OPT \
  -v "$BASE_ARCHIVE:/tmp/base.tar.xz:ro" \
  -v "$TOOL_ARCHIVE:/tmp/tool.tar.xz:ro" \
  -v "$AGENT_ARCHIVE:/tmp/agent.tar.xz:ro" \
  -v "$PWD:/var/workdir" \
  "$@" \
  -v "$SYSTEM_DIR/.mask:/var/workdir/$AGENT_PROJECT_DIR/.system:ro" \
  --workdir /var/workdir \
  ${ALLOW_DNF:+--env CRATE_ALLOW_DNF=1} \
  "$IMAGE_TAG" \
  --log-level "${LOG_LEVEL:-W}"
