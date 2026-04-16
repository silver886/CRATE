#!/bin/sh
# tools.sh — tool archive build system
# Sourced (not executed). Requires: PROJECT_ROOT

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { printf '%s' "$1" | sha256sum | cut -d ' ' -f 1; }
else
  sha256() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
fi

# `log` is provided by lib/log.sh, sourced from init-launcher.sh.

# Wait for all PIDs; if any failed, report and exit.
# POSIX wait with multiple PIDs only returns the last one's status.
wait_all() {
  _wa_fail=0
  for _wa_pid in "$@"; do
    wait "$_wa_pid" || _wa_fail=1
  done
  if [ "$_wa_fail" -ne 0 ]; then
    echo "One or more background tasks failed" >&2; exit 1
  fi
}

# ── Tool archive system ──

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-sandbox"
TOOLS_DIR="$CACHE_DIR/tools"

detect_arch() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)
      ARCH_NODE="x64"
      ARCH_RG="x86_64-unknown-linux-musl"
      ARCH_MICRO="linux64-static"
      ARCH_UV="x86_64-unknown-linux-musl"
      ARCH_PNPM="linux-x64"
      ARCH_CLAUDE="linux-x64"
      ;;
    arm64|aarch64)
      ARCH_NODE="arm64"
      ARCH_RG="aarch64-unknown-linux-gnu"
      ARCH_MICRO="linux-arm64"
      ARCH_UV="aarch64-unknown-linux-musl"
      ARCH_PNPM="linux-arm64"
      ARCH_CLAUDE="linux-arm64"
      ;;
    *) log E tools fail "unsupported architecture: $ARCH"; exit 1 ;;
  esac
}

# Fetch all tool versions in parallel (6 concurrent curls)
# Sets: NODE_VER, RG_VER, MICRO_VER, PNPM_VER, UV_VER, CLAUDE_VER
fetch_tool_versions() {
  _DIR=$(mktemp -d)
  (curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null \
    | jq -r '[.[] | select(.lts != false)][0].version' | sed 's/^v//' > "$_DIR/node") &
  _PID1=$!
  (curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest 2>/dev/null \
    | jq -r .tag_name > "$_DIR/rg") &
  _PID2=$!
  (curl -fsSL https://api.github.com/repos/zyedidia/micro/releases/latest 2>/dev/null \
    | jq -r .tag_name | sed 's/^v//' > "$_DIR/micro") &
  _PID3=$!
  (curl -fsSL https://registry.npmjs.org/pnpm/latest 2>/dev/null \
    | jq -r .version > "$_DIR/pnpm") &
  _PID4=$!
  (curl -fsSL https://pypi.org/pypi/uv/json 2>/dev/null \
    | jq -r .info.version > "$_DIR/uv") &
  _PID5=$!
  (curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
    | jq -r .version > "$_DIR/claude") &
  _PID6=$!
  wait_all "$_PID1" "$_PID2" "$_PID3" "$_PID4" "$_PID5" "$_PID6"
  NODE_VER=$(cat "$_DIR/node")
  RG_VER=$(cat "$_DIR/rg")
  MICRO_VER=$(cat "$_DIR/micro")
  PNPM_VER=$(cat "$_DIR/pnpm")
  UV_VER=$(cat "$_DIR/uv")
  CLAUDE_VER=$(cat "$_DIR/claude")
  rm -rf "$_DIR"
  # Validate — pipelines can exit 0 despite curl/jq failure (no pipefail in POSIX sh)
  if [ -z "$NODE_VER" ] || [ -z "$RG_VER" ] || [ -z "$MICRO_VER" ] || \
     [ -z "$PNPM_VER" ] || [ -z "$UV_VER" ] || [ -z "$CLAUDE_VER" ]; then
    log E tools fail "failed to fetch one or more tool versions"
    exit 1
  fi
}

# Resolve a hash prefix to a cached archive path
# Usage: resolve_archive <tier> <hash_prefix>
resolve_archive() {
  _tier="$1"
  _prefix="$2"
  _matches=""
  _count=0
  for _f in "$TOOLS_DIR/${_tier}-${_prefix}"*.tar.xz; do
    [ -f "$_f" ] || continue
    _matches="$_f"
    _count=$((_count + 1))
  done
  if [ "$_count" -eq 0 ]; then
    log E "tools.$_tier" fail "no cached archive matching hash '$_prefix'"
    exit 1
  elif [ "$_count" -gt 1 ]; then
    log E "tools.$_tier" fail "ambiguous hash prefix '$_prefix' matches multiple archives"
    exit 1
  fi
  printf '%s' "$_matches"
}

# Verify a cached tar.xz: not present, zero-length, or corrupt
# (truncated by an interrupted previous run, partial download, etc).
# `tar -tJf` fully decodes the xz stream and walks the tar structure,
# catching both layers of damage.
_archive_ok() {
  [ -f "$1" ] && [ -s "$1" ] && tar -tJf "$1" >/dev/null 2>&1
}

# ── Per-tier builders ──
#
# Each _build_*_tier function is self-contained and operates on its
# own archive path. The orchestrator computes BASE_ARCHIVE /
# TOOL_ARCHIVE / CLAUDE_ARCHIVE up front so that the 3 tier workers
# can run in parallel without sharing any mutable state — each just
# reads its archive path, downloads, and writes the file in place.
#
# Background subshells inherit the parent's env vars at fork time,
# so OPT_*_HASH / FORCE_PULL / *_VER / ARCH_* / *_ARCHIVE are all
# visible inside the worker. Variables set inside a worker do NOT
# propagate back, but they don't need to — the only side effect is
# the archive file on disk.
#
# `log` writes to stderr via `printf`, which is line-atomic for
# small writes on POSIX. Output from the 3 workers may interleave
# at line boundaries but never within a line.

_build_base_tier() {
  if [ -n "${OPT_BASE_HASH:-}" ]; then
    if ! _archive_ok "$BASE_ARCHIVE"; then
      log E tools.base fail "pinned archive is corrupt: $(basename "$BASE_ARCHIVE")"
      return 1
    fi
    log I tools.base cache-pin "$(basename "$BASE_ARCHIVE")"
    return 0
  fi
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$BASE_ARCHIVE"; then
    log I tools.base cache-hit "$(basename "$BASE_ARCHIVE")"
    return 0
  fi
  if [ -f "$BASE_ARCHIVE" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.base rebuild "cached archive corrupt; rebuilding"
    rm -f "$BASE_ARCHIVE"
  fi
  log I tools.base downloading "node $NODE_VER, ripgrep $RG_VER, micro $MICRO_VER"
  _DIR=$(mktemp -d)

  (curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-${ARCH_NODE}.tar.xz" \
    | tar -xJ --strip-components=2 -C "$_DIR" "node-v${NODE_VER}-linux-${ARCH_NODE}/bin/node") &
  _PID1=$!
  (curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-${ARCH_RG}.tar.gz" \
    | tar -xz --strip-components=1 -C "$_DIR" "ripgrep-${RG_VER}-${ARCH_RG}/rg") &
  _PID2=$!
  (curl -fsSL "https://github.com/zyedidia/micro/releases/download/v${MICRO_VER}/micro-${MICRO_VER}-${ARCH_MICRO}.tar.gz" \
    | tar -xz --strip-components=1 -C "$_DIR" "micro-${MICRO_VER}/micro") &
  _PID3=$!
  wait_all "$_PID1" "$_PID2" "$_PID3"

  cp "$PROJECT_ROOT/bin/claude-wrapper.sh" "$_DIR/claude-wrapper"
  chmod +x "$_DIR/node" "$_DIR/rg" "$_DIR/micro" "$_DIR/claude-wrapper"
  log I tools.base packing "$(basename "$BASE_ARCHIVE")"
  # Build to a temp path and atomic-rename on success. If the
  # process is killed mid-tar, the partial file sits at the .partial
  # path and gets swept on the next run; the final BASE_ARCHIVE
  # path is never partially written.
  _BASE_TMP="$BASE_ARCHIVE.partial.$$"
  tar -C "$_DIR" -cJf "$_BASE_TMP" node rg micro claude-wrapper
  mv -f "$_BASE_TMP" "$BASE_ARCHIVE"
  rm -rf "$_DIR"
  log I tools.base cached "$(basename "$BASE_ARCHIVE")"
}

_build_tool_tier() {
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    if ! _archive_ok "$TOOL_ARCHIVE"; then
      log E tools.tool fail "pinned archive is corrupt: $(basename "$TOOL_ARCHIVE")"
      return 1
    fi
    log I tools.tool cache-pin "$(basename "$TOOL_ARCHIVE")"
    return 0
  fi
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$TOOL_ARCHIVE"; then
    log I tools.tool cache-hit "$(basename "$TOOL_ARCHIVE")"
    return 0
  fi
  if [ -f "$TOOL_ARCHIVE" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.tool rebuild "cached archive corrupt; rebuilding"
    rm -f "$TOOL_ARCHIVE"
  fi
  log I tools.tool downloading "pnpm $PNPM_VER, uv $UV_VER"
  _DIR=$(mktemp -d)

  (curl -fsSL "https://github.com/pnpm/pnpm/releases/download/v${PNPM_VER}/pnpm-${ARCH_PNPM}" \
    -o "$_DIR/pnpm") &
  _PID1=$!
  (curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${ARCH_UV}.tar.gz" \
    | tar -xz --strip-components=1 -C "$_DIR") &
  _PID2=$!
  wait_all "$_PID1" "$_PID2"

  chmod +x "$_DIR/pnpm" "$_DIR/uv" "$_DIR/uvx"
  log I tools.tool packing "$(basename "$TOOL_ARCHIVE")"
  _TOOL_TMP="$TOOL_ARCHIVE.partial.$$"
  tar -C "$_DIR" -cJf "$_TOOL_TMP" pnpm uv uvx
  mv -f "$_TOOL_TMP" "$TOOL_ARCHIVE"
  rm -rf "$_DIR"
  log I tools.tool cached "$(basename "$TOOL_ARCHIVE")"
}

_build_claude_tier() {
  if [ -n "${OPT_CLAUDE_HASH:-}" ]; then
    if ! _archive_ok "$CLAUDE_ARCHIVE"; then
      log E tools.claude fail "pinned archive is corrupt: $(basename "$CLAUDE_ARCHIVE")"
      return 1
    fi
    log I tools.claude cache-pin "$(basename "$CLAUDE_ARCHIVE")"
    return 0
  fi
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$CLAUDE_ARCHIVE"; then
    log I tools.claude cache-hit "$(basename "$CLAUDE_ARCHIVE")"
    return 0
  fi
  if [ -f "$CLAUDE_ARCHIVE" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.claude rebuild "cached archive corrupt; rebuilding"
    rm -f "$CLAUDE_ARCHIVE"
  fi
  log I tools.claude downloading "claude $CLAUDE_VER"
  _GCS="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
  _DIR=$(mktemp -d)
  curl -fsSL "$_GCS/$CLAUDE_VER/$ARCH_CLAUDE/claude" -o "$_DIR/claude"
  chmod +x "$_DIR/claude"
  log I tools.claude packing "$(basename "$CLAUDE_ARCHIVE")"
  _CLAUDE_TMP="$CLAUDE_ARCHIVE.partial.$$"
  tar -C "$_DIR" -cJf "$_CLAUDE_TMP" claude
  mv -f "$_CLAUDE_TMP" "$CLAUDE_ARCHIVE"
  rm -rf "$_DIR"
  log I tools.claude cached "$(basename "$CLAUDE_ARCHIVE")"
}

# Build 3-tier tool archives. Respects OPT_BASE_HASH, OPT_TOOL_HASH,
# OPT_CLAUDE_HASH (pin to cached) and FORCE_PULL (skip cache).
# Sets: BASE_ARCHIVE, TOOL_ARCHIVE, CLAUDE_ARCHIVE
build_tool_archives() {
  mkdir -p "$TOOLS_DIR"
  # Sweep stale .partial.* archives left by interrupted previous runs
  # (we build to a temp name and atomic-rename on success, so a
  # partial archive at the final path should never exist — but the
  # temp file leaks on Ctrl-C and needs collecting).
  rm -f "$TOOLS_DIR"/*.partial.* 2>/dev/null || true

  # Fetch versions once up front if any tier is unpinned.
  # fetch_tool_versions does all 6 HTTP calls in parallel internally.
  if [ -z "${OPT_BASE_HASH:-}" ] || [ -z "${OPT_TOOL_HASH:-}" ] || [ -z "${OPT_CLAUDE_HASH:-}" ]; then
    [ -z "${NODE_VER:-}" ] && fetch_tool_versions
  fi

  # Resolve all 3 archive paths up front so the parallel workers are
  # fully independent — each just operates on the path it was given.
  if [ -n "${OPT_BASE_HASH:-}" ]; then
    BASE_ARCHIVE=$(resolve_archive "base" "$OPT_BASE_HASH")
  else
    # Strip CR so the hash matches the Windows-side Tools.ps1 computation
    # (which normalizes CRLF→LF before hashing). A CRLF checkout on a
    # Unix host would otherwise produce a cache that can never be reused
    # by a PS-side launcher against the same source.
    BASE_HASH=$(sha256 "base-node:$NODE_VER-rg:$RG_VER-micro:$MICRO_VER-$(tr -d '\r' < "$PROJECT_ROOT/bin/claude-wrapper.sh")")
    BASE_ARCHIVE="$TOOLS_DIR/base-$BASE_HASH.tar.xz"
  fi
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    TOOL_ARCHIVE=$(resolve_archive "tool" "$OPT_TOOL_HASH")
  else
    TOOL_HASH=$(sha256 "tool-pnpm:$PNPM_VER-uv:$UV_VER")
    TOOL_ARCHIVE="$TOOLS_DIR/tool-$TOOL_HASH.tar.xz"
  fi
  if [ -n "${OPT_CLAUDE_HASH:-}" ]; then
    CLAUDE_ARCHIVE=$(resolve_archive "claude" "$OPT_CLAUDE_HASH")
  else
    CLAUDE_HASH=$(sha256 "claude-$CLAUDE_VER")
    CLAUDE_ARCHIVE="$TOOLS_DIR/claude-$CLAUDE_HASH.tar.xz"
  fi

  # Fan out: 3 background subshells, one per tier. Tiers are fully
  # independent — different downloads, different archive paths, no
  # shared writable state — so the cold-cache wall time drops from
  # sum(tiers) to max(tiers). On warm cache, the 3 `tar -tJf`
  # validations also run concurrently.
  _build_base_tier &
  _BPID=$!
  _build_tool_tier &
  _TPID=$!
  _build_claude_tier &
  _CPID=$!
  wait_all "$_BPID" "$_TPID" "$_CPID"
}
