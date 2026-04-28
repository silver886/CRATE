#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

. "$PROJECT_ROOT/lib/init-launcher.sh"

AGENT="claude"
OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_AGENT_HASH=""
FORCE_PULL=""
MACHINE_IMAGE=""
MACHINE_CPUS=""
MACHINE_MEMORY=""
MACHINE_DISK_SIZE=""
ALLOW_DNF=""
STOP_OTHERS=""
OPT_NEW_SESSION=""
OPT_SESSION_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)        AGENT="$2"; shift 2 ;;
    --base-hash)    OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)    OPT_TOOL_HASH="$2"; shift 2 ;;
    --agent-hash)   OPT_AGENT_HASH="$2"; shift 2 ;;
    --force-pull)   FORCE_PULL=1; shift ;;
    --machine-image) MACHINE_IMAGE="$2"; shift 2 ;;
    --cpus)         MACHINE_CPUS="$2"; shift 2 ;;
    --memory)       MACHINE_MEMORY="$2"; shift 2 ;;
    --disk-size)    MACHINE_DISK_SIZE="$2"; shift 2 ;;
    --allow-dnf)    ALLOW_DNF=1; shift ;;
    --stop-others)  STOP_OTHERS=1; shift ;;
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

# Podman parses `-v/--volume "src:dst[:opts]"` by colon — a host path
# containing `:` (legal on Linux/macOS) silently re-routes the mount or
# breaks the launch. The native POSIX backends interpolate $PWD into
# the volume string directly, so reject upfront with a clear message
# rather than letting Podman produce a cryptic mid-bootstrap error.
case "$PWD" in
  *:*) log E launcher fail "working directory '$PWD' contains ':' — Podman uses ':' as the volume source/destination separator. Move the project to a path without colons (or run from a path without colons) and retry."; exit 1 ;;
esac
# Build as an argv array (not a shell string) so values containing
# whitespace or shell metacharacters can't be re-split or inject extra
# Podman flags when expanded into `podman machine init`.
MACHINE_ARGS=()
[ -n "$MACHINE_CPUS" ]      && MACHINE_ARGS+=(--cpus "$MACHINE_CPUS")
[ -n "$MACHINE_MEMORY" ]    && MACHINE_ARGS+=(--memory "$MACHINE_MEMORY")
[ -n "$MACHINE_DISK_SIZE" ] && MACHINE_ARGS+=(--disk-size "$MACHINE_DISK_SIZE")
# `podman machine init --image` takes a Podman *machine* image
# (path/URL to a disk image like a FCOS qcow2/raw, or `testing`/`stable`
# stream label), NOT a container image reference like `fedora:latest`
# — those would fail with "no such image". Hence a dedicated flag,
# distinct from the container/WSL `--image` that selects a base OS
# container image.
[ -n "$MACHINE_IMAGE" ]     && MACHINE_ARGS+=(--image "$MACHINE_IMAGE")

# State dir: each launch writes "<MACHINE_NAME>.machine" containing
# `pid`, `start` (process start time), and `cmd` (cmdline) as KV lines,
# then deletes it on exit. A future launch reclaims any machine whose
# owner is no longer the same live process — pid alone is insufficient
# on long-uptime hosts where the OS can wrap the pid space and leave
# the recorded pid in use by an unrelated process. The 3-field tuple
# (pid + start + cmd) is unique per process lifetime, mirroring the
# session-owner liveness check in lib/init-launcher.sh.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/crate/machines"
mkdir -p "$STATE_DIR"

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
      log E vm leak "$MACHINE_NAME still present after 3 rm attempts; state file preserved at $STATE_DIR/$MACHINE_NAME.machine for next-launch reclaim. Manual cleanup may be required (check ~/.local/share/containers/podman/machine/ and ~/.config/containers/podman/machine/)"
    else
      rm -f "$STATE_DIR/$MACHINE_NAME.machine" 2>/dev/null || true
    fi
  fi
' EXIT

init_launcher

# The VM backend runs the agent as the FCOS 'core' user (see
# bin/bootstrap-agent-user.sh for why a separate uid 24368 isn't
# viable on virtiofs). For agents without a config-dir env var
# (gemini), agent_load anchored CRATE_DIR at /home/agent —
# re-anchor against /home/core so the mount target matches the
# agent's actual $HOME inside the VM. Env-based agents (claude/codex)
# mount at /usr/local/etc/crate/<agent>, independent of $HOME
# (the env var, baked into agent-manifest.sh, points there) — leave
# them untouched.
if [ -z "$CRATE_ENV" ]; then
  _default=$(agent_get .configDir.default)
  case "$_default" in
    '$HOME'*) CRATE_DIR="/home/core${_default#\$HOME}" ;;
    *)        CRATE_DIR="$_default" ;;
  esac
fi

# ── Runtime VM ──

# Podman supports only one running machine per host (the VM backend
# binds a fixed gvproxy port). By default fail fast if another machine
# is running — pass --stop-others to stop them automatically. Avoids
# silently terminating unrelated user workloads.
check_running_machines() {
  _running=$(podman machine list --format '{{.Name}} {{.Running}}' --noheading 2>/dev/null \
    | sed 's/\*//' \
    | awk '$2 == "true" { print $1 }')
  [ -n "$_running" ] || return 0
  if [ -n "$STOP_OTHERS" ]; then
    for _name in $_running; do
      log W vm stop-other "stopping running machine '$_name' (--stop-others)"
      podman machine stop "$_name" 2>/dev/null || true
    done
  else
    log E vm conflict "another podman machine is running ($(printf '%s ' $_running| sed 's/ $//')) — podman allows only one at a time. Stop it manually, or pass --stop-others to stop it automatically."
    exit 1
  fi
}

# Reclaim machines whose launcher process is no longer alive (kill -9,
# power loss, etc.) OR whose pid has been reused by an unrelated
# process. The marker is a KV file with `pid`, `start`, and `cmd`. A
# machine is "still owned" iff: pid is alive AND its current start
# time matches the recorded one AND its current cmdline matches the
# recorded one. Anything else → abandoned. Legacy markers (single-line
# pid, no `start=`) fall back to pid-only liveness.
reclaim_abandoned_machines() {
  for _f in "$STATE_DIR"/*.machine; do
    [ -f "$_f" ] || continue
    _pid=$(_owner_get "$_f" pid)
    _start=$(_owner_get "$_f" start)
    _cmd=$(_owner_get "$_f" cmd)
    # Legacy single-line marker: first line is the pid, no KV pairs.
    if [ -z "$_pid" ]; then
      _pid=$(head -n1 "$_f" 2>/dev/null)
      case "$_pid" in
        ''|*[!0-9]*) _pid="" ;;
      esac
    fi
    _alive=0
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
      if [ -n "$_start" ]; then
        _cur_start=$(_pid_start "$_pid")
        _cur_cmd=$(_pid_cmdline "$_pid")
        if [ "$_cur_start" = "$_start" ] && [ "$_cur_cmd" = "$_cmd" ]; then
          _alive=1
        fi
      else
        _alive=1
      fi
    fi
    if [ "$_alive" -eq 0 ]; then
      _abandoned=$(basename "$_f" .machine)
      log W vm reclaim "removing abandoned machine '$_abandoned' (owner pid '${_pid:-?}' not alive or PID-reused)"
      podman machine stop "$_abandoned" 2>/dev/null || true
      podman machine rm -f "$_abandoned" 2>/dev/null || true
      # Only drop the marker once the machine is actually gone — otherwise
      # the next launch would lose its only handle on the leak.
      if podman machine inspect "$_abandoned" >/dev/null 2>&1; then
        log E vm reclaim-fail "machine '$_abandoned' still registered after rm; state file preserved at $_f for retry on next launch"
      else
        rm -f "$_f"
      fi
    fi
  done
}

# Reuse the launcher's resolved SESSION_ID (8 chars base36, set by
# init_launcher → resolve_session_id) as the VM identity. Format:
# `crate-<agent>-<sessionId>`. Budget under macOS Podman's 30-char cap
# (AF_UNIX socket path):
#   crate- (6) + agent (≤6) + - (1) + 8 = 21 chars (claude/gemini/codex).
MACHINE_NAME="crate-$AGENT-$SESSION_ID"

reclaim_abandoned_machines
check_running_machines

# Register this machine before init: if init/start fails, the trap will
# remove the half-created machine AND this state file together. KV
# format with pid + start + cmd so a future launch can detect both
# kill-9 leaks and PID-reuse on long-uptime hosts. cmd is collapsed to
# a single line so the awk-based KV parser stays valid.
{
  printf 'pid=%s\n'   "$$"
  printf 'start=%s\n' "$(_pid_start "$$")"
  printf 'cmd=%s\n'   "$(_pid_cmdline "$$" | tr '\n' ' ')"
} > "$STATE_DIR/$MACHINE_NAME.machine"

log I vm init "$MACHINE_NAME"
podman machine init "$MACHINE_NAME" ${MACHINE_ARGS[@]+"${MACHINE_ARGS[@]}"} \
  --volume "$PWD:/var/workdir"
log I vm start "$MACHINE_NAME"
podman machine start "$MACHINE_NAME"

# Stage log.sh to the canonical in-sandbox path (baked into the image on
# container/WSL backends; absent on Fedora CoreOS — must be installed here
# before any bin/*.sh that sources it runs).
#
# All shell files streamed below are filtered through `tr -d '\r'` so a
# Windows checkout with `core.autocrlf=true` doesn't ship CRLF into the
# guest where bash chokes on the carriage returns. Archive transfers in
# the for-loop below are intentionally NOT filtered (binary .tar.xz).
log I vm setup "installing log.sh"
tr -d '\r' < "$PROJECT_ROOT/lib/log.sh" | podman machine ssh "$MACHINE_NAME" \
  'sudo install -d -m 0755 /usr/local/lib/crate && sudo tee /usr/local/lib/crate/log.sh >/dev/null && sudo chmod 0644 /usr/local/lib/crate/log.sh'

# Encode each file list as base64 of NUL-delimited UTF-8 so filenames
# with quotes/spaces/newlines/metachars survive both the SSH command-
# string interpolation AND the receiver's iteration. Empty arrays
# produce an empty string (printf '%s\0' with zero args still emits a
# NUL on bash, so we guard with ${#arr[@]}).
_encode_nul_b64() {
  if [ "$#" -eq 0 ]; then printf ''; else printf '%s\0' "$@" | base64 | tr -d '\n'; fi
}
_CF_B64=$(_encode_nul_b64 ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"})
_RF_B64=$(_encode_nul_b64 ${RO_FILES[@]+"${RO_FILES[@]}"})
_RD_B64=$(_encode_nul_b64 ${RO_DIRS[@]+"${RO_DIRS[@]}"})

# Stream the script over ssh stdin into `sudo sh -s --` rather than
# staging at a predictable /tmp/<name>.sh path. Eliminates the
# pre-create-symlink window that an attacker with concurrent VM access
# would have between `cat > /tmp/X.sh` and the subsequent invocation.
log I mounts assemble "$CRATE_DIR"
tr -d '\r' < "$PROJECT_ROOT/bin/setup-system-mounts.sh" | podman machine ssh "$MACHINE_NAME" \
  "sudo bash -s -- \
     --log-level ${LOG_LEVEL:-W} \
     --workdir /var/workdir \
     --project-dir '$AGENT_PROJECT_DIR' \
     --session-id '$SESSION_ID' \
     --target '$CRATE_DIR' \
     --config-files '$_CF_B64' \
     --ro-files '$_RF_B64' \
     --ro-dirs '$_RD_B64'"

log I archive inject "base+tool+$AGENT tarballs"
# Each archive gets a fresh mktemp'd path inside the VM (random suffix,
# O_EXCL semantics) so a concurrent VM-side process can't pre-place a
# symlink at the path. setup-tools.sh treats archives as positional
# args and uses tar's content-based detection — the random name is
# fine.
_ARCHIVE_ARGS=""
for _archive in "$BASE_ARCHIVE" "$TOOL_ARCHIVE" "$AGENT_ARCHIVE"; do
  _remote_path=$(cat "$_archive" | podman machine ssh "$MACHINE_NAME" \
    'p=$(mktemp /tmp/archive.XXXXXXXX) && cat > "$p" && printf "%s" "$p"')
  if [ -z "$_remote_path" ]; then
    log E launcher fail "failed to stage $(basename "$_archive") in VM"
    exit 1
  fi
  _ARCHIVE_ARGS="$_ARCHIVE_ARGS $_remote_path"
done
# setup-tools.sh streams over ssh stdin into `sh -s --`, same pattern
# as setup-system-mounts.sh above. Archives are referenced by their
# mktemp'd paths via $_ARCHIVE_ARGS.
tr -d '\r' < "$PROJECT_ROOT/bin/setup-tools.sh" | podman machine ssh "$MACHINE_NAME" \
  "sh -s -- --log-level ${LOG_LEVEL:-W}$_ARCHIVE_ARGS"

# Install enable-dnf + the per-user bootstrap sudoers rule. Container/
# WSL backends bake these into the image (Containerfile lines 18-24);
# FCOS gets a fresh stock VM each launch, so we install here. The
# per-user sudoers rule survives the strip-sudo step below — group
# membership and per-user rules are independent in sudoers.
log I vm install-dnf "enable-dnf + sudoers rule for core"
tr -d '\r' < "$PROJECT_ROOT/bin/enable-dnf.sh" | podman machine ssh "$MACHINE_NAME" \
  'sudo tee /usr/local/lib/crate/enable-dnf >/dev/null && sudo chmod 0755 /usr/local/lib/crate/enable-dnf'
sed 's|__USER__|core|g; s|\r$||' "$PROJECT_ROOT/config/sudoers-enable-dnf.tmpl" | podman machine ssh "$MACHINE_NAME" \
  'sudo tee /etc/sudoers.d/core-enable-dnf >/dev/null && sudo chmod 0440 /etc/sudoers.d/core-enable-dnf && sudo visudo -cf /etc/sudoers.d/core-enable-dnf'

# Strip core of sudo/wheel group membership so the agent (which runs
# as core for /var/workdir uid parity) cannot escalate. MUST happen
# AFTER all sudo-requiring setup steps and BEFORE the launch SSH
# session — the launch session opens fresh and PAM reads the updated
# /etc/group at login. The per-user sudoers rule installed above
# stays in effect (sudoers per-user rules don't depend on group).
log I vm strip-sudo "dropping core from sudo/wheel"
# Stream over ssh stdin into `sudo sh -s --`; same pattern as the
# other setup scripts — no temp file at a predictable /tmp/ path.
tr -d '\r' < "$PROJECT_ROOT/bin/bootstrap-agent-user.sh" | podman machine ssh "$MACHINE_NAME" \
  'sudo sh -s --'

# ── Launch ──

# Two inspect calls so an IdentityPath containing a space (custom
# machine dir) round-trips intact — the joined format would silently
# truncate at the first space.
SSH_PORT=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}')
SSH_KEY=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')

# A fresh SSH session: PAM reads /etc/group at login, so this session
# sees core after the strip-sudo step — no sudo/wheel membership, no
# escalation path. `exec` replaces the SSH shell with the agent so
# there's no parent shell remaining for a TTY hijack (TIOCSTI) on
# agent exit; ssh closes when the agent process does.
_ENV=""
[ -n "$ALLOW_DNF" ] && _ENV="$_ENV CRATE_ALLOW_DNF=1"
log I run launch "ssh -tt core@localhost (machine $MACHINE_NAME, agent $AGENT)"
ssh -tt -p "$SSH_PORT" -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  core@localhost \
  "cd /var/workdir && exec env $_ENV \$HOME/.local/bin/$AGENT_BINARY --log-level ${LOG_LEVEL:-W}"
