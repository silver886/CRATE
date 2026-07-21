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

# Render shims from bin/node-shim.sh.tmpl for every entry in
# PKG_DIR/package.json's `.bin` map. Validates bin names, writes one
# shim per entry into OUT_DIR (with +x), and prints the rendered
# filenames space-joined to stdout — caller captures via $(...) for
# pack inputs.
#
# CANON_IN/CANON_OUT route the shim for the bin entry named CANON_IN
# to filename CANON_OUT instead of the bin key. The agent tier passes
# ($binary, ${binary}-bin) so agent-wrapper.sh finds its entry; the
# tool tier passes ("","") since there's no wrapper layer.
#
# Args: OUT_DIR  PKG_DIR  PKG_NAME  CANON_IN  CANON_OUT  STAGE
_render_node_bin_shims() {
  _rb_out_dir=$1; _rb_pkg_dir=$2; _rb_pkg_name=$3
  _rb_canon_in=$4; _rb_canon_out=$5; _rb_stage=$6
  _rb_pkg_json="$_rb_pkg_dir/package.json"
  if [ ! -f "$_rb_pkg_json" ]; then
    log E "$_rb_stage" fail "package.json missing at $_rb_pkg_json"
    exit 1
  fi
  _rb_tmpl=$(tr -d '\r' < "$PROJECT_ROOT/bin/node-shim.sh.tmpl")
  _rb_files=""
  _rb_saw_canon=0
  while IFS= read -r -d '' _rb_name && IFS= read -r -d '' _rb_path; do
    # Validate bin key: rejects path separators, shell metas, leading
    # hyphen (would look like a flag), and leading dot (no `..`).
    case "$_rb_name" in
      ''|*[!A-Za-z0-9._-]*|-*|.*)
        log E "$_rb_stage" fail "invalid bin name in $_rb_pkg_json: '$_rb_name'"
        exit 1 ;;
    esac
    _rb_entry=${_rb_path#./}
    # Validate bin path: must be relative, no traversal, safe segments.
    # Interpolated into the shim's `exec node "$HOME/.local/lib/PKG/{{ENTRY}}"`
    # template — a quote, backslash, control char, newline, or '..' would
    # either break the double-quoted shell literal, escape the package
    # dir, or surface as an invalid filesystem write target. Mirrors the
    # existing per-segment whitelist used for .binary / .projectDir /
    # files.* entries elsewhere in the loader.
    case "$_rb_entry" in
      ''|/*)
        log E "$_rb_stage" fail "invalid bin path in $_rb_pkg_json: '$_rb_path' (must be a non-empty relative path)"
        exit 1
        ;;
    esac
    _rb_old_ifs=$IFS
    IFS=/
    for _rb_seg in $_rb_entry; do
      case "$_rb_seg" in
        ''|.|..|*[!A-Za-z0-9._-]*)
          IFS=$_rb_old_ifs
          log E "$_rb_stage" fail "invalid bin path segment in $_rb_pkg_json: '$_rb_path' (segment '$_rb_seg' must match [A-Za-z0-9._-]+ and not be '.' or '..')"
          exit 1
          ;;
      esac
    done
    IFS=$_rb_old_ifs
    if [ -n "$_rb_canon_in" ] && [ "$_rb_name" = "$_rb_canon_in" ]; then
      _rb_target=$_rb_canon_out
      _rb_saw_canon=1
    else
      _rb_target=$_rb_name
      # Reject aux-shim collisions with reserved agent-tier filenames.
      # Only relevant when a canonical mapping is in effect (tool tier
      # has no wrapper / manifest, so this check naturally skips).
      if [ -n "$_rb_canon_in" ]; then
        case "$_rb_target" in
          agent-manifest.sh|"$_rb_canon_in"|"$_rb_canon_out"|"${_rb_canon_in}-pkg")
            log E "$_rb_stage" fail "aux bin '$_rb_name' collides with reserved filename"
            exit 1 ;;
        esac
      fi
    fi
    _rb_shim=${_rb_tmpl//\{\{PKG\}\}/$_rb_pkg_name}
    _rb_shim=${_rb_shim//\{\{ENTRY\}\}/$_rb_entry}
    printf '%s' "$_rb_shim" > "$_rb_out_dir/$_rb_target"
    chmod +x "$_rb_out_dir/$_rb_target"
    _rb_files="$_rb_files $_rb_target"
  done < <(jq -j '
    if (.bin | type) == "object" then
      .bin | to_entries[] | "\(.key)\u0000\(.value)\u0000"
    else
      error("package.json: .bin must be an object, got \(.bin | type)")
    end
  ' "$_rb_pkg_json")
  if [ -z "$_rb_files" ]; then
    log E "$_rb_stage" fail "$_rb_pkg_json: no .bin entries rendered"
    exit 1
  fi
  if [ -n "$_rb_canon_in" ] && [ "$_rb_saw_canon" = 0 ]; then
    log E "$_rb_stage" fail "canonical bin '$_rb_canon_in' not found in $_rb_pkg_json"
    exit 1
  fi
  printf '%s' "${_rb_files# }"
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
#   ARCH_TRIPLE  — full musl triple, used by Codex {triple}
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

# Fetch base-tier versions (node, ripgrep, micro) in parallel.
# Sets: NODE_VER, RG_VER, MICRO_VER. Called inside the base pipeline.
fetch_base_versions() {
  _DIR=$(mktemp -d)
  (curl -fsSL -A "$CRATE_USER_AGENT" https://nodejs.org/dist/index.json \
    | jq -r '[.[] | select(.lts != false)][0].version' | sed 's/^v//' > "$_DIR/node") &
  _PID1=$!
  # ripgrep: crates.io is the canonical registry (BurntSushi publishes
  # there in lock-step with GH releases). Hitting the API there avoids
  # GH's 60 req/hour unauthenticated rate limit.
  (curl -fsSL -A "$CRATE_USER_AGENT" https://crates.io/api/v1/crates/ripgrep \
    | jq -r .crate.max_stable_version > "$_DIR/rg") &
  _PID2=$!
  # micro is GH-only, so we resolve the version via the web-side
  # `releases/latest` redirect — github.com (not api.github.com) — which
  # is not subject to the API rate limit. The Location header points to
  # `releases/tag/v<version>`; strip the leading `v`.
  (_final=$(curl -fsSLI -A "$CRATE_USER_AGENT" -o /dev/null -w '%{url_effective}' \
     https://github.com/micro-editor/micro/releases/latest)
   _tag=${_final##*/}
   printf '%s' "${_tag#v}" > "$_DIR/micro") &
  _PID3=$!
  wait_all "$_PID1" "$_PID2" "$_PID3"
  NODE_VER=$(cat "$_DIR/node")
  RG_VER=$(cat "$_DIR/rg")
  MICRO_VER=$(cat "$_DIR/micro")
  rm -rf "$_DIR"
  # micro guard: a failed or un-redirected `releases/latest` leaves the
  # literal tail "latest" (or "releases" for a repo with no releases) as
  # the "version". Reject all three so a hiccup fails loudly here instead
  # of 404-ing on a bogus `micro-latest-…` download URL later. Mirrors
  # the agent github version guard in fetch_agent_version.
  case "$MICRO_VER" in
    ''|releases|latest) log E tools.base fail "failed to resolve a micro release tag (got '${MICRO_VER:-}')"; exit 1 ;;
  esac
  if [ -z "$NODE_VER" ] || [ -z "$RG_VER" ]; then
    log E tools.base fail "failed to fetch node/ripgrep version"
    exit 1
  fi
}

# Fetch tool-tier versions + pnpm/uv metadata (pnpm, uv) in parallel.
# Sets: PNPM_VER, UV_VER, PNPM_TARBALL_URL, PNPM_NPM_INTEGRITY,
# UV_WHL_URL, UV_PYPI_INTEGRITY. Called inside the tool pipeline.
fetch_tool_versions() {
  _DIR=$(mktemp -d)
  # pnpm: full `latest` metadata in one fetch — gets version, tarball
  # URL, and sha512 SRI in a single ~3 KB response. We use the vanilla
  # `pnpm` package (mjs node-bundle, ~17 MB unpacked) executed against
  # the node we already ship in the base tier, NOT the per-arch
  # @pnpm/linuxstatic-<arch> Node SEA (~140 MB unpacked, ~123 MB of
  # which is bundled node — wasted bytes for us).
  (curl -fsSL -A "$CRATE_USER_AGENT" https://registry.npmjs.org/pnpm/latest \
    > "$_DIR/pnpm.json") &
  _PID1=$!
  # Full PyPI metadata (not just .info.version): we also parse the
  # matching musllinux wheel's download URL + sha256 digest out of the
  # same ~4 MB response — one-fetch-many-fields, like pnpm above.
  (curl -fsSL -A "$CRATE_USER_AGENT" https://pypi.org/pypi/uv/json \
    > "$_DIR/uv.json") &
  _PID2=$!
  wait_all "$_PID1" "$_PID2"
  _pnpm_meta=$(cat "$_DIR/pnpm.json")
  _uv_meta=$(cat "$_DIR/uv.json")
  rm -rf "$_DIR"
  PNPM_VER=$(printf '%s' "$_pnpm_meta" | jq -r '.version // empty')
  PNPM_TARBALL_URL=$(printf '%s' "$_pnpm_meta" | jq -r '.dist.tarball // empty')
  PNPM_NPM_INTEGRITY=$(printf '%s' "$_pnpm_meta" | jq -r '.dist.integrity // empty')
  UV_VER=$(printf '%s' "$_uv_meta" | jq -r '.info.version // empty')
  # Select the uv wheel whose filename contains 'musllinux' followed by
  # this host's Rust-arch token ($ARCH_GNU, e.g. x86_64 / aarch64) — the
  # musllinux wheel is statically linked, so it runs in the sandbox
  # regardless of the host libc. `index` mirrors Tools.ps1's substring
  # scan (find 'musllinux', then look for the arch after it, 9 = len
  # 'musllinux'); `first` takes the earliest match. Emits the URL on the
  # first line and the sha256 digest on the second.
  {
    IFS= read -r UV_WHL_URL
    IFS= read -r UV_PYPI_INTEGRITY
  } <<EOF
$(printf '%s' "$_uv_meta" | jq -r --arg arch "$ARCH_GNU" '
    [ .urls[]
      | select(
          (.filename | index("musllinux")) as $i
          | $i != null and (.filename[$i + 9:] | index($arch)) != null
        )
    ]
    | first
    | (.url // ""), (.digests.sha256 // "")')
EOF
  if [ -z "$PNPM_VER" ] || [ -z "$UV_VER" ]; then
    log E tools.tool fail "failed to fetch pnpm/uv version"
    exit 1
  fi
  if [ -z "$PNPM_TARBALL_URL" ] || [ -z "$PNPM_NPM_INTEGRITY" ]; then
    log E tools.tool fail "pnpm $PNPM_VER: missing dist.tarball / dist.integrity"
    exit 1
  fi
  if [ -z "$UV_WHL_URL" ] || [ -z "$UV_PYPI_INTEGRITY" ]; then
    log E tools.tool fail "uv $UV_VER: missing urls.url / urls.digests.sha256 where urls.filename matches 'musllinux*$ARCH_GNU'"
    exit 1
  fi
  # Pinning the URL host to registry.npmjs.org matches the agent-tier
  # policy: a compromised metadata redirect can't point us at an
  # attacker host.
  case "$PNPM_TARBALL_URL" in
    https://registry.npmjs.org/*) ;;
    *) log E tools.tool fail "pnpm tarball URL not on registry.npmjs.org: $PNPM_TARBALL_URL"; exit 1 ;;
  esac
  # Same host-pinning policy for uv: PyPI serves wheel payloads off
  # files.pythonhosted.org, so a tampered metadata URL can't redirect the
  # download to an attacker-controlled host.
  case "$UV_WHL_URL" in
    https://files.pythonhosted.org/*) ;;
    *) log E tools.tool fail "uv wheel URL not on files.pythonhosted.org: $UV_WHL_URL"; exit 1 ;;
  esac
}

# Determine the executable source from which of `.executable.npm` /
# `.executable.github` is set (exactly one required), validate that value
# (it flows into a download URL), and publish _EXEC_SOURCE (npm|github) and
# _EXEC_VALUE (the npm package, or the github 'owner/name'). The value
# doubles as the version handle and the URL id-prefix. Call this DIRECTLY,
# never inside $(), so a validation `exit` propagates to the script.
_resolve_exec_source() {
  _es_npm=$(agent_get .executable.npm)
  _es_github=$(agent_get .executable.github)
  if [ -n "$_es_npm" ] && [ -n "$_es_github" ]; then
    log E tools.agent fail "executable sets both .npm and .github; set exactly one"
    exit 1
  elif [ -n "$_es_npm" ]; then
    # npm package name (scoped allowed): @, alphanumerics, . _ - and /.
    case "$_es_npm" in
      *[!A-Za-z0-9._@/-]*|*..*|/*|*/)
        log E tools.agent fail "invalid executable.npm package: '$_es_npm' (chars [A-Za-z0-9._@/-], no '..')"
        exit 1 ;;
    esac
    _EXEC_SOURCE=npm; _EXEC_VALUE=$_es_npm
  elif [ -n "$_es_github" ]; then
    # GitHub 'owner/name': exactly two safe segments.
    case "$_es_github" in
      */*/*|*[!A-Za-z0-9._/-]*|*..*|/*|*/)
        log E tools.agent fail "invalid executable.github repo: '$_es_github' (must be 'owner/name', chars [A-Za-z0-9._-])"
        exit 1 ;;
      */*) ;;
      *)
        log E tools.agent fail "invalid executable.github repo: '$_es_github' (must be 'owner/name')"
        exit 1 ;;
    esac
    _EXEC_SOURCE=github; _EXEC_VALUE=$_es_github
  else
    log E tools.agent fail "executable sets neither .npm nor .github; set exactly one"
    exit 1
  fi
}

# Fetch the agent's latest version. Sets: AGENT_VER.
# npm reads `<pkg>/latest` from the registry; github resolves the
# `releases/latest` redirect (web, not api.github.com, so it dodges the
# 60 req/hr API rate limit — same trick the base tier uses for micro) and
# takes the tag verbatim (the download URL path uses the tag as published,
# so no `v` strip).
fetch_agent_version() {
  _resolve_exec_source
  case "$_EXEC_SOURCE" in
    github)
      _final=$(curl -fsSLI -A "$CRATE_USER_AGENT" -o /dev/null -w '%{url_effective}' \
        "https://github.com/$_EXEC_VALUE/releases/latest")
      AGENT_VER=${_final##*/}
      # The tag is the last path segment of the redirect target
      # (`…/releases/tag/<tag>`). If the redirect didn't happen — repo has
      # no releases (`…/releases`, segment "releases") or a transient
      # error left us on the original URL (segment "latest") — the segment
      # is one of those literals, never a real tag. Reject all three so a
      # hiccup fails loudly here instead of 404-ing on a bogus tag later.
      case "$AGENT_VER" in
        ''|releases|latest) log E tools fail "failed to resolve a release tag for $_EXEC_VALUE (got '${AGENT_VER:-}')"; exit 1 ;;
      esac
      ;;
    npm)
      AGENT_VER=$(curl -fsSL -A "$CRATE_USER_AGENT" "https://registry.npmjs.org/$_EXEC_VALUE/latest" | jq -r .version)
      if [ -z "$AGENT_VER" ]; then
        log E tools fail "failed to fetch version for $_EXEC_VALUE"
        exit 1
      fi
      ;;
  esac
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

# Extract a ZIP archive (e.g. a PyPI wheel) into DEST_DIR. GNU tar — a
# supported `tar` on Linux per the README — cannot read zip, so prefer
# `unzip`; fall back to a libarchive `tar` (bsdtar, the macOS/Windows
# default, which auto-detects zip regardless of the format flags). Errors
# if neither is available: the uv binaries live inside a wheel and
# there's no way in with the rest of the required toolchain. Mirrors
# Tools.ps1's `tar -xzf` on the wheel, where the platform tar is always
# bsdtar. Args: ZIP_FILE  DEST_DIR
_extract_zip() {
  _ez_file=$1; _ez_dest=$2
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$_ez_file" -d "$_ez_dest"
  elif tar --version 2>&1 | head -1 | grep -qi bsdtar; then
    tar -xf "$_ez_file" -C "$_ez_dest"
  else
    log E tools.tool fail "cannot extract wheel: need 'unzip' or a libarchive tar (GNU tar can't read zip archives)"
    exit 1
  fi
}

# ── Per-tier builders ──

# Each `_build_*_tier` is a self-contained pipeline: resolve its own
# versions + archive path, cache-check, build, pack — and print ONLY its
# resolved archive path on stdout (all progress goes to stderr via log()).
# build_tool_archives runs the three concurrently and captures the paths.
# An unrecoverable error `exit 1`s the tier subshell, caught by wait_all.
_build_base_tier() {
  if [ -n "${OPT_BASE_HASH:-}" ]; then
    _arch=$(resolve_archive "base" "$OPT_BASE_HASH")
    if ! _archive_ok "$_arch"; then
      log E tools.base fail "pinned archive is corrupt: $(basename "$_arch")"
      exit 1
    fi
    log I tools.base cache-pin "$(basename "$_arch")"
    printf '%s' "$_arch"; return 0
  fi
  log I tools.base resolving "latest version"
  fetch_base_versions
  # arch:$ARCH in the seed because the packed binaries (node, rg, micro)
  # are architecture-specific — an x64 and an arm64 host sharing $TOOLS_DIR
  # would otherwise collide on the same `base-*.tar.xz` filename and inject
  # the wrong binaries.
  _arch="$TOOLS_DIR/base-$(sha256 "base-arch:$ARCH-node:$NODE_VER-rg:$RG_VER-micro:$MICRO_VER").tar.xz"
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$_arch"; then
    log I tools.base cache-hit "$(basename "$_arch")"
    printf '%s' "$_arch"; return 0
  fi
  if [ -f "$_arch" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.base rebuild "cached archive corrupt; rebuilding"
    rm -f "$_arch"
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
    _url="https://github.com/micro-editor/micro/releases/download/v${MICRO_VER}/micro-${MICRO_VER}-${ARCH_MICRO}.tar.gz"
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
  log I tools.base packing "$(basename "$_arch")"
  # mktemp (not "$$") so a stale predictable-named partial from a prior
  # run can't be picked up as ours. The .partial.* glob in
  # build_tool_archives still matches because mktemp appends to the
  # template suffix.
  _BASE_TMP=$(mktemp "$_arch.partial.XXXXXXXX")
  _pack_xz "$_BASE_TMP" "$_DIR" node rg micro
  mv -f "$_BASE_TMP" "$_arch"
  rm -rf "$_DIR"
  log I tools.base cached "$(basename "$_arch")"
  printf '%s' "$_arch"
}

_build_tool_tier() {
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    _arch=$(resolve_archive "tool" "$OPT_TOOL_HASH")
    if ! _archive_ok "$_arch"; then
      log E tools.tool fail "pinned archive is corrupt: $(basename "$_arch")"
      exit 1
    fi
    log I tools.tool cache-pin "$(basename "$_arch")"
    printf '%s' "$_arch"; return 0
  fi
  log I tools.tool resolving "latest version"
  fetch_tool_versions
  # arch:$ARCH covers uv (per-arch native binary). pnpm is JS (arch-
  # agnostic) but shares this archive with uv, so $ARCH stays in the seed.
  # Include the shim template since pnpm's `pnpm` entry is a rendered shim.
  _arch="$TOOLS_DIR/tool-$(sha256 "tool-arch:$ARCH-pnpm:$PNPM_VER-uv:$UV_VER-shim:$_shim_tmpl").tar.xz"
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$_arch"; then
    log I tools.tool cache-hit "$(basename "$_arch")"
    printf '%s' "$_arch"; return 0
  fi
  if [ -f "$_arch" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.tool rebuild "cached archive corrupt; rebuilding"
    rm -f "$_arch"
  fi
  log I tools.tool downloading "pnpm $PNPM_VER, uv $UV_VER"
  _DIR=$(mktemp -d)

  (
    # pnpm vanilla npm package: a Node bundle (mjs entries, ~17 MB
    # unpacked) executed against the base-tier node via the same shim
    # template the agent tier uses for node-bundle agents. Verified
    # against npm's sha512 `dist.integrity` — same trust path as the
    # agent tier.
    _file="$_DIR/_pnpm.tgz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$PNPM_TARBALL_URL" -o "$_file"
    _verify_npm_integrity "$_file" "$PNPM_NPM_INTEGRITY" "pnpm npm tarball"
    _extract="$_DIR/_pnpm_extract"
    mkdir -p "$_extract"
    tar -xz -C "$_extract" -f "$_file"
    rm -f "$_file"
    if [ ! -d "$_extract/package" ]; then
      log E tools.tool fail "pnpm npm tarball missing 'package/' dir"
      exit 1
    fi
    # Relocate package/ → pnpm-pkg/ matching the on-disk layout used
    # for node-bundle agents (~/.local/lib/<name>-pkg/) — setup-tools.sh
    # globs `*-pkg` and moves them into LIB_DIR generically. Shim
    # rendering happens after wait_all so the pnpm-pkg/package.json
    # is fully visible to _render_node_bin_shims.
    mv "$_extract/package" "$_DIR/pnpm-pkg"
    rm -rf "$_extract"
  ) &
  _PID1=$!
  (
    # uv now ships from PyPI as a musllinux wheel (a ZIP), verified
    # against PyPI's own sha256 digest — the same trust anchor as pnpm's
    # npm integrity. (Formerly a GitHub release tarball + `.sha256`
    # sidecar.) The wheel lays uv/uvx out under `uv-<ver>.data/scripts/`;
    # relocate the two binaries to the archive root to match the on-disk
    # layout the packer expects.
    _file="$_DIR/_uv.whl"
    curl -fsSL -A "$CRATE_USER_AGENT" "$UV_WHL_URL" -o "$_file"
    _verify_sha256 "$_file" "$UV_PYPI_INTEGRITY" "uv"
    _extract="$_DIR/_uv_extract"
    mkdir -p "$_extract"
    _extract_zip "$_file" "$_extract"
    rm -f "$_file"
    _scripts="$_extract/uv-${UV_VER}.data/scripts"
    if [ ! -d "$_scripts" ]; then
      log E tools.tool fail "uv PyPI wheel missing 'uv-${UV_VER}.data/scripts/' dir"
      exit 1
    fi
    mv "$_scripts/uv" "$_DIR/uv"
    mv "$_scripts/uvx" "$_DIR/uvx"
    rm -rf "$_extract"
  ) &
  _PID2=$!
  wait_all "$_PID1" "$_PID2"

  # Render one shim per package.json `bin` entry. pnpm publishes 4
  # (pn, pnx, pnpm, pnpx — pn/pnpm and pnx/pnpx are aliases for the
  # same JS files); shipping them all keeps user-facing invocation
  # parity with `npm i -g pnpm`. Same template the agent tier renders
  # for node-bundle agents — single source of truth.
  _pnpm_shims=$(_render_node_bin_shims "$_DIR" "$_DIR/pnpm-pkg" pnpm-pkg "" "" tools.tool)

  # The rendered shims (`pnpm`, `pn`, `pnx`, `pnpx`) are sh scripts
  # invoked directly; the mjs entries inside pnpm-pkg/ are read by
  # node and don't need the exec bit. uv/uvx are native binaries.
  chmod +x "$_DIR/uv" "$_DIR/uvx"
  log I tools.tool packing "$(basename "$_arch")"
  _TOOL_TMP=$(mktemp "$_arch.partial.XXXXXXXX")
  # shellcheck disable=SC2086 -- $_pnpm_shims intentionally word-split;
  # _render_node_bin_shims validates names against [A-Za-z0-9._-].
  _pack_xz "$_TOOL_TMP" "$_DIR" $_pnpm_shims pnpm-pkg uv uvx
  mv -f "$_TOOL_TMP" "$_arch"
  rm -rf "$_DIR"
  log I tools.tool cached "$(basename "$_arch")"
  printf '%s' "$_arch"
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
    _arch=$(resolve_archive "$AGENT" "$OPT_AGENT_HASH")
    if ! _archive_ok "$_arch"; then
      log E tools.agent fail "pinned archive is corrupt: $(basename "$_arch")"
      exit 1
    fi
    log I tools.agent cache-pin "$(basename "$_arch")"
    printf '%s' "$_arch"; return 0
  fi
  log I tools.agent resolving "latest version"
  fetch_agent_version
  # Hash seed includes manifest source, the generated agent-manifest.sh,
  # and the wrapper source (all CR-stripped for CRLF/LF parity), so any
  # change to the agent's identity/flags/wrapper busts the tier-3 cache.
  _manifest_src=$(tr -d '\r' < "$AGENT_MANIFEST")
  _manifest_sh=$(_agent_manifest_sh_contents)
  _wrapper_src=$(tr -d '\r' < "$PROJECT_ROOT/bin/agent-wrapper.sh")
  _arch="$TOOLS_DIR/$AGENT-$(sha256 "agent:$AGENT-ver:$AGENT_VER-arch:$ARCH-manifest:$_manifest_src-manifest-sh:$_manifest_sh-wrapper:$_wrapper_src-shim:$_shim_tmpl").tar.xz"
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$_arch"; then
    log I tools.agent cache-hit "$(basename "$_arch")"
    printf '%s' "$_arch"; return 0
  fi
  if [ -f "$_arch" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.agent rebuild "cached archive corrupt; rebuilding"
    rm -f "$_arch"
  fi

  _resolve_exec_source
  # binPath presence is the layout discriminator: present ⇒ a single
  # platform binary at that archive path; absent ⇒ an npm node bundle
  # whose entries come from package.json. (binPath is intrinsic to one and
  # meaningless to the other, so it stands in for an explicit type.)
  _binpath=$(agent_get .executable.binPath)
  if [ -n "$_binpath" ]; then _layout=platform-binary; else _layout=node-bundle; fi
  log I tools.agent downloading "$AGENT $AGENT_VER ($_EXEC_SOURCE/$_layout)"

  # Build the download URL ($_url) and a verification reference
  # ($_verify_ref, checked per $_verify_mode after download). The host and
  # any fixed path infix are launcher-owned constants — the manifest
  # supplies only the validated id ($_EXEC_VALUE) and the templated
  # urlSuffix tail. A URL path can't introduce an authority, so urlSuffix
  # can't change the host (at worst a different path on the same trusted
  # host) — hence no manifest-supplied host to pin.
  _suffix_raw=$(agent_get .executable.urlSuffix)
  case "$_suffix_raw" in
    ''|*[!A-Za-z0-9._/{}-]*|*..*)
      log E tools.agent fail "invalid executable.urlSuffix: '$_suffix_raw' (chars [A-Za-z0-9._/{}-], no '..')"
      exit 1
      ;;
  esac
  _suffix=$(_subst "$_suffix_raw" "$AGENT_VER")
  case "$_EXEC_SOURCE" in
    github)
      # url = github.com/<repo>/releases/download/<tag>/<asset>
      _asset=$_suffix
      _url="https://github.com/$_EXEC_VALUE/releases/download/$AGENT_VER/$_asset"
      # GitHub publishes no checksum sidecar, but the releases API exposes
      # a per-asset `digest` (`sha256:<hex>`) — use it so the "verify
      # before extract" invariant still holds. One api.github.com call per
      # uncached build; cache hits skip it.
      _gh_meta=$(curl -fsSL -A "$CRATE_USER_AGENT" "https://api.github.com/repos/$_EXEC_VALUE/releases/tags/$AGENT_VER")
      _digest=$(printf '%s' "$_gh_meta" | jq -r --arg n "$_asset" '.assets[]? | select(.name == $n) | .digest // empty')
      case "$_digest" in
        sha256:*) _verify_ref=${_digest#sha256:} ;;
        *)
          log E tools.agent fail "no sha256 digest for asset '$_asset' in $_EXEC_VALUE $AGENT_VER release metadata"
          exit 1
          ;;
      esac
      _verify_mode=sha256
      ;;
    npm)
      # url = registry.npmjs.org/<npm><urlSuffix>. <npm> is the version
      # package; the DOWNLOAD package may extend it (claude's per-arch
      # optional-dep `<npm>-linux-<arch>`), so the integrity lookup parses
      # the CONSTRUCTED path on `/-/` for the real download pkg + tarball
      # version — npm's canonical `<scope>/<name>/-/<name>-<version>.tgz`
      # shape. The host is a fixed literal, never parsed from the manifest.
      _path="$_EXEC_VALUE$_suffix"
      _url="https://registry.npmjs.org/$_path"
      case "$_path" in
        */-/*) ;;
        *)
          log E tools.agent fail "npm <npm>+urlSuffix must form a '<pkg>/-/<file>.tgz' path: $_path"
          exit 1
          ;;
      esac
      _pkg=${_path%%/-/*}
      _filename=${_path##*/-/}
      _pkg_base=${_pkg##*/}
      case "$_filename" in
        "${_pkg_base}-"*.tgz)
          _tar_ver=${_filename#${_pkg_base}-}
          _tar_ver=${_tar_ver%.tgz}
          ;;
        *)
          log E tools.agent fail "npm tarball filename does not match '<pkg>-<version>.tgz': $_filename (pkg=$_pkg_base)"
          exit 1
          ;;
      esac
      _meta_url="https://registry.npmjs.org/$_pkg/$_tar_ver"
      _verify_ref=$(curl -fsSL -A "$CRATE_USER_AGENT" "$_meta_url" | jq -r '.dist.integrity // empty')
      if [ -z "$_verify_ref" ]; then
        log E tools.agent fail "no dist.integrity at $_meta_url"
        exit 1
      fi
      _verify_mode=npm
      ;;
  esac

  _DIR=$(mktemp -d)
  _EXTRACT="$_DIR/extract"
  _TARFILE="$_DIR/_agent.tgz"
  mkdir -p "$_EXTRACT"
  curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_TARFILE"
  case "$_verify_mode" in
    sha256) _verify_sha256        "$_TARFILE" "$_verify_ref" "$AGENT github asset" ;;
    npm)    _verify_npm_integrity "$_TARFILE" "$_verify_ref" "$AGENT npm tarball" ;;
  esac
  tar -xz -C "$_EXTRACT" -f "$_TARFILE"
  rm -f "$_TARFILE"

  _binary=$(agent_get .binary)

  if [ -n "$_binpath" ]; then
    # platform-binary: copy the single binary at the (templated) archive
    # path to <binary>-bin.
    _binPath=$(_subst "$_binpath" "$AGENT_VER")
    _src="$_EXTRACT/$_binPath"
    if [ ! -f "$_src" ]; then
      log E tools.agent fail "binary not found in tarball: $_binPath"
      exit 1
    fi
    cp "$_src" "$_DIR/${_binary}-bin"
    chmod +x "$_DIR/${_binary}-bin"
  else
    # node-bundle: relocate extract/package → <binary>-pkg/ for a stable
    # on-disk path (~/.local/lib/<binary>-pkg/) inside the sandbox, then
    # render one shim per package.json `bin` entry. The canonical entry
    # (key matching .binary) goes to ${_binary}-bin so agent-wrapper.sh
    # finds it; auxiliary entries become standalone shims under their bin
    # keys. _agent_shims is the full space-joined list of rendered
    # filenames (canonical + aux), word-split into pack inputs below.
    _pkg="${_binary}-pkg"
    if [ -d "$_EXTRACT/package" ]; then
      mv "$_EXTRACT/package" "$_DIR/$_pkg"
    else
      log E tools.agent fail "node bundle has no 'package/' dir"
      exit 1
    fi
    _agent_shims=$(_render_node_bin_shims "$_DIR" "$_DIR/$_pkg" "$_pkg" \
      "$_binary" "${_binary}-bin" tools.agent)
  fi

  # Ship the wrapper under the agent's command name (regular file, not
  # a symlink) — keeps behavior identical across Linux/WSL/Windows
  # host filesystems where symlink creation quirks would otherwise
  # require an OS-specific fallback. Strip CR so Windows checkouts
  # (git autocrlf) pack a Linux-compatible #!/usr/bin/env sh shebang.
  tr -d '\r' < "$PROJECT_ROOT/bin/agent-wrapper.sh" > "$_DIR/$_binary"
  _agent_manifest_sh_contents > "$_DIR/agent-manifest.sh"
  chmod +x "$_DIR/$_binary"

  rm -rf "$_EXTRACT"

  log I tools.agent packing "$(basename "$_arch")"
  _AGENT_TMP=$(mktemp "$_arch.partial.XXXXXXXX")
  if [ -n "$_binpath" ]; then
    _pack_xz "$_AGENT_TMP" "$_DIR" "$_binary" agent-manifest.sh "${_binary}-bin"
  else
    # shellcheck disable=SC2086 -- $_agent_shims intentionally word-split;
    # _render_node_bin_shims validates names against [A-Za-z0-9._-].
    _pack_xz "$_AGENT_TMP" "$_DIR" "$_binary" agent-manifest.sh $_agent_shims "${_binary}-pkg"
  fi
  mv -f "$_AGENT_TMP" "$_arch"
  rm -rf "$_DIR"
  log I tools.agent cached "$(basename "$_arch")"
  printf '%s' "$_arch"
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

  # Shim template bytes — both the tool tier (pnpm) and node-bundle agents
  # render this template, so it feeds both their hashes. Read once here
  # (CR-stripped for CRLF/LF hash parity) and inherited read-only by the
  # tier subshells below, rather than each re-reading the file.
  _shim_tmpl=$(tr -d '\r' < "$PROJECT_ROOT/bin/node-shim.sh.tmpl")

  # The three tiers are fully independent end-to-end (own version probes,
  # own hash, own cache-check, own build), so run each as a concurrent
  # pipeline — no version-resolution barrier, and a slow/cached tier never
  # blocks the others. Each tier prints ONLY its resolved archive path on
  # stdout (progress logs go to stderr); we capture the three via temp
  # files since the launcher consumes the paths after this returns. The
  # ps1 side mirrors this with three Start-ThreadJob runspaces.
  _PD=$(mktemp -d)
  ( _build_base_tier  > "$_PD/base"  ) & _BPID=$!
  ( _build_tool_tier  > "$_PD/tool"  ) & _TPID=$!
  ( _build_agent_tier > "$_PD/agent" ) & _APID=$!
  wait_all "$_BPID" "$_TPID" "$_APID"
  BASE_ARCHIVE=$(cat "$_PD/base")
  TOOL_ARCHIVE=$(cat "$_PD/tool")
  AGENT_ARCHIVE=$(cat "$_PD/agent")
  rm -rf "$_PD"
  if [ -z "$BASE_ARCHIVE" ] || [ -z "$TOOL_ARCHIVE" ] || [ -z "$AGENT_ARCHIVE" ]; then
    log E tools fail "a tier pipeline did not report its archive path"
    exit 1
  fi
}
