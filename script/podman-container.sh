#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source init-launcher.sh first (which sources lib/log.sh) so `log` is
# available for option-parse errors and stage markers below.
. "$PROJECT_ROOT/lib/init-launcher.sh"

OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_CLAUDE_HASH=""
FORCE_PULL=""
BASE_IMAGE="fedora:latest"
ALLOW_DNF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-hash)   OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)   OPT_TOOL_HASH="$2"; shift 2 ;;
    --claude-hash) OPT_CLAUDE_HASH="$2"; shift 2 ;;
    --force-pull)  FORCE_PULL=1; shift ;;
    --image)       BASE_IMAGE="$2"; shift 2 ;;
    --allow-dnf)   ALLOW_DNF=1; shift ;;
    --log-level)
      # Accept any case and normalize. Downstream consumers
      # (log.sh, inline loggers in bin/*.sh) are case-SENSITIVE.
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

# SELinux detection: prefer `getenforce` (policycoreutils), fall back
# to reading /sys/fs/selinux/enforce so we still apply label=disable on
# hosts where the tool isn't installed but the LSM is active.
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

# Hash each input file independently and concatenate the digests so
# file-boundary content can't collide when the contents are shifted.
_IMG_HASHES=""
for _f in Containerfile bin/enable-dnf.sh bin/setup-tools.sh config/sudoers-claude-enable-dnf; do
  _IMG_HASHES="$_IMG_HASHES$(sha256 "$(cat "$PROJECT_ROOT/$_f")")"
done
IMAGE_TAG="claude-base-$(sha256 "$_IMG_HASHES-$BASE_IMAGE")"
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
# System config assembly via podman -v stacking (no in-container privileges):
#   1. cr/ as the base of /etc/claude-code-sandbox (rw, persists per project)
#   2. rw/<f> per-file mounts shadow cr at <f> with the host hardlinks
#      (mount-point gives EBUSY → in-place writeFileSync → host sync)
#   3. ro/<x>:ro per-file/per-subdir mounts shadow cr at <x>, read-only
#   4. .mask/ bind-mounted (read-only) over /var/workdir/.claude/.system
#      to mask system scope from project scope. Bind-of-empty-dir
#      instead of --tmpfs because podman --tmpfs nested under another
#      -v has been observed to silently no-op.

# Build the cfg-mount args as positional parameters so paths with
# spaces survive (POSIX sh has no real arrays — `set --` is the
# closest thing). Each `-v` flag is two positional args; `"$@"`
# expands them properly quoted into the podman run call.
set -- -v "$SYSTEM_DIR/cr:/etc/claude-code-sandbox"
for _f in $CONFIG_FILES; do
  set -- "$@" -v "$SYSTEM_DIR/rw/$_f:/etc/claude-code-sandbox/$_f"
done
for _f in $RO_FILES; do
  set -- "$@" -v "$SYSTEM_DIR/ro/$_f:/etc/claude-code-sandbox/$_f:ro"
done
for _d in $RO_DIRS; do
  set -- "$@" -v "$SYSTEM_DIR/ro/$_d:/etc/claude-code-sandbox/$_d:ro"
done

log I run launch "podman container run $IMAGE_TAG"
# --log-level is appended after the image tag as CMD args. The
# Containerfile ENTRYPOINT is setup-tools.sh, which parses the flag
# from its tail args and forwards it to claude-wrapper.sh (the
# renamed `claude`). No LOG_LEVEL env var crosses the container
# boundary — every hop passes the level as an explicit arg.
podman container run --interactive --tty --rm \
  --userns=keep-id:uid=1000,gid=1000 \
  $SELINUX_OPT \
  -v "$BASE_ARCHIVE:/tmp/base.tar.xz:ro" \
  -v "$TOOL_ARCHIVE:/tmp/tool.tar.xz:ro" \
  -v "$CLAUDE_ARCHIVE:/tmp/claude.tar.xz:ro" \
  -v "$PWD:/var/workdir" \
  "$@" \
  -v "$SYSTEM_DIR/.mask:/var/workdir/.claude/.system:ro" \
  --workdir /var/workdir \
  --env CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox \
  ${ALLOW_DNF:+--env CLAUDE_ENABLE_DNF=1} \
  "$IMAGE_TAG" \
  --log-level "${LOG_LEVEL:-W}"
