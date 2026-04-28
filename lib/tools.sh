#!/bin/sh
# tools.sh — tool archive build system (multi-agent).
# Sourced (not executed). Requires: PROJECT_ROOT, AGENT, AGENT_MANIFEST.

# sha256_file strips CR before hashing so a CRLF (Windows) checkout of
# the same commit produces the same hash as an LF (Linux) checkout —
# mirrors Tools.ps1's `Replace("`r`n", "`n")` for base-image hash parity.
# sha256_bin / sha512_bin do raw byte hashing for downloaded artifacts
# (binaries contain bytes that look like CR+LF; CR-stripping would
# corrupt the digest).
if command -v sha256sum >/dev/null 2>&1; then
  sha256()      { printf '%s' "$1" | sha256sum                | cut -d ' ' -f 1; }
  sha256_file() { tr -d '\r'       < "$1" | sha256sum         | cut -d ' ' -f 1; }
  sha256_bin()  { sha256sum                < "$1"             | cut -d ' ' -f 1; }
  sha512_bin()  { sha512sum                < "$1"             | cut -d ' ' -f 1; }
else
  sha256()      { printf '%s' "$1" | shasum -a 256            | cut -d ' ' -f 1; }
  sha256_file() { tr -d '\r'       < "$1" | shasum -a 256     | cut -d ' ' -f 1; }
  sha256_bin()  { shasum -a 256            < "$1"             | cut -d ' ' -f 1; }
  sha512_bin()  { shasum -a 512            < "$1"             | cut -d ' ' -f 1; }
fi

# Portable base64 decode: GNU coreutils uses `-d`, BSD/macOS pre-Catalina
# only accepts `-D` (newer macOS accepts both). Probe once.
if printf 'YQ==' | base64 -d >/dev/null 2>&1; then
  _base64_decode() { base64 -d; }
else
  _base64_decode() { base64 -D; }
fi

# Verify a downloaded file matches an expected sha256 hex digest. Exits 1
# on mismatch / empty expected, so the caller subshell propagates failure
# through wait_all instead of letting an unverified artifact proceed to
# extraction.
_verify_sha256() {
  _vf=$1; _vexp=$2; _vlabel=$3
  if [ -z "$_vexp" ]; then
    log E tools.verify fail "$_vlabel: empty expected sha256"
    exit 1
  fi
  _vact=$(sha256_bin "$_vf")
  if [ "$_vact" != "$_vexp" ]; then
    log E tools.verify fail "$_vlabel sha256 mismatch (expected $_vexp, got $_vact)"
    exit 1
  fi
}

# Verify a downloaded file matches an npm dist.integrity SRI value
# (`sha512-<base64>`). Decodes base64 → hex once and compares against
# the file's hex digest. POSIX-only deps (base64, od); openssl/xxd not
# required.
_verify_npm_integrity() {
  _nf=$1; _ni=$2; _nlabel=$3
  case "$_ni" in
    sha512-*) _nb64=${_ni#sha512-} ;;
    *) log E tools.verify fail "$_nlabel: unsupported integrity algorithm: $_ni"; exit 1 ;;
  esac
  _nexp_hex=$(printf '%s' "$_nb64" | _base64_decode | od -An -vtx1 | tr -d ' \n')
  if [ -z "$_nexp_hex" ]; then
    log E tools.verify fail "$_nlabel: failed to decode integrity value '$_ni'"
    exit 1
  fi
  _nact_hex=$(sha512_bin "$_nf")
  if [ "$_nact_hex" != "$_nexp_hex" ]; then
    log E tools.verify fail "$_nlabel sha512 mismatch (expected $_nexp_hex, got $_nact_hex)"
    exit 1
  fi
}

# Wait for all PIDs; report and exit if any failed.
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

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/crate"
TOOLS_DIR="$CACHE_DIR/tools"

# Distinct values grouped by the arch-suffix convention each tool uses.
# Only genuine primitives are case-branched; everything else is derived:
#   ARCH         — Node.js / pnpm suffix / npm platform sub-pkg {arch}
#                    (x64 on amd64, arm64 on arm64)
#   ARCH_GNU     — prefix of Rust-style triples
#                    (x86_64 on amd64, aarch64 on arm64)
#   ARCH_MICRO   — micro's release-asset suffix — unrelated schemes
#                    (linux64-static on amd64, linux-arm64 on arm64)
#   ARCH_RG      — ripgrep's triple — musl on amd64, gnu on arm64
#                    (BurntSushi/ripgrep doesn't ship musl arm64)
#   ARCH_TRIPLE  — full musl triple, used by uv and Codex {triple}
detect_arch() {
  _uname=$(uname -m)
  case "$_uname" in
    x86_64|amd64)
      ARCH="x64"
      ARCH_GNU="x86_64"
      ARCH_MICRO="linux64-static"
      _rg_libc="musl"
      ;;
    arm64|aarch64)
      ARCH="arm64"
      ARCH_GNU="aarch64"
      ARCH_MICRO="linux-arm64"
      _rg_libc="gnu"
      ;;
    *) log E tools fail "unsupported architecture: $_uname"; exit 1 ;;
  esac
  ARCH_TRIPLE="${ARCH_GNU}-unknown-linux-musl"
  ARCH_RG="${ARCH_GNU}-unknown-linux-${_rg_libc}"
}

# Substitute {arch}, {triple}, {version} in a template string.
_subst() {
  printf '%s' "$1" | sed \
    -e "s|{arch}|$ARCH|g" \
    -e "s|{triple}|$ARCH_TRIPLE|g" \
    -e "s|{version}|$2|g"
}

# Fetch shared tool versions in parallel.
# Sets: NODE_VER, RG_VER, MICRO_VER, PNPM_VER, UV_VER
fetch_shared_versions() {
  _DIR=$(mktemp -d)
  (curl -fsSL -A "$CRATE_USER_AGENT" https://nodejs.org/dist/index.json \
    | jq -r '[.[] | select(.lts != false)][0].version' | sed 's/^v//' > "$_DIR/node") &
  _PID1=$!
  (curl -fsSL -A "$CRATE_USER_AGENT" https://api.github.com/repos/BurntSushi/ripgrep/releases/latest \
    | jq -r .tag_name > "$_DIR/rg") &
  _PID2=$!
  (curl -fsSL -A "$CRATE_USER_AGENT" https://api.github.com/repos/zyedidia/micro/releases/latest \
    | jq -r .tag_name | sed 's/^v//' > "$_DIR/micro") &
  _PID3=$!
  # pnpm: GH release JSON gives both version and per-asset sha256
  # digest. The npm registry only exposes the npm-tarball checksum, not
  # the standalone pnpm-linux-<arch> binary that we actually download
  # from GH — different artifact, different checksum.
  (curl -fsSL -A "$CRATE_USER_AGENT" https://api.github.com/repos/pnpm/pnpm/releases/latest > "$_DIR/pnpm.json") &
  _PID4=$!
  (curl -fsSL -A "$CRATE_USER_AGENT" https://pypi.org/pypi/uv/json \
    | jq -r .info.version > "$_DIR/uv") &
  _PID5=$!
  wait_all "$_PID1" "$_PID2" "$_PID3" "$_PID4" "$_PID5"
  NODE_VER=$(cat "$_DIR/node")
  RG_VER=$(cat "$_DIR/rg")
  MICRO_VER=$(cat "$_DIR/micro")
  PNPM_VER=$(jq -r '.tag_name | sub("^v"; "")' "$_DIR/pnpm.json")
  PNPM_LINUX_SHA=$(jq -r --arg n "pnpm-linux-${ARCH}" \
    '.assets[] | select(.name == $n) | .digest // empty | sub("^sha256:"; "")' \
    "$_DIR/pnpm.json")
  UV_VER=$(cat "$_DIR/uv")
  rm -rf "$_DIR"
  if [ -z "$NODE_VER" ] || [ -z "$RG_VER" ] || [ -z "$MICRO_VER" ] || \
     [ -z "$PNPM_VER" ] || [ -z "$UV_VER" ]; then
    log E tools fail "failed to fetch one or more tool versions"
    exit 1
  fi
  if [ -z "$PNPM_LINUX_SHA" ]; then
    log E tools fail "pnpm-linux-${ARCH} digest missing from GH release assets"
    exit 1
  fi
}

# Fetch the agent's latest npm version. Sets: AGENT_VER
fetch_agent_version() {
  _pkg=$(agent_get .executable.versionPackage)
  AGENT_VER=$(curl -fsSL -A "$CRATE_USER_AGENT" "https://registry.npmjs.org/$_pkg/latest" | jq -r .version)
  if [ -z "$AGENT_VER" ]; then
    log E tools fail "failed to fetch version for $_pkg"
    exit 1
  fi
}

# Resolve a hash prefix to a cached archive path.
resolve_archive() {
  _tier="$1"; _prefix="$2"
  _matches=""; _count=0
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

# Verify a cached tier archive is intact (not zero-length, not truncated).
_archive_ok() {
  [ -f "$1" ] && [ -s "$1" ] && tar --xz -tf "$1" >/dev/null 2>&1
}

# Pick the best available xz pack strategy. Probed once, cached in
# _PACK_XZ_MODE. Order (fastest → safest):
#   1. `pipe`     — external `xz` on PATH: `tar -cf - … | xz -0 -T0`.
#                   Fastest, explicit level/thread tuning. Fedora ships
#                   xz by default (dnf/rpm dependency). macOS does not;
#                   users install via `brew install xz`.
#   2. `bsdtar`   — tar is libarchive bsdtar: use `--xz --options
#                   'xz:compression-level=0,xz:threads=0'`. No external
#                   binary needed. macOS bsdtar and Windows bsdtar
#                   support this; GNU tar does not have `--options`.
#   3. `fallback` — `tar --xz` with default level (6) and single thread.
#                   Works everywhere but ~10× slower to pack than the
#                   top two paths. Warned at detection time.
_detect_pack_xz_mode() {
  [ -n "${_PACK_XZ_MODE:-}" ] && return 0
  if command -v xz >/dev/null 2>&1; then
    _PACK_XZ_MODE=pipe
  elif tar --version 2>&1 | head -1 | grep -qi bsdtar; then
    _PACK_XZ_MODE=bsdtar
  else
    _PACK_XZ_MODE=fallback
    log W tools.pack fallback "no xz CLI and tar is not bsdtar; using \`tar --xz\` defaults (slower)"
  fi
}

# Pack files into an xz-compressed tar archive using the detected mode.
# Args: OUT_PATH DIR FILES...
_pack_xz() {
  _detect_pack_xz_mode
  _pxz_out="$1"; _pxz_dir="$2"; shift 2
  case "$_PACK_XZ_MODE" in
    pipe)
      tar -C "$_pxz_dir" -cf - "$@" | xz -0 -T0 -c > "$_pxz_out"
      ;;
    bsdtar)
      tar -C "$_pxz_dir" --xz --options 'xz:compression-level=0,xz:threads=0' -cf "$_pxz_out" "$@"
      ;;
    fallback)
      tar -C "$_pxz_dir" --xz -cf "$_pxz_out" "$@"
      ;;
  esac
}

# ── Per-tier builders ──

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

  # Each subshell: download to disk → fetch publisher checksum → verify
  # → extract. Verifying before extract is the whole point — a hostile
  # tarball could otherwise drop binaries the build then chmod +x'es.
  (
    _name="node-v${NODE_VER}-linux-${ARCH}.tar.xz"
    _file="$_DIR/_node.tar.xz"
    curl -fsSL -A "$CRATE_USER_AGENT" "https://nodejs.org/dist/v${NODE_VER}/$_name" -o "$_file"
    # Node ships one SHASUMS256.txt covering every platform tarball.
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "https://nodejs.org/dist/v${NODE_VER}/SHASUMS256.txt" \
      | awk -v n="$_name" '$2 == n {print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "node $_name"
    tar -xJ --strip-components=2 -C "$_DIR" -f "$_file" "node-v${NODE_VER}-linux-${ARCH}/bin/node"
    rm -f "$_file"
  ) &
  _PID1=$!
  (
    _url="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-${ARCH_RG}.tar.gz"
    _file="$_DIR/_rg.tar.gz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_file"
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "${_url}.sha256" | awk '{print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "ripgrep"
    tar -xz --strip-components=1 -C "$_DIR" -f "$_file" "ripgrep-${RG_VER}-${ARCH_RG}/rg"
    rm -f "$_file"
  ) &
  _PID2=$!
  (
    _url="https://github.com/zyedidia/micro/releases/download/v${MICRO_VER}/micro-${MICRO_VER}-${ARCH_MICRO}.tar.gz"
    _file="$_DIR/_micro.tar.gz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_file"
    # micro uses '.sha' (not '.sha256') as its sidecar suffix; the
    # contents are still the standard '<sha256>  <filename>' format.
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "${_url}.sha" | awk '{print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "micro"
    tar -xz --strip-components=1 -C "$_DIR" -f "$_file" "micro-${MICRO_VER}/micro"
    rm -f "$_file"
  ) &
  _PID3=$!
  wait_all "$_PID1" "$_PID2" "$_PID3"

  chmod +x "$_DIR/node" "$_DIR/rg" "$_DIR/micro"
  log I tools.base packing "$(basename "$BASE_ARCHIVE")"
  # mktemp (not "$$") so a stale predictable-named partial from a prior
  # run can't be picked up as ours. The .partial.* glob in
  # build_tool_archives still matches because mktemp appends to the
  # template suffix.
  _BASE_TMP=$(mktemp "$BASE_ARCHIVE.partial.XXXXXXXX")
  _pack_xz "$_BASE_TMP" "$_DIR" node rg micro
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

  (
    _url="https://github.com/pnpm/pnpm/releases/download/v${PNPM_VER}/pnpm-linux-${ARCH}"
    _file="$_DIR/pnpm"
    curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_file"
    # pnpm ships no per-asset sidecar checksum file; fetch_shared_versions
    # captured the GH release API's per-asset 'digest' into PNPM_LINUX_SHA.
    _verify_sha256 "$_file" "$PNPM_LINUX_SHA" "pnpm-linux-${ARCH}"
  ) &
  _PID1=$!
  (
    _url="https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${ARCH_TRIPLE}.tar.gz"
    _file="$_DIR/_uv.tar.gz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_file"
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "${_url}.sha256" | awk '{print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "uv"
    tar -xz --strip-components=1 -C "$_DIR" -f "$_file"
    rm -f "$_file"
  ) &
  _PID2=$!
  wait_all "$_PID1" "$_PID2"

  chmod +x "$_DIR/pnpm" "$_DIR/uv" "$_DIR/uvx"
  log I tools.tool packing "$(basename "$TOOL_ARCHIVE")"
  _TOOL_TMP=$(mktemp "$TOOL_ARCHIVE.partial.XXXXXXXX")
  _pack_xz "$_TOOL_TMP" "$_DIR" pnpm uv uvx
  mv -f "$_TOOL_TMP" "$TOOL_ARCHIVE"
  rm -rf "$_DIR"
  log I tools.tool cached "$(basename "$TOOL_ARCHIVE")"
}

# POSIX shell-quote a value: wrap in single quotes with each embedded
# `'` rewritten as `'\''`. The result round-trips through `. file` for
# any byte sequence — including newlines and quotes — so a manifest
# value can no longer corrupt the agent-manifest.sh sourced by the
# wrapper. Bash parameter expansion (${var//pat/repl}) is the only
# non-POSIX feature; this whole library is bash-only (see
# init-launcher.sh's `set -o pipefail` and bash-array note).
_sh_quote() {
  _q=${1//\'/\'\\\'\'}
  printf "'%s'" "$_q"
}

# Generate the per-agent agent-manifest.sh that the wrapper sources at
# startup. Outputs to stdout. Contents are derived from manifest fields
# so any change to binary/flags/env invalidates the tier-3 cache via
# _agent_manifest_sh_contents being included in the tier hash.
#
# Every value is POSIX single-quoted via _sh_quote so the file is safe
# to `. source` regardless of what's in the manifest. Env keys are
# validated against [A-Za-z_][A-Za-z0-9_]* before emission — a bad key
# would either invalidate sh syntax or shell-inject through the
# unquoted `export <key>=...` slot.
_agent_manifest_sh_contents() {
  _binary=$(agent_get .binary)
  printf 'AGENT_BINARY='; _sh_quote "$_binary"; printf '\n'
  # Emit launch.flags as a function body so each flag preserves its
  # argument boundary across the manifest → wrapper boundary. A flat
  # space-joined string would lose boundaries on any flag value
  # containing whitespace, an empty string, or shell metacharacters,
  # and the wrapper's word-splitting expansion would then misframe
  # subsequent args. The wrapper calls
  #   exec_agent_with_flags "$_bin" "$@"
  # to exec with flags-then-user-args.
  printf 'exec_agent_with_flags() {\n  _eaf_bin=$1\n  shift\n  exec "$_eaf_bin"'
  while IFS= read -r -d '' _flag; do
    printf ' '
    _sh_quote "$_flag"
  done < <(jq -j '.launch.flags // [] | map(. + "\u0000") | add // ""' "$AGENT_MANIFEST")
  printf ' "$@"\n}\n'
  # Point the agent's config-dir env var at the system staging path.
  # Skipped for agents whose manifest.configDir.env is empty (Gemini) —
  # they read from the hard-coded default under $HOME, mounted there.
  # CRATE_ENV is already shell-name-validated in agent_load.
  if [ -n "${CRATE_ENV:-}" ]; then
    printf 'export %s=' "$CRATE_ENV"; _sh_quote "$CRATE_DIR"; printf '\n'
  fi
  # Iterate launch.env via NUL-separated key,value,key,value out of jq
  # so newlines and embedded quotes survive the jq → shell handoff.
  while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
    case "$_k" in
      [A-Za-z_]*) ;;
      *) log E launcher fail "invalid launch.env key in $AGENT_MANIFEST: '$_k' (must match [A-Za-z_][A-Za-z0-9_]*)"; exit 1 ;;
    esac
    case "$_k" in
      *[!A-Za-z0-9_]*)
        log E launcher fail "invalid launch.env key in $AGENT_MANIFEST: '$_k' (must match [A-Za-z_][A-Za-z0-9_]*)"
        exit 1
        ;;
    esac
    printf 'export %s=' "$_k"; _sh_quote "$_v"; printf '\n'
  done < <(jq -j '.launch.env // {} | to_entries[] | "\(.key)\u0000\(.value)\u0000"' "$AGENT_MANIFEST")
}

_build_agent_tier() {
  if [ -n "${OPT_AGENT_HASH:-}" ]; then
    if ! _archive_ok "$AGENT_ARCHIVE"; then
      log E "tools.$AGENT" fail "pinned archive is corrupt: $(basename "$AGENT_ARCHIVE")"
      return 1
    fi
    log I "tools.$AGENT" cache-pin "$(basename "$AGENT_ARCHIVE")"
    return 0
  fi
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$AGENT_ARCHIVE"; then
    log I "tools.$AGENT" cache-hit "$(basename "$AGENT_ARCHIVE")"
    return 0
  fi
  if [ -f "$AGENT_ARCHIVE" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W "tools.$AGENT" rebuild "cached archive corrupt; rebuilding"
    rm -f "$AGENT_ARCHIVE"
  fi

  _type=$(agent_get .executable.type)
  _tarball=$(_subst "$(agent_get .executable.tarballUrl)" "$AGENT_VER")
  log I "tools.$AGENT" downloading "$AGENT $AGENT_VER ($_type)"

  # Resolve npm package name AND tarball-version from the URL. The
  # version we look up MUST match the tarball we download — codex
  # publishes per-platform binaries as version-suffixed releases
  # (`0.125.0-linux-x64`, `0.125.0-darwin-arm64`, …) under the same
  # `@openai/codex` package, so the integrity for `0.125.0` (the JS
  # wrapper) is NOT the integrity for `0.125.0-linux-x64` (the
  # platform binary we actually fetch). Extract the version from the
  # tarball's basename instead of using $AGENT_VER, which only knows
  # the wrapper's version. URL shape: `<scope>/<name>/-/<basename>-<version>.tgz`.
  # Restrict to registry.npmjs.org so a manifest can't redirect the
  # verification step at an attacker-controlled metadata host.
  case "$_tarball" in
    https://registry.npmjs.org/*)
      _rest=${_tarball#https://registry.npmjs.org/}
      _pkg=${_rest%%/-/*}
      _filename=${_rest##*/-/}
      _pkg_base=${_pkg##*/}
      case "$_filename" in
        "${_pkg_base}-"*.tgz)
          _tar_ver=${_filename#${_pkg_base}-}
          _tar_ver=${_tar_ver%.tgz}
          ;;
        *)
          log E "tools.$AGENT" fail "tarball filename does not match '<pkg>-<version>.tgz' shape: $_filename (pkg=$_pkg_base)"
          exit 1
          ;;
      esac
      ;;
    *)
      log E "tools.$AGENT" fail "unsupported tarball host (only registry.npmjs.org is allowed): $_tarball"
      exit 1
      ;;
  esac
  _meta_url="https://registry.npmjs.org/$_pkg/$_tar_ver"
  _integrity=$(curl -fsSL -A "$CRATE_USER_AGENT" "$_meta_url" | jq -r '.dist.integrity // empty')
  if [ -z "$_integrity" ]; then
    log E "tools.$AGENT" fail "no dist.integrity at $_meta_url"
    exit 1
  fi

  _DIR=$(mktemp -d)
  _EXTRACT="$_DIR/extract"
  _TARFILE="$_DIR/_agent.tgz"
  mkdir -p "$_EXTRACT"
  curl -fsSL -A "$CRATE_USER_AGENT" "$_tarball" -o "$_TARFILE"
  _verify_npm_integrity "$_TARFILE" "$_integrity" "$AGENT npm tarball"
  tar -xz -C "$_EXTRACT" -f "$_TARFILE"
  rm -f "$_TARFILE"

  _binary=$(agent_get .binary)

  case "$_type" in
    platform-binary)
      _binPath=$(_subst "$(agent_get .executable.binPath)" "$AGENT_VER")
      _src="$_EXTRACT/$_binPath"
      if [ ! -f "$_src" ]; then
        log E "tools.$AGENT" fail "binary not found in tarball: $_binPath"
        exit 1
      fi
      cp "$_src" "$_DIR/${_binary}-bin"
      chmod +x "$_DIR/${_binary}-bin"
      ;;
    node-bundle)
      _entryPath=$(_subst "$(agent_get .executable.entryPath)" "$AGENT_VER")
      _pkg="${_binary}-pkg"
      # Relocate extract/ → <binary>-pkg/ for clarity and a stable
      # on-disk path (~/.local/lib/<binary>-pkg/) inside the sandbox.
      if [ -d "$_EXTRACT/package" ]; then
        mv "$_EXTRACT/package" "$_DIR/$_pkg"
      else
        log E "tools.$AGENT" fail "node bundle has no 'package/' dir"
        exit 1
      fi
      _entryRel=${_entryPath#package/}
      # Render the node-bundle shim from bin/agent-node-shim.sh.tmpl.
      # Bash parameter expansion is enough — `{{PKG}}` / `{{ENTRY}}` are
      # plain strings (no glob metachars), so ${var//pat/repl} replaces
      # them literally. Strip CR so a CRLF checkout doesn't pack a
      # `#!/usr/bin/env sh\r` shebang (broken on Linux) — and matches
      # the normalized bytes the tier-3 hash is computed from.
      _shim=$(tr -d '\r' < "$PROJECT_ROOT/bin/agent-node-shim.sh.tmpl")
      _shim=${_shim//\{\{PKG\}\}/$_pkg}
      _shim=${_shim//\{\{ENTRY\}\}/$_entryRel}
      printf '%s' "$_shim" > "$_DIR/${_binary}-bin"
      chmod +x "$_DIR/${_binary}-bin"
      ;;
    *)
      log E "tools.$AGENT" fail "unknown executable.type: $_type"
      exit 1
      ;;
  esac

  # Ship the wrapper under the agent's command name (regular file, not
  # a symlink) — keeps behavior identical across Linux/WSL/Windows
  # host filesystems where symlink creation quirks would otherwise
  # require an OS-specific fallback. Strip CR so Windows checkouts
  # (git autocrlf) pack a Linux-compatible #!/usr/bin/env sh shebang.
  tr -d '\r' < "$PROJECT_ROOT/bin/agent-wrapper.sh" > "$_DIR/$_binary"
  _agent_manifest_sh_contents > "$_DIR/agent-manifest.sh"
  chmod +x "$_DIR/$_binary"

  rm -rf "$_EXTRACT"

  log I "tools.$AGENT" packing "$(basename "$AGENT_ARCHIVE")"
  _AGENT_TMP=$(mktemp "$AGENT_ARCHIVE.partial.XXXXXXXX")
  if [ "$_type" = "node-bundle" ]; then
    _pack_xz "$_AGENT_TMP" "$_DIR" "$_binary" agent-manifest.sh "${_binary}-bin" "${_binary}-pkg"
  else
    _pack_xz "$_AGENT_TMP" "$_DIR" "$_binary" agent-manifest.sh "${_binary}-bin"
  fi
  mv -f "$_AGENT_TMP" "$AGENT_ARCHIVE"
  rm -rf "$_DIR"
  log I "tools.$AGENT" cached "$(basename "$AGENT_ARCHIVE")"
}

# Build 3-tier tool archives. Respects OPT_BASE_HASH, OPT_TOOL_HASH,
# OPT_AGENT_HASH (pin to cached) and FORCE_PULL (skip cache).
# Sets: BASE_ARCHIVE, TOOL_ARCHIVE, AGENT_ARCHIVE
build_tool_archives() {
  mkdir -p "$TOOLS_DIR"
  # Reap ORPHAN partials from prior builds that crashed. The cache dir
  # is shared across concurrent launchers — a blanket `rm -f *.partial.*`
  # would race-delete another active launcher's in-progress archive
  # (its `mv -f` would then fail). Each launch's partial is uniquely
  # named via mktemp; a successful build always consumes its own
  # partial via `mv -f`. Anything older than the threshold is by
  # definition abandoned, so age-gating cleanup never touches a live
  # builder's file. Both GNU find (Linux) and BSD find (macOS) support
  # -mmin and -delete.
  find "$TOOLS_DIR" -maxdepth 1 -name '*.partial.*' -mmin +60 -delete 2>/dev/null || true

  # Fetch versions once up front if any tier is unpinned. Shared tier
  # versions (node/rg/micro/pnpm/uv) and the agent version are
  # independent — fetch whichever subset we need.
  _need_shared=0
  _need_agent=0
  [ -z "${OPT_BASE_HASH:-}" ] && _need_shared=1
  [ -z "${OPT_TOOL_HASH:-}" ] && _need_shared=1
  [ -z "${OPT_AGENT_HASH:-}" ] && _need_agent=1
  if [ "$_need_shared" = 1 ] && [ -z "${NODE_VER:-}" ]; then
    fetch_shared_versions
  fi
  if [ "$_need_agent" = 1 ] && [ -z "${AGENT_VER:-}" ]; then
    fetch_agent_version
  fi

  # Archive path resolution.
  if [ -n "${OPT_BASE_HASH:-}" ]; then
    BASE_ARCHIVE=$(resolve_archive "base" "$OPT_BASE_HASH")
  else
    BASE_HASH=$(sha256 "base-node:$NODE_VER-rg:$RG_VER-micro:$MICRO_VER")
    BASE_ARCHIVE="$TOOLS_DIR/base-$BASE_HASH.tar.xz"
  fi
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    TOOL_ARCHIVE=$(resolve_archive "tool" "$OPT_TOOL_HASH")
  else
    TOOL_HASH=$(sha256 "tool-pnpm:$PNPM_VER-uv:$UV_VER")
    TOOL_ARCHIVE="$TOOLS_DIR/tool-$TOOL_HASH.tar.xz"
  fi
  if [ -n "${OPT_AGENT_HASH:-}" ]; then
    AGENT_ARCHIVE=$(resolve_archive "$AGENT" "$OPT_AGENT_HASH")
  else
    # Include manifest source, generated agent-manifest.sh, and wrapper
    # source in the hash. Generated-sh catches changes to the generator
    # itself (e.g. adding the CLAUDE_CONFIG_DIR export). Strip CR so
    # Windows-side (CRLF) and Linux-side (LF) hashes match for the same
    # checkout.
    _manifest_src=$(tr -d '\r' < "$AGENT_MANIFEST")
    _manifest_sh=$(_agent_manifest_sh_contents)
    _wrapper_src=$(tr -d '\r' < "$PROJECT_ROOT/bin/agent-wrapper.sh")
    _shim_tmpl=$(tr -d '\r' < "$PROJECT_ROOT/bin/agent-node-shim.sh.tmpl")
    AGENT_HASH=$(sha256 "agent:$AGENT-ver:$AGENT_VER-arch:$ARCH-manifest:$_manifest_src-manifest-sh:$_manifest_sh-wrapper:$_wrapper_src-shim:$_shim_tmpl")
    AGENT_ARCHIVE="$TOOLS_DIR/$AGENT-$AGENT_HASH.tar.xz"
  fi

  _build_base_tier &
  _BPID=$!
  _build_tool_tier &
  _TPID=$!
  _build_agent_tier &
  _APID=$!
  wait_all "$_BPID" "$_TPID" "$_APID"
}
