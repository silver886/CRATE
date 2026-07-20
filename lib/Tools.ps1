# Tools.ps1 — tool archive build system (multi-agent).
# Dot-sourced (not executed). Requires: $projectRoot, $agent,
# $agentManifest (from Agent.ps1).
#
# Top-level surface (kept minimal — only what crosses into the launcher
# scope): $cacheDir, $detectArch, $buildToolArchives. Every helper, the
# HttpClient, JSON parsing scratch, sha256/SRI helpers, and the tier
# builder live INSIDE $buildToolArchives so dot-sourcing this file
# doesn't pollute the launcher with build-time machinery.

# $cacheDir is read by Init-Launcher's preflight before $detectArch /
# $buildToolArchives are invoked, so it must stay at script scope.
$cacheDir = if ($env:XDG_CACHE_HOME) { "$env:XDG_CACHE_HOME\crate" } else { "$HOME\.cache\crate" }

# Distinct values grouped by the arch-suffix convention each tool uses.
# Only genuine primitives are case-branched; everything else is derived:
#   $arch        — Node.js / pnpm suffix / npm platform sub-pkg {arch}
#                    (x64 on X64, arm64 on Arm64)
#   $archGnu     — prefix of Rust-style triples
#                    (x86_64 on X64, aarch64 on Arm64)
#   $archMicro   — micro's release-asset suffix — unrelated schemes
#                    (linux64-static on X64, linux-arm64 on Arm64)
#   $archRg      — ripgrep's triple — musl on X64, gnu on Arm64
#                    (BurntSushi/ripgrep doesn't ship musl arm64)
#   $archTriple  — full musl triple, used by Codex {triple}
$detectArch = {
  $osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  switch ($osArch) {
    'X64' {
      $script:arch = 'x64'
      $script:archGnu = 'x86_64'
      $script:archMicro = 'linux64-static'
      $rgLibc = 'musl'
    }
    'Arm64' {
      $script:arch = 'arm64'
      $script:archGnu = 'aarch64'
      $script:archMicro = 'linux-arm64'
      $rgLibc = 'gnu'
    }
    default {
      Write-Log E tools fail "unsupported architecture: $osArch"
      throw "unsupported architecture: $osArch"
    }
  }
  $script:archTriple = "$($script:archGnu)-unknown-linux-musl"
  $script:archRg = "$($script:archGnu)-unknown-linux-$rgLibc"
}

$buildToolArchives = {
  $toolsDir = "$cacheDir\tools"

  # Determine the executable source from which of .executable.npm /
  # .executable.github is set (exactly one), validate that value (it flows
  # into a download URL), and publish $script:execSource (npm|github) +
  # $script:execValue (the npm package, or the github 'owner/name'). The
  # value doubles as the version handle and the URL id-prefix. Mirror of
  # _resolve_exec_source in lib/tools.sh.
  $resolveExecSource = {
    $npmId = Get-AgentField '.executable.npm'
    $githubId = Get-AgentField '.executable.github'
    if ($npmId -and $githubId) {
      Write-Log E "tools.$agent" fail "executable sets both .npm and .github; set exactly one"
      throw "executable sets both .npm and .github"
    }
    elseif ($npmId) {
      if ($npmId -notmatch '^[A-Za-z0-9._@/-]+$' -or $npmId -match '\.\.' -or $npmId.StartsWith('/') -or $npmId.EndsWith('/')) {
        Write-Log E "tools.$agent" fail "invalid executable.npm package: '$npmId' (chars [A-Za-z0-9._@/-], no '..')"
        throw "invalid executable.npm: $npmId"
      }
      $script:execSource = 'npm'; $script:execValue = $npmId
    }
    elseif ($githubId) {
      if ($githubId -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -or $githubId -match '\.\.') {
        Write-Log E "tools.$agent" fail "invalid executable.github repo: '$githubId' (must be 'owner/name', chars [A-Za-z0-9._-])"
        throw "invalid executable.github: $githubId"
      }
      $script:execSource = 'github'; $script:execValue = $githubId
    }
    else {
      Write-Log E "tools.$agent" fail "executable sets neither .npm nor .github; set exactly one"
      throw "executable sets neither .npm nor .github"
    }
  }

  # POSIX shell-quote a value: wrap in single quotes with each embedded
  # `'` rewritten as `'\''`. Output round-trips through `. file` for any
  # byte sequence — including newlines and quotes — so a manifest value
  # can no longer corrupt the agent-manifest.sh sourced by the wrapper.
  # Must produce byte-identical output to lib/tools.sh's _sh_quote so the
  # generated file is the same regardless of which side built the cache.
  $shQuote = { param([string]$s)
    "'" + $s.Replace("'", "'\''") + "'"
  }

  # Build agent-manifest.sh contents from manifest fields. Mirrors
  # _agent_manifest_sh_contents in lib/tools.sh — exact same output so
  # tier-3 hashes match across sh/ps1 sides.
  $agentManifestShContents = {
    $sb = [Text.StringBuilder]::new(256)
    [void]$sb.Append("AGENT_BINARY=$(& $shQuote $script:agentBinary)`n")
    # Emit launch.flags as a function body so each flag preserves its
    # argument boundary across the manifest → wrapper boundary. A flat
    # space-joined string would lose boundaries on any flag value
    # containing whitespace, an empty string, or shell metacharacters.
    $flags = Get-AgentList '.launch.flags'
    [void]$sb.Append("exec_agent_with_flags() {`n  _eaf_bin=`$1`n  shift`n  exec `"`$_eaf_bin`"")
    foreach ($flag in $flags) {
      [void]$sb.Append(' ')
      [void]$sb.Append((& $shQuote $flag))
    }
    [void]$sb.Append(" `"`$@`"`n}`n")
    # Point the agent's config-dir env var at the system staging path.
    # Skipped for agents whose manifest.configDir.env is empty (Gemini).
    # $crateEnv is shell-name-validated in Invoke-AgentLoad.
    if ($script:crateEnv) {
      [void]$sb.Append("export $($script:crateEnv)=$(& $shQuote $script:crateDir)`n")
    }
    $envKv = Get-AgentKv '.launch.env'
    foreach ($k in $envKv.Keys) {
      if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Write-Log E launcher fail "invalid launch.env key in $($script:agentManifestPath): '$k' (must match [A-Za-z_][A-Za-z0-9_]*)"
        throw "invalid launch.env key: $k"
      }
      [void]$sb.Append("export $k=$(& $shQuote $envKv[$k])`n")
    }
    $sb.ToString()
  }

  # ── Tier builder ──
  #
  # Shared script block that runs inside each Start-ThreadJob runspace.
  # Thread-job runspaces don't inherit the parent's script scope, so
  # everything is passed as explicit params. For the agent tier, the
  # caller passes prebuilt inputs (tarball URL, bin/entry path, manifest
  # shell-script contents, wrapper source) instead of parsing the manifest
  # inside the job. HttpClient is intentionally NOT passed in — the
  # worker creates and disposes its own so the resource never crosses
  # the call boundary.
  $tierBuilder = {
    param($logLevel, $projectRoot, $tier, $toolsDir, $pathOut, $optHash, $forcePull, $vars)
    # ThreadJob runspaces don't inherit the parent's preference variables,
    # so .NET method exceptions would default to non-terminating. Force
    # 'Stop' here so any failure escapes the job instead of being swallowed.
    $ErrorActionPreference = 'Stop'
    $script:LogLevel = $logLevel
    . "$projectRoot\lib\Log.ps1"
    # Stage from $vars.kind (base|tool|agent), not $tier: the agent tier's
    # $tier is the agent name (up to 15 chars) which would overflow the
    # log's 16-char STAGE column — `tools.agent` keeps it bounded and
    # parallel to `tools.base`/`tools.tool`. $tier still names the archive
    # prefix for the pin lookup below.
    $stage = "tools.$($vars.kind)"

    # $ErrorActionPreference does NOT cover native command exit codes —
    # `tar` and friends keep going on non-zero. Wrap them so a failed
    # extract/pack throws instead of producing a silently-bad archive.
    # Slice safely: $args[1..0] would reverse-range when only the cmd is
    # passed, so guard with the count.
    $mustNative = {
      $cmd = $args[0]
      $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
      & $cmd @rest
      if ($LASTEXITCODE -ne 0) {
        throw "$stage`: $cmd failed (exit $LASTEXITCODE): $($args -join ' ')"
      }
    }

    $archiveOk = { param($p)
      if (-not [IO.File]::Exists($p)) { return $false }
      if ([IO.FileInfo]::new($p).Length -eq 0) { return $false }
      & tar -tf $p *> $null
      return ($LASTEXITCODE -eq 0)
    }

    # Verify downloaded bytes match an expected sha256 hex digest. Throws
    # before extraction so a hostile tarball can't drop binaries that the
    # build then chmod +x'es. Mirrors lib/tools.sh:_verify_sha256.
    $verifySha256 = { param($bytes, $expected, $label)
      if (-not $expected) {
        Write-Log E "$stage.verify" fail "$label`: empty expected sha256"
        throw "$stage.verify: $label empty expected sha256"
      }
      $actual = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').ToLower()
      $exp = $expected.ToLower()
      if ($actual -ne $exp) {
        Write-Log E "$stage.verify" fail "$label sha256 mismatch (expected $exp, got $actual)"
        throw "$stage.verify: $label sha256 mismatch"
      }
    }

    # Verify downloaded bytes against an npm dist.integrity SRI value
    # (`sha512-<base64>`). Mirrors lib/tools.sh:_verify_npm_integrity.
    $verifyNpmIntegrity = { param($bytes, $integrity, $label)
      if (-not $integrity -or -not $integrity.StartsWith('sha512-')) {
        Write-Log E "$stage.verify" fail "$label`: unsupported integrity algorithm: $integrity"
        throw "$stage.verify: $label unsupported integrity algorithm"
      }
      $expBytes = [Convert]::FromBase64String($integrity.Substring(7))
      $actBytes = [Security.Cryptography.SHA512]::HashData($bytes)
      $eq = ($expBytes.Length -eq $actBytes.Length)
      if ($eq) {
        for ($i = 0; $i -lt $expBytes.Length; $i++) {
          if ($expBytes[$i] -ne $actBytes[$i]) { $eq = $false; break }
        }
      }
      if (-not $eq) {
        $expHex = [BitConverter]::ToString($expBytes).Replace('-', '').ToLower()
        $actHex = [BitConverter]::ToString($actBytes).Replace('-', '').ToLower()
        Write-Log E "$stage.verify" fail "$label sha512 mismatch (expected $expHex, got $actHex)"
        throw "$stage.verify: $label sha512 mismatch"
      }
    }

    # Sidecar checksum files are typically '<hex>  <filename>' (two spaces)
    # or just '<hex>'. Take the first whitespace-delimited token.
    $firstShaToken = { param($shaText)
      if (-not $shaText) { return $null }
      ($shaText.Trim() -split '\s+', 2)[0]
    }

    # Node ships one SHASUMS256.txt covering every platform tarball; pick
    # the row matching our exact filename.
    $nodeShaForName = { param($shaText, $tarballName)
      foreach ($line in ($shaText -split "`n")) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        $parts = $t -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $tarballName) { return $parts[0] }
      }
      return $null
    }

    # Render shims from the node-shim template for every entry in
    # $pkgDir/package.json's `.bin` map. Validates bin names, writes
    # one shim per entry into $outDir, and returns a string array of
    # rendered filenames the caller word-uses as pack inputs.
    #
    # $canonIn / $canonOut route the shim for the bin entry whose
    # name equals $canonIn to filename $canonOut instead of using the
    # bin key. Agent tier passes ($binary, "$binary-bin") so
    # agent-wrapper.sh finds its entry; tool tier passes ('','').
    # Mirrors lib/tools.sh:_render_node_bin_shims — same validation
    # rules, same output shape.
    $renderNodeBinShims = { param($outDir, $pkgDir, $pkgName, $shimTmpl, $canonIn, $canonOut)
      $pkgJsonPath = [IO.Path]::Combine($pkgDir, 'package.json')
      if (-not [IO.File]::Exists($pkgJsonPath)) {
        Write-Log E $stage fail "package.json missing at $pkgJsonPath"
        throw "$stage`: package.json missing"
      }
      $files = [Collections.Generic.List[string]]::new()
      $sawCanon = $false
      $pkgJson = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($pkgJsonPath))
      try {
        # Locate `.bin` via EnumerateObject rather than TryGetProperty:
        # JsonElement.TryGetProperty has three overloads (string,
        # ReadOnlySpan<byte>, ReadOnlySpan<char>) and PowerShell's
        # method binder can't disambiguate when the `out` parameter is
        # passed as `[ref]$x` against an untyped/null variable —
        # surfaces as "Cannot find an overload for TryGetProperty and
        # the argument count: 2" at runtime.
        $binEl = $pkgJson.RootElement
        $hasBin = $false
        foreach ($prop in $pkgJson.RootElement.EnumerateObject()) {
          if ($prop.Name -eq 'bin') { $binEl = $prop.Value; $hasBin = $true; break }
        }
        if (-not $hasBin -or $binEl.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
          Write-Log E $stage fail "$pkgJsonPath`: .bin must be an object"
          throw "$stage`: .bin not an object"
        }
        foreach ($p in $binEl.EnumerateObject()) {
          $binName = $p.Name
          $binPath = $p.Value.GetString()
          # Validate bin key: rejects path separators, shell metas,
          # leading hyphen (would look like a flag), leading dot (no '..').
          if ($binName -notmatch '^[A-Za-z0-9_][A-Za-z0-9._-]*$') {
            Write-Log E $stage fail "invalid bin name in $pkgJsonPath`: '$binName'"
            throw "$stage`: invalid bin name '$binName'"
          }
          $entry = $binPath -replace '^\./', ''
          # Validate bin path: must be relative, no traversal, safe
          # segments. Interpolated into the shim's `exec node
          # "$HOME/.local/lib/PKG/{{ENTRY}}"` template — a quote,
          # backslash, control char, or '..' would either break the
          # double-quoted shell literal or escape the package dir.
          # Mirrors the lib/tools.sh validator.
          if (-not $entry -or $entry.StartsWith('/') -or $entry.Contains('\')) {
            Write-Log E $stage fail "invalid bin path in $pkgJsonPath`: '$binPath' (must be a non-empty relative path with no backslashes)"
            throw "$stage`: invalid bin path '$binPath'"
          }
          foreach ($seg in $entry.Split('/')) {
            if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..' -or
              $seg -notmatch '^[A-Za-z0-9._-]+$') {
              Write-Log E $stage fail "invalid bin path segment in $pkgJsonPath`: '$binPath' (segment '$seg' must match [A-Za-z0-9._-]+ and not be '.' or '..')"
              throw "$stage`: invalid bin path segment"
            }
          }
          if ($canonIn -and $binName -eq $canonIn) {
            $target = $canonOut
            $sawCanon = $true
          }
          else {
            $target = $binName
            # Reject aux-shim collisions with reserved agent-tier
            # filenames. Tool tier (no $canonIn) skips this naturally.
            if ($canonIn) {
              if ($target -eq 'agent-manifest.sh' -or
                $target -eq $canonIn -or
                $target -eq $canonOut -or
                $target -eq "$canonIn-pkg") {
                Write-Log E $stage fail "aux bin '$binName' collides with reserved filename '$target'"
                throw "$stage`: aux bin '$binName' collides with reserved filename"
              }
            }
          }
          $shim = $shimTmpl.Replace('{{PKG}}', $pkgName).Replace('{{ENTRY}}', $entry)
          [IO.File]::WriteAllText([IO.Path]::Combine($outDir, $target), $shim)
          [void]$files.Add($target)
        }
      }
      finally { $pkgJson.Dispose() }
      if ($files.Count -eq 0) {
        Write-Log E $stage fail "$pkgJsonPath`: no .bin entries rendered"
        throw "$stage`: no .bin entries rendered"
      }
      if ($canonIn -and -not $sawCanon) {
        Write-Log E $stage fail "canonical bin '$canonIn' not found in $pkgJsonPath"
        throw "$stage`: canonical bin '$canonIn' not found"
      }
      # Return as a fixed array — `,` prefix prevents PowerShell from
      # unwrapping a single-element list into a scalar.
      , $files.ToArray()
    }

    # sha256 of a string → lowercase hex. The job runspace doesn't inherit
    # the parent's $sha256, so define a local one for the tier hash seeds.
    $sha256 = {
      [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
      ).Replace('-', '').ToLower()
    }
    # Substitute {arch}/{triple}/{version} in a template (agent urlSuffix /
    # binPath). $vars carries arch/archTriple; $version is the resolved tag.
    $subst = { param($t, $version)
      $t.Replace('{arch}', $vars.arch).Replace('{triple}', $vars.archTriple).Replace('{version}', $version)
    }

    # Each tier is a self-contained pipeline (resolve own version → hash →
    # cache-check → build → pack) and writes its resolved archive path to
    # $pathOut for the parent — mirroring lib/tools.sh's per-tier subshells.
    # Pinned: resolve by hash prefix, verify, done.
    if ($optHash) {
      $cand = if ([IO.Directory]::Exists($toolsDir)) { [IO.Directory]::GetFiles($toolsDir, "$tier-$optHash*.tar.xz") } else { @() }
      if (-not $cand -or $cand.Length -eq 0) {
        Write-Log E $stage fail "no cached archive matching hash '$optHash'"
        throw "no cached $tier archive matching hash '$optHash'"
      }
      if ($cand.Length -gt 1) {
        Write-Log E $stage fail "ambiguous hash prefix '$optHash' matches multiple archives"
        throw "ambiguous $tier hash prefix '$optHash'"
      }
      $archive = $cand[0]
      if (-not (& $archiveOk $archive)) {
        Write-Log E $stage fail "pinned archive is corrupt: $([IO.Path]::GetFileName($archive))"
        throw "pinned $tier archive is corrupt"
      }
      Write-Log I $stage cache-pin ([IO.Path]::GetFileName($archive))
      [IO.File]::WriteAllText($pathOut, $archive)
      return
    }

    # Per-thread HttpClient — owned and disposed inside this runspace,
    # never received from the parent. UA value travels via $vars
    # because thread runspaces don't inherit parent script scope, so
    # $crateUserAgent (lib/Common.ps1) isn't visible here directly.
    $http = [Net.Http.HttpClient]::new()
    $http.DefaultRequestHeaders.UserAgent.ParseAdd($vars.userAgent)
    $tmpDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "agent-build-$([Guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tmpDir) > $null
    try {
      $archive = $null
      $packInputs = $null
      switch ($vars.kind) {
        'base' {
          Write-Log I $stage resolving 'latest version'
          # Resolve node (LTS) / ripgrep (crates max_stable) / micro
          # (releases/latest redirect) versions in parallel, then hash.
          $nodeVerT = $http.GetStringAsync('https://nodejs.org/dist/index.json')
          $rgVerT = $http.GetStringAsync('https://crates.io/api/v1/crates/ripgrep')
          $microVerReq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head, 'https://github.com/micro-editor/micro/releases/latest')
          $microVerT = $http.SendAsync($microVerReq)
          [Threading.Tasks.Task]::WaitAll($nodeVerT, $rgVerT, $microVerT)
          $nodeIdx = [Text.Json.JsonDocument]::Parse($nodeVerT.Result)
          $nodeVer = $null
          foreach ($el in $nodeIdx.RootElement.EnumerateArray()) {
            if ($el.GetProperty('lts').ValueKind -ne [Text.Json.JsonValueKind]::False) {
              $nodeVer = $el.GetProperty('version').GetString().TrimStart('v'); break
            }
          }
          $nodeIdx.Dispose()
          $rgDoc = [Text.Json.JsonDocument]::Parse($rgVerT.Result)
          $rgVer = $rgDoc.RootElement.GetProperty('crate').GetProperty('max_stable_version').GetString()
          $rgDoc.Dispose()
          $microFinal = $microVerT.Result.RequestMessage.RequestUri.ToString()
          $microVerT.Result.Dispose()
          $microVer = $microFinal.Substring($microFinal.LastIndexOf('/') + 1).TrimStart('v')
          # micro guard — same as fetch_base_versions in lib/tools.sh: a
          # failed/un-redirected releases/latest yields the literal tail.
          if (-not $microVer -or $microVer -eq 'releases' -or $microVer -eq 'latest') {
            Write-Log E $stage fail "failed to resolve a micro release tag (got '$microVer')"
            throw "failed to resolve micro release tag"
          }
          if (-not $nodeVer -or -not $rgVer) {
            Write-Log E $stage fail "failed to fetch node/ripgrep version"
            throw "failed to fetch node/ripgrep version"
          }
          # arch:$arch in the seed because the packed binaries are
          # architecture-specific — an x64/arm64 host sharing $toolsDir
          # would otherwise collide on the same base-*.tar.xz filename.
          $archive = "$toolsDir\base-$(& $sha256 "base-arch:$($vars.arch)-node:$nodeVer-rg:$rgVer-micro:$microVer").tar.xz"
          if ((-not $forcePull) -and (& $archiveOk $archive)) {
            Write-Log I $stage cache-hit ([IO.Path]::GetFileName($archive)); [IO.File]::WriteAllText($pathOut, $archive); return
          }
          if ([IO.File]::Exists($archive) -and -not $forcePull) {
            Write-Log W $stage rebuild "cached archive corrupt; rebuilding"; [IO.File]::Delete($archive)
          }
          Write-Log I $stage downloading "node $nodeVer, ripgrep $rgVer, micro $microVer"
          $nodeTarballName = "node-v$nodeVer-linux-$($vars.arch).tar.xz"
          $nodeUrl = "https://nodejs.org/dist/v$nodeVer/$nodeTarballName"
          $nodeShaUrl = "https://nodejs.org/dist/v$nodeVer/SHASUMS256.txt"
          $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/$rgVer/ripgrep-$rgVer-$($vars.archRg).tar.gz"
          $microUrl = "https://github.com/micro-editor/micro/releases/download/v$microVer/micro-$microVer-$($vars.archMicro).tar.gz"
          # Fetch artifacts and publisher checksums in parallel. micro
          # uses '.sha' (not '.sha256') as its sidecar suffix.
          $nodeTask = $http.GetByteArrayAsync($nodeUrl)
          $rgTask = $http.GetByteArrayAsync($rgUrl)
          $microTask = $http.GetByteArrayAsync($microUrl)
          $nodeShaTask = $http.GetStringAsync($nodeShaUrl)
          $rgShaTask = $http.GetStringAsync("$rgUrl.sha256")
          $microShaTask = $http.GetStringAsync("$microUrl.sha")
          [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask, $nodeShaTask, $rgShaTask, $microShaTask)

          $nodeExp = & $nodeShaForName $nodeShaTask.Result $nodeTarballName
          $rgExp = & $firstShaToken $rgShaTask.Result
          $microExp = & $firstShaToken $microShaTask.Result
          & $verifySha256 $nodeTask.Result $nodeExp "node $nodeTarballName"
          & $verifySha256 $rgTask.Result $rgExp 'ripgrep'
          & $verifySha256 $microTask.Result $microExp 'micro'

          $nodeTmp = "$tmpDir\_node.tar.xz"; [IO.File]::WriteAllBytes($nodeTmp, $nodeTask.Result)
          & $mustNative tar -xJf $nodeTmp -C $tmpDir --strip-components=2 "node-v$nodeVer-linux-$($vars.arch)/bin/node"
          [IO.File]::Delete($nodeTmp)

          $rgTmp = "$tmpDir\_rg.tar.gz"; [IO.File]::WriteAllBytes($rgTmp, $rgTask.Result)
          & $mustNative tar -xzf $rgTmp -C $tmpDir --strip-components=1 "ripgrep-$rgVer-$($vars.archRg)/rg"
          [IO.File]::Delete($rgTmp)

          $microTmp = "$tmpDir\_micro.tar.gz"; [IO.File]::WriteAllBytes($microTmp, $microTask.Result)
          & $mustNative tar -xzf $microTmp -C $tmpDir --strip-components=1 "micro-$microVer/micro"
          [IO.File]::Delete($microTmp)

          $packInputs = @('node', 'rg', 'micro')
        }
        'tool' {
          Write-Log I $stage resolving 'latest version'
          # Resolve pnpm (full `latest` metadata → version + tarball URL +
          # sha512 SRI in one fetch) and uv (pypi version) in parallel,
          # then hash. Mirrors fetch_tool_versions in lib/tools.sh.
          $pnpmMetaT = $http.GetStringAsync('https://registry.npmjs.org/pnpm/latest')
          $uvVerT = $http.GetStringAsync('https://pypi.org/pypi/uv/json')
          [Threading.Tasks.Task]::WaitAll($pnpmMetaT, $uvVerT)
          $pnpmDoc = [Text.Json.JsonDocument]::Parse($pnpmMetaT.Result)
          $pnpmVer = $pnpmDoc.RootElement.GetProperty('version').GetString()
          $pnpmDist = $pnpmDoc.RootElement.GetProperty('dist')
          $pnpmTarballUrl = $pnpmDist.GetProperty('tarball').GetString()
          $pnpmNpmIntegrity = $pnpmDist.GetProperty('integrity').GetString()
          $pnpmDoc.Dispose()
          $uvDoc = [Text.Json.JsonDocument]::Parse($uvVerT.Result)
          $uvVer = $uvDoc.RootElement.GetProperty('info').GetProperty('version').GetString()
          $uvUrl = foreach ($a in $uvDoc.RootElement.GetProperty('urls').EnumerateArray()) {
            $s = $a.GetProperty('filename').GetString()
            $i = $s.IndexOf('musllinux', [StringComparison]::Ordinal)
            if ($i -ge 0 -and $s.IndexOf($vars.archGnu, $i + 9, [StringComparison]::Ordinal) -ge 0) {
              $a
              break
            }
          }
          $uvWhlUrl = $uvUrl.GetProperty('url').GetString()
          $uvPypiIntegrity = $uvUrl.GetProperty('digests').GetProperty('sha256').GetString()
          $uvDoc.Dispose()
          if (-not $pnpmVer -or -not $uvVer) {
            Write-Log E $stage fail "failed to fetch pnpm/uv version"; throw "failed to fetch pnpm/uv version"
          }
          if (-not $pnpmTarballUrl -or -not $pnpmNpmIntegrity) {
            Write-Log E $stage fail "pnpm $pnpmVer`: missing dist.tarball / dist.integrity"; throw "pnpm npm metadata missing dist fields"
          }
          if (-not $pnpmTarballUrl.StartsWith('https://registry.npmjs.org/')) {
            Write-Log E $stage fail "pnpm tarball URL not on registry.npmjs.org: $pnpmTarballUrl"; throw "pnpm tarball URL not on npm registry"
          }
          if (-not $uvWhlUrl -or -not $uvPypiIntegrity) {
            Write-Log E $stage fail "uv $uvVer`: missing urls.url / urls.digests.sha256 where urls.filename matches 'musllinux*$($vars.archGnu)'"; throw "uv PyPI metadata missing urls fields"
          }
          if (-not $uvWhlUrl.StartsWith('https://files.pythonhosted.org/')) {
            Write-Log E $stage fail "uv wheel URL not on files.pythonhosted.org: $uvWhlUrl"; throw "uv wheel URL not on PyPI registry"
          }
          $archive = "$toolsDir\tool-$(& $sha256 "tool-arch:$($vars.arch)-pnpm:$pnpmVer-uv:$uvVer-shim:$($vars.shimTmpl)").tar.xz"
          if ((-not $forcePull) -and (& $archiveOk $archive)) {
            Write-Log I $stage cache-hit ([IO.Path]::GetFileName($archive)); [IO.File]::WriteAllText($pathOut, $archive); return
          }
          if ([IO.File]::Exists($archive) -and -not $forcePull) {
            Write-Log W $stage rebuild "cached archive corrupt; rebuilding"; [IO.File]::Delete($archive)
          }
          Write-Log I $stage downloading "pnpm $pnpmVer, uv $uvVer"
          # pnpm vanilla npm package: a Node bundle (mjs entry, ~17 MB
          # unpacked) executed against the base-tier node via the same
          # shim template the agent tier uses for node-bundle agents.
          # Verified against npm's sha512 `dist.integrity` — same
          # trust path as the agent tier.
          $pnpmTask = $http.GetByteArrayAsync($pnpmTarballUrl)
          $uvTask = $http.GetByteArrayAsync($uvWhlUrl)
          [Threading.Tasks.Task]::WaitAll($pnpmTask, $uvTask)

          & $verifyNpmIntegrity $pnpmTask.Result $pnpmNpmIntegrity 'pnpm npm tarball'
          $uvExp = & $firstShaToken $uvPypiIntegrity
          & $verifySha256 $uvTask.Result $uvExp 'uv'

          $pnpmTmp = "$tmpDir\_pnpm.tgz"; [IO.File]::WriteAllBytes($pnpmTmp, $pnpmTask.Result)
          $pnpmExtract = "$tmpDir\_pnpm_extract"
          [IO.Directory]::CreateDirectory($pnpmExtract) > $null
          & $mustNative tar -xzf $pnpmTmp -C $pnpmExtract
          [IO.File]::Delete($pnpmTmp)
          $pnpmPkgSrc = "$pnpmExtract\package"
          if (-not [IO.Directory]::Exists($pnpmPkgSrc)) {
            Write-Log E $stage fail "pnpm npm tarball missing 'package/' dir"
            throw "pnpm npm tarball missing 'package/' dir"
          }
          # Relocate package/ → pnpm-pkg/ matching the on-disk layout
          # used for node-bundle agents (~/.local/lib/<name>-pkg/) —
          # setup-tools.sh globs `*-pkg` and moves them into LIB_DIR
          # generically.
          [IO.Directory]::Move($pnpmPkgSrc, "$tmpDir\pnpm-pkg")
          [IO.Directory]::Delete($pnpmExtract, $true)
          # Render one shim per package.json `bin` entry. pnpm publishes
          # 4 (pn, pnx, pnpm, pnpx — pn/pnpm and pnx/pnpx are aliases for
          # the same JS files); shipping them all keeps user-facing
          # invocation parity with `npm i -g pnpm`. No canonical mapping
          # in the tool tier — there's no wrapper layer.
          $pnpmShims = & $renderNodeBinShims $tmpDir "$tmpDir\pnpm-pkg" 'pnpm-pkg' $vars.shimTmpl '' ''

          $uvTmp = "$tmpDir\_uv.tar.gz"; [IO.File]::WriteAllBytes($uvTmp, $uvTask.Result)
          $uvExtract = "$tmpDir\_uv_extract"
          [IO.Directory]::CreateDirectory($uvExtract) > $null
          & $mustNative tar -xzf $uvTmp -C $uvExtract
          [IO.File]::Delete($uvTmp)
          $uvPkgSrc = "$uvExtract\uv-$uvVer.data\scripts"
          if (-not [IO.Directory]::Exists($uvPkgSrc)) {
            Write-Log E $stage fail "uv PyPI wheel missing 'uv-$uvVer.data/scripts/' dir"
            throw "uv PyPI wheel missing 'uv-$uvVer.data/scripts/' dir"
          }
          # Relocate uv-$uvVer.data/scripts/ → / matching the on-disk layout
          [IO.File]::Move("$uvPkgSrc\uv", "$tmpDir\uv")
          [IO.File]::Move("$uvPkgSrc\uvx", "$tmpDir\uvx")
          [IO.Directory]::Delete($uvExtract, $true)
          $packInputs = @($pnpmShims) + @('pnpm-pkg', 'uv', 'uvx')
        }
        'agent' {
          Write-Log I $stage resolving 'latest version'
          # Resolve the agent version, then (per source) the download URL +
          # a verification reference, then hash → archive path → cache-check.
          # Mirrors fetch_agent_version + _build_agent_tier in lib/tools.sh.
          # The manifest is parsed parent-side (Agent.ps1 isn't loaded in
          # this runspace); $vars carries the raw id/templates and the
          # CR-stripped manifest/wrapper sources for the hash.
          if ($vars.execSource -eq 'github') {
            $verReq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head, "https://github.com/$($vars.execValue)/releases/latest")
            $verRes = $http.SendAsync($verReq).Result
            $verFinal = $verRes.RequestMessage.RequestUri.ToString(); $verRes.Dispose()
            $agentVer = $verFinal.Substring($verFinal.LastIndexOf('/') + 1)
            if (-not $agentVer -or $agentVer -eq 'releases' -or $agentVer -eq 'latest') {
              Write-Log E $stage fail "failed to resolve a release tag for $($vars.execValue) (got '$agentVer')"
              throw "failed to resolve release tag"
            }
          }
          else {
            $verDoc = [Text.Json.JsonDocument]::Parse($http.GetStringAsync("https://registry.npmjs.org/$($vars.execValue)/latest").Result)
            $agentVer = $verDoc.RootElement.GetProperty('version').GetString(); $verDoc.Dispose()
            if (-not $agentVer) { Write-Log E $stage fail "failed to fetch version for $($vars.execValue)"; throw "failed to fetch agent version" }
          }
          $suffix = & $subst $vars.urlSuffix $agentVer
          $binPath = if ($vars.binPath) { & $subst $vars.binPath $agentVer } else { $null }
          if ($vars.execSource -eq 'github') {
            $url = "https://github.com/$($vars.execValue)/releases/download/$agentVer/$suffix"
            $apiDoc = [Text.Json.JsonDocument]::Parse($http.GetStringAsync("https://api.github.com/repos/$($vars.execValue)/releases/tags/$agentVer").Result)
            try {
              $digest = $null
              foreach ($a in $apiDoc.RootElement.GetProperty('assets').EnumerateArray()) {
                if ($a.GetProperty('name').GetString() -eq $suffix) { $digest = $a.GetProperty('digest').GetString(); break }
              }
            }
            finally { $apiDoc.Dispose() }
            if (-not $digest -or -not $digest.StartsWith('sha256:')) {
              Write-Log E $stage fail "no sha256 digest for asset '$suffix' in $($vars.execValue) $agentVer release metadata"
              throw "no sha256 digest for $suffix"
            }
            $verifyMode = 'sha256'; $verifyRef = $digest.Substring('sha256:'.Length)
          }
          else {
            $npmPath = "$($vars.execValue)$suffix"
            $url = "https://registry.npmjs.org/$npmPath"
            $npmSepIdx = $npmPath.IndexOf('/-/')
            if ($npmSepIdx -lt 0) { Write-Log E $stage fail "npm <npm>+urlSuffix must form a '<pkg>/-/<file>.tgz' path: $npmPath"; throw "npm path missing /-/ separator" }
            $npmPkg = $npmPath.Substring(0, $npmSepIdx)
            $npmFilename = $npmPath.Substring($npmSepIdx + '/-/'.Length)
            $npmPkgBase = $npmPkg.Substring($npmPkg.LastIndexOf('/') + 1)
            $npmExpectedPrefix = "$npmPkgBase-"
            if (-not $npmFilename.StartsWith($npmExpectedPrefix) -or -not $npmFilename.EndsWith('.tgz')) {
              Write-Log E $stage fail "npm tarball filename does not match '<pkg>-<version>.tgz': $npmFilename (pkg=$npmPkgBase)"
              throw "npm tarball filename shape mismatch: $npmFilename"
            }
            $npmTarVer = $npmFilename.Substring($npmExpectedPrefix.Length, $npmFilename.Length - $npmExpectedPrefix.Length - '.tgz'.Length)
            $npmMetaDoc = [Text.Json.JsonDocument]::Parse($http.GetStringAsync("https://registry.npmjs.org/$npmPkg/$npmTarVer").Result)
            try { $verifyRef = $npmMetaDoc.RootElement.GetProperty('dist').GetProperty('integrity').GetString() } finally { $npmMetaDoc.Dispose() }
            if (-not $verifyRef) { Write-Log E $stage fail "no dist.integrity for $($vars.agentName)"; throw "no dist.integrity for $($vars.agentName)" }
            $verifyMode = 'npm'
          }
          $archive = "$toolsDir\$($vars.agentName)-$(& $sha256 "agent:$($vars.agentName)-ver:$agentVer-arch:$($vars.arch)-manifest:$($vars.manifestSrc)-manifest-sh:$($vars.manifestShContents)-wrapper:$($vars.wrapperSrc)-shim:$($vars.shimTmpl)").tar.xz"
          if ((-not $forcePull) -and (& $archiveOk $archive)) {
            Write-Log I $stage cache-hit ([IO.Path]::GetFileName($archive)); [IO.File]::WriteAllText($pathOut, $archive); return
          }
          if ([IO.File]::Exists($archive) -and -not $forcePull) {
            Write-Log W $stage rebuild "cached archive corrupt; rebuilding"; [IO.File]::Delete($archive)
          }
          $layout = if ($binPath) { 'platform-binary' } else { 'node-bundle' }
          Write-Log I $stage downloading "$($vars.agentName) $agentVer ($layout)"
          $tarTmp = "$tmpDir\_agent.tgz"
          $extractDir = "$tmpDir\_extract"
          [IO.Directory]::CreateDirectory($extractDir) > $null
          # Verify the downloaded bytes before handing them to tar — same
          # threat model as the base/tool tier checksum gate.
          $tarBytes = $http.GetByteArrayAsync($url).Result
          if ($verifyMode -eq 'sha256') {
            & $verifySha256 $tarBytes $verifyRef "$($vars.agentName) github asset"
          }
          else {
            & $verifyNpmIntegrity $tarBytes $verifyRef "$($vars.agentName) npm tarball"
          }
          [IO.File]::WriteAllBytes($tarTmp, $tarBytes)
          & $mustNative tar -xzf $tarTmp -C $extractDir
          [IO.File]::Delete($tarTmp)

          $binary = $vars.agentBinary
          # binPath presence is the layout discriminator: present ⇒ single
          # platform binary at that archive path; absent ⇒ npm node bundle.
          if ($binPath) {
            $binSrc = [IO.Path]::Combine($extractDir, $binPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (-not [IO.File]::Exists($binSrc)) {
              Write-Log E $stage fail "binary not found in tarball: $binPath"
              throw "binary not found in tarball"
            }
            [IO.File]::Copy($binSrc, "$tmpDir\$binary-bin", $true)
            $packInputs = @($binary, 'agent-manifest.sh', "$binary-bin")
          }
          else {
            $pkgSrc = [IO.Path]::Combine($extractDir, 'package')
            if (-not [IO.Directory]::Exists($pkgSrc)) {
              Write-Log E $stage fail "node bundle has no 'package/' dir"
              throw "node bundle has no package/ dir"
            }
            $pkgName = "$binary-pkg"
            [IO.Directory]::Move($pkgSrc, "$tmpDir\$pkgName")
            # Render one shim per package.json `bin` entry. The canonical
            # entry (key matching .binary) goes to "$binary-bin" so
            # agent-wrapper.sh finds it; auxiliary entries become standalone
            # shims under their bin keys. $agentShims holds the full list of
            # rendered filenames (canonical + aux), spread into $packInputs.
            $agentShims = & $renderNodeBinShims $tmpDir "$tmpDir\$pkgName" $pkgName $vars.shimTmpl $binary "$binary-bin"
            $packInputs = @($binary, 'agent-manifest.sh') + @($agentShims) + @($pkgName)
          }

          # Wrapper goes in under the agent command name (regular file,
          # not a symlink) — same choice as lib/tools.sh. Keeps behavior
          # identical across Linux/WSL/Windows host filesystems.
          [IO.File]::WriteAllText("$tmpDir\agent-manifest.sh", $vars.manifestShContents)
          [IO.File]::WriteAllText("$tmpDir\$binary", $vars.wrapperSrc)

          [IO.Directory]::Delete($extractDir, $true)
        }
        default { throw "unknown tier kind: $($vars.kind)" }
      }

      Write-Log I $stage packing ([IO.Path]::GetFileName($archive))
      # GUID (not $PID) so a stale predictable-named partial from a prior
      # run can't be picked up as ours. The .partial.* glob in the parent
      # cleanup still matches because we keep the suffix shape.
      $tmp = "$archive.partial.$([Guid]::NewGuid().ToString('N'))"
      # Three-tier strategy (mirrors lib/tools.sh._detect_pack_xz_mode):
      #   1. external xz on PATH: pipe `tar -cf - ... | xz -0 -T0 -c`
      #   2. bsdtar (libarchive): `--xz --options 'xz:compression-level=0,xz:threads=0'`
      #   3. fallback: `tar --xz` with default level/threads (slower, larger)
      # Windows ships bsdtar with liblzma — path 2 is the common case.
      # Windows ships bsdtar (libarchive), where -I is a synonym for -T
      # (--files-from), not --use-compress-program as in GNU tar. Use the
      # native --xz flag or the explicit xz-pipe path instead.
      $xzCmd = Get-Command xz -ErrorAction SilentlyContinue
      if ($xzCmd) {
        # Pipe via System.Diagnostics.Process — PowerShell native pipelines
        # can corrupt binary data. CopyToAsync on both ends avoids deadlocks
        # when the kernel pipe buffer fills before xz reads.
        $tarPsi = [Diagnostics.ProcessStartInfo]::new('tar')
        foreach ($a in @('-cf', '-', '-C', $tmpDir) + $packInputs) { [void]$tarPsi.ArgumentList.Add($a) }
        $tarPsi.RedirectStandardOutput = $true
        $tarPsi.UseShellExecute = $false
        $xzPsi = [Diagnostics.ProcessStartInfo]::new($xzCmd.Source)
        foreach ($a in @('-0', '-T0', '-c')) { [void]$xzPsi.ArgumentList.Add($a) }
        $xzPsi.RedirectStandardInput = $true
        $xzPsi.RedirectStandardOutput = $true
        $xzPsi.UseShellExecute = $false

        $tarProc = [Diagnostics.Process]::Start($tarPsi)
        $xzProc = [Diagnostics.Process]::Start($xzPsi)
        $outFs = [IO.File]::Create($tmp)
        try {
          $copyIn = $tarProc.StandardOutput.BaseStream.CopyToAsync($xzProc.StandardInput.BaseStream)
          $copyOut = $xzProc.StandardOutput.BaseStream.CopyToAsync($outFs)
          $copyIn.Wait()
          $xzProc.StandardInput.Close()
          $copyOut.Wait()
          $tarProc.WaitForExit()
          $xzProc.WaitForExit()
        }
        finally { $outFs.Close() }
        if ($tarProc.ExitCode -ne 0) { throw "$stage`: tar failed (exit $($tarProc.ExitCode))" }
        if ($xzProc.ExitCode -ne 0) { throw "$stage`: xz failed (exit $($xzProc.ExitCode))" }
      }
      elseif ((& tar --version 2>&1 | Select-Object -First 1) -match 'bsdtar') {
        & $mustNative tar --xz --options 'xz:compression-level=0,xz:threads=0' -cf $tmp -C $tmpDir @packInputs
      }
      else {
        Write-Log W $stage fallback "no xz CLI and tar is not bsdtar; using tar --xz defaults (slower, larger)"
        & $mustNative tar --xz -cf $tmp -C $tmpDir @packInputs
      }
      [IO.File]::Move($tmp, $archive, $true)
      Write-Log I $stage cached ([IO.Path]::GetFileName($archive))
      [IO.File]::WriteAllText($pathOut, $archive)
    }
    finally {
      $http.Dispose()
      try { [IO.Directory]::Delete($tmpDir, $true) } catch {}
    }
  }

  # ── Orchestration ──

  [IO.Directory]::CreateDirectory($toolsDir) > $null
  # Reap ORPHAN partials from prior builds that crashed. The cache dir
  # is shared across concurrent launchers — a blanket delete would
  # race-delete another active launcher's in-progress archive (its
  # File.Move would then fail). Each launch's partial is uniquely
  # named via Guid.NewGuid(); a successful build always consumes its
  # own partial via File.Move. Anything older than the threshold is
  # by definition abandoned, so age-gating cleanup never touches a
  # live builder's file.
  # GetFiles (not EnumerateFiles) so the file list is materialized up
  # front — deleting during enumeration can invalidate the enumerator
  # and skip entries on some filesystems.
  $stalePartialCutoff = (Get-Date).AddHours(-1)
  foreach ($stale in [IO.Directory]::GetFiles($toolsDir, '*.partial.*')) {
    try {
      if ([IO.FileInfo]::new($stale).LastWriteTime -lt $stalePartialCutoff) {
        [IO.File]::Delete($stale)
      }
    }
    catch {}
  }

  # Each tier is a fully independent pipeline (own version probes, hash,
  # cache-check, build) run as a concurrent ThreadJob — no version-
  # resolution barrier, mirroring lib/tools.sh's per-tier subshells. The
  # job writes its resolved archive path to a temp file (the launcher
  # consumes the three paths after this returns). The manifest is parsed
  # HERE — Agent.ps1 isn't loaded in the job runspaces — so only no-
  # network extraction happens parent-side; the job does version+network.
  $shimTmpl = & $lfOnly ([IO.File]::ReadAllText("$projectRoot\bin\node-shim.sh.tmpl"))

  $baseVars = @{
    kind = 'base'; userAgent = $crateUserAgent
    arch = $script:arch; archRg = $script:archRg; archMicro = $script:archMicro
  }
  $toolVars = @{
    kind = 'tool'; userAgent = $crateUserAgent
    arch = $script:arch; archGnu = $script:archGnu; shimTmpl = $shimTmpl
  }
  $agentVars = @{
    kind = 'agent'; userAgent = $crateUserAgent
    agentName = $agent; agentBinary = $script:agentBinary
    arch = $script:arch; archTriple = $script:archTriple; shimTmpl = $shimTmpl
  }
  # Agent inputs are only needed when the tier will actually build (a
  # pinned tier resolves by hash prefix in the job and never reads these).
  # Manifest parsing + urlSuffix validation happen here; the job resolves
  # the version, builds the URL, fetches the digest/integrity, and hashes.
  if (-not $optAgentHash) {
    & $resolveExecSource
    $suffixRaw = Get-AgentField '.executable.urlSuffix'
    if ($suffixRaw -notmatch '^[A-Za-z0-9._/{}-]+$' -or $suffixRaw -match '\.\.') {
      Write-Log E "tools.$agent" fail "invalid executable.urlSuffix: '$suffixRaw' (chars [A-Za-z0-9._/{}-], no '..')"
      throw "invalid executable.urlSuffix: $suffixRaw"
    }
    $agentVars.execSource = $script:execSource
    $agentVars.execValue = $script:execValue
    $agentVars.urlSuffix = $suffixRaw
    $agentVars.binPath = Get-AgentField '.executable.binPath'
    $agentVars.manifestShContents = & $agentManifestShContents
    $agentVars.manifestSrc = & $lfOnly ([IO.File]::ReadAllText($agentManifestPath))
    $agentVars.wrapperSrc = & $lfOnly ([IO.File]::ReadAllText("$projectRoot\bin\agent-wrapper.sh"))
  }

  $pd = [IO.Path]::Combine([IO.Path]::GetTempPath(), "crate-paths-$([Guid]::NewGuid().ToString('N'))")
  [IO.Directory]::CreateDirectory($pd) > $null
  try {
    $basePath = [IO.Path]::Combine($pd, 'base')
    $toolPath = [IO.Path]::Combine($pd, 'tool')
    $agentPath = [IO.Path]::Combine($pd, 'agent')
    $jobs = @(
      Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
        $script:LogLevel, $projectRoot, 'base', $toolsDir, $basePath, $optBaseHash, $forcePull, $baseVars
      )
      Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
        $script:LogLevel, $projectRoot, 'tool', $toolsDir, $toolPath, $optToolHash, $forcePull, $toolVars
      )
      Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
        $script:LogLevel, $projectRoot, $agent, $toolsDir, $agentPath, $optAgentHash, $forcePull, $agentVars
      )
    )
    # Waits for all three (already running concurrently) and re-throws any
    # job failure. Each job's only side effect we read is its path file;
    # the output stream is intentionally ignored.
    $jobs | Receive-Job -Wait -AutoRemoveJob | Out-Null
    $script:baseArchive = [IO.File]::ReadAllText($basePath)
    $script:toolArchive = [IO.File]::ReadAllText($toolPath)
    $script:agentArchive = [IO.File]::ReadAllText($agentPath)
    if (-not $script:baseArchive -or -not $script:toolArchive -or -not $script:agentArchive) {
      Write-Log E tools fail "a tier pipeline did not report its archive path"
      throw "a tier pipeline did not report its archive path"
    }
  }
  finally {
    try { [IO.Directory]::Delete($pd, $true) } catch {}
  }
}
