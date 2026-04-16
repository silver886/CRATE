#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

. "$PROJECT_ROOT/lib/init-launcher.sh"

OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_CLAUDE_HASH=""
FORCE_PULL=""
BASE_IMAGE=""
MACHINE_CPUS=""
MACHINE_MEMORY=""
MACHINE_DISK_SIZE=""
ALLOW_DNF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-hash)   OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)   OPT_TOOL_HASH="$2"; shift 2 ;;
    --claude-hash) OPT_CLAUDE_HASH="$2"; shift 2 ;;
    --force-pull)  FORCE_PULL=1; shift ;;
    --image)       BASE_IMAGE="$2"; shift 2 ;;
    --cpus)        MACHINE_CPUS="$2"; shift 2 ;;
    --memory)      MACHINE_MEMORY="$2"; shift 2 ;;
    --disk-size)   MACHINE_DISK_SIZE="$2"; shift 2 ;;
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
MACHINE_ARGS=""
[ -n "$MACHINE_CPUS" ]      && MACHINE_ARGS="$MACHINE_ARGS --cpus $MACHINE_CPUS"
[ -n "$MACHINE_MEMORY" ]    && MACHINE_ARGS="$MACHINE_ARGS --memory $MACHINE_MEMORY"
[ -n "$MACHINE_DISK_SIZE" ] && MACHINE_ARGS="$MACHINE_ARGS --disk-size $MACHINE_DISK_SIZE"
[ -n "$BASE_IMAGE" ]        && MACHINE_ARGS="$MACHINE_ARGS --image $BASE_IMAGE"

# Tear the VM down on any exit. The project's .claude/.system layout
# persists on the host — nothing to clean up there.
#
# File-leak guard: if `podman machine init` crashes partway through
# (a known class of issue on macOS/vfkit — containers/podman#24725
# family), a single `rm -f` can silently leave disk images behind.
# We retry up to 3 times, re-verify via `podman machine inspect`, and
# log a warning if the machine still appears in podman's state after
# all attempts so a human can clean up rather than losing gigabytes
# of orphaned qcow2 to silent leakage.
MACHINE_NAME=""
trap '
  if [ -n "$MACHINE_NAME" ]; then
    log I vm teardown "$MACHINE_NAME"
    podman machine stop "$MACHINE_NAME" 2>/dev/null || true
    _i=0
    while [ "$_i" -lt 3 ]; do
      podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
      podman machine inspect "$MACHINE_NAME" >/dev/null 2>&1 || break
      _i=$((_i + 1))
      sleep 1
    done
    if podman machine inspect "$MACHINE_NAME" >/dev/null 2>&1; then
      log E vm leak "$MACHINE_NAME still present after 3 rm attempts; manual cleanup required (check ~/.local/share/containers/podman/machine/ and ~/.config/containers/podman/machine/)"
    fi
  fi
' EXIT

init_launcher

# ── Runtime VM ──

# Podman only supports one VM at a time — stop whatever is running
stop_all_machines() {
  for _m in $(podman machine list --format '{{.Name}}' --noheading 2>/dev/null | sed 's/\*$//' || true); do
    podman machine stop "$_m" 2>/dev/null || true
  done
}

WORKDIR_HASH=$(sha256 "$PWD" | cut -c1-16)
MACHINE_NAME="claude-$WORKDIR_HASH"

# Clean up leftovers from a previous interrupted run
podman machine stop "$MACHINE_NAME" 2>/dev/null || true
podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
stop_all_machines

# Single host→guest mount: $PWD → /var/workdir. .claude/.system/rw/
# (containing hardlinks to the canonical config files) rides along
# inside the workdir, so the in-VM bind layer in setup-system-mounts.sh
# can reach them without exposing all of $CONFIG_DIR.
log I vm init "$MACHINE_NAME"
podman machine init "$MACHINE_NAME" $MACHINE_ARGS \
  --volume "$PWD:/var/workdir"
log I vm start "$MACHINE_NAME"
podman machine start "$MACHINE_NAME"

# Push setup-system-mounts.sh into the VM and run it as root. claude
# itself is launched below as the unprivileged `core` user — sudo is
# only used here to do the mount syscalls.
log I mounts assemble "/etc/claude-code-sandbox"
cat "$PROJECT_ROOT/bin/setup-system-mounts.sh" | podman machine ssh "$MACHINE_NAME" \
  'cat > /tmp/setup-system-mounts.sh && chmod +x /tmp/setup-system-mounts.sh'
podman machine ssh "$MACHINE_NAME" \
  "sudo /tmp/setup-system-mounts.sh \
     --log-level ${LOG_LEVEL:-W} \
     --workdir /var/workdir \
     --target /etc/claude-code-sandbox \
     --config-files '$CONFIG_FILES' \
     --ro-files '$RO_FILES' \
     --ro-dirs '$RO_DIRS'"

# Inject setup script and tool archives, then run setup
log I archive inject "base+tool+claude tarballs"
cat "$PROJECT_ROOT/bin/setup-tools.sh" | podman machine ssh "$MACHINE_NAME" \
  'cat > /tmp/setup-tools.sh && chmod +x /tmp/setup-tools.sh'
_ARCHIVE_ARGS=""
for _archive in "$BASE_ARCHIVE" "$TOOL_ARCHIVE" "$CLAUDE_ARCHIVE"; do
  _name=$(basename "$_archive")
  cat "$_archive" | podman machine ssh "$MACHINE_NAME" "cat > /tmp/$_name"
  _ARCHIVE_ARGS="$_ARCHIVE_ARGS /tmp/$_name"
done
podman machine ssh "$MACHINE_NAME" "/tmp/setup-tools.sh --log-level ${LOG_LEVEL:-W}$_ARCHIVE_ARGS"

# ── Launch ──
#
# Raw `ssh -tt` to the VM — `podman machine ssh MACHINE "cmd"`'s pty
# allocation has been observed to be unreliable, leaving claude with
# no controlling tty. `-tt` forces pty allocation on the server side.
#
# Not `exec`'d — the EXIT trap still needs to fire to tear down the VM
# after claude exits.
SSH_PORT=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}')
SSH_KEY=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')
_ENV="CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox"
[ -n "$ALLOW_DNF" ] && _ENV="$_ENV CLAUDE_ENABLE_DNF=1"
log I run launch "ssh -tt core@localhost (machine $MACHINE_NAME)"
ssh -tt -p "$SSH_PORT" -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  core@localhost \
  "cd /var/workdir && exec env $_ENV \$HOME/.local/bin/claude --log-level ${LOG_LEVEL:-W} --dangerously-skip-permissions"
