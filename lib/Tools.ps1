# Tools.ps1 — tool archive build system
# Dot-sourced (not executed). Requires: $projectRoot

$sha256 = {
  [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
  ).Replace('-', '').ToLower()
}

# Structured logging is provided by Write-Log in lib/Log.ps1, dot-sourced
# from Init-Launcher.ps1.

$http = [Net.Http.HttpClient]::new()
$http.DefaultRequestHeaders.UserAgent.ParseAdd('claude-code-sandbox/1.0')

# ── Tool archive system ──

$cacheDir = if ($env:XDG_CACHE_HOME) { "$env:XDG_CACHE_HOME\claude-code-sandbox" } else { "$HOME\.cache\claude-code-sandbox" }
$toolsDir = "$cacheDir\tools"

$detectArch = {
  $osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  switch ($osArch) {
    'X64' {
      $script:archNode = 'x64'
      $script:archRg = 'x86_64-unknown-linux-musl'
      $script:archMicro = 'linux64-static'
      $script:archUv = 'x86_64-unknown-linux-musl'
      $script:archPnpm = 'linux-x64'
      $script:archClaude = 'linux-x64'
    }
    'Arm64' {
      $script:archNode = 'arm64'
      $script:archRg = 'aarch64-unknown-linux-gnu'
      $script:archMicro = 'linux-arm64'
      $script:archUv = 'aarch64-unknown-linux-musl'
      $script:archPnpm = 'linux-arm64'
      $script:archClaude = 'linux-arm64'
    }
    default {
      Write-Log E tools fail "unsupported architecture: $osArch"
      throw "unsupported architecture: $osArch"
    }
  }
}

$fetchToolVersions = {
  $nodeTask = $http.GetStringAsync('https://nodejs.org/dist/index.json')
  $rgTask = $http.GetStringAsync('https://api.github.com/repos/BurntSushi/ripgrep/releases/latest')
  $microTask = $http.GetStringAsync('https://api.github.com/repos/zyedidia/micro/releases/latest')
  $pnpmTask = $http.GetStringAsync('https://registry.npmjs.org/pnpm/latest')
  $uvTask = $http.GetStringAsync('https://pypi.org/pypi/uv/json')
  $claudeTask = $http.GetStringAsync('https://registry.npmjs.org/@anthropic-ai/claude-code/latest')
  [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask, $pnpmTask, $uvTask, $claudeTask)

  $nodeJson = [Text.Json.JsonDocument]::Parse($nodeTask.Result)
  $rgJson = [Text.Json.JsonDocument]::Parse($rgTask.Result)
  $microJson = [Text.Json.JsonDocument]::Parse($microTask.Result)
  $pnpmJson = [Text.Json.JsonDocument]::Parse($pnpmTask.Result)
  $uvJson = [Text.Json.JsonDocument]::Parse($uvTask.Result)
  $claudeJson = [Text.Json.JsonDocument]::Parse($claudeTask.Result)

  # Node LTS: find first entry where lts is not false
  $script:nodeVer = $null
  foreach ($el in $nodeJson.RootElement.EnumerateArray()) {
    $lts = $el.GetProperty('lts')
    if ($lts.ValueKind -ne [Text.Json.JsonValueKind]::False) {
      $script:nodeVer = $el.GetProperty('version').GetString().TrimStart('v')
      break
    }
  }
  $script:rgVer = $rgJson.RootElement.GetProperty('tag_name').GetString()
  $script:microVer = $microJson.RootElement.GetProperty('tag_name').GetString().TrimStart('v')
  $script:pnpmVer = $pnpmJson.RootElement.GetProperty('version').GetString()
  $script:uvVer = $uvJson.RootElement.GetProperty('info').GetProperty('version').GetString()
  $script:claudeVer = $claudeJson.RootElement.GetProperty('version').GetString()

  $nodeJson.Dispose(); $rgJson.Dispose(); $microJson.Dispose()
  $pnpmJson.Dispose(); $uvJson.Dispose(); $claudeJson.Dispose()
}

# Note: archive validation (`tar -tJf`) lives inside each per-tier
# worker block below, not at module scope. Each worker re-defines a
# tiny local `archiveOk` helper because Start-ThreadJob runspaces
# can't reliably inherit module-scope script blocks.

$resolveArchive = { param($tier, $prefix)
  $cached = $null
  if ([IO.Directory]::Exists($toolsDir)) {
    $cached = [IO.Directory]::GetFiles($toolsDir, "${tier}-${prefix}*.tar.xz")
  }
  if (-not $cached -or $cached.Length -eq 0) {
    Write-Log E "tools.$tier" fail "no cached archive matching hash '$prefix'"
    throw "no cached $tier archive matching hash '$prefix'"
  }
  if ($cached.Length -gt 1) {
    Write-Log E "tools.$tier" fail "ambiguous hash prefix '$prefix' matches multiple archives"
    throw "ambiguous $tier hash prefix '$prefix'"
  }
  $cached[0]
}

# ── Tier builder ──
#
# One shared script block that runs inside each Start-ThreadJob
# runspace. Thread-job runspaces don't inherit the parent's script
# scope reliably, so the block takes everything as explicit params
# (including a $vars hashtable with tier-specific URL/version bits)
# and re-dot-sources Log.ps1 so Write-Log is available. Hashtables
# serialize cleanly across runspace boundaries — script blocks do not,
# which is why the tier-specific download logic lives in an inline
# `switch ($tier)` rather than being passed in as a closure.
#
# Logging works because Write-Log writes to [Console]::Error directly
# (see lib/Log.ps1) — that bypasses the job's Information stream so
# tier output streams live to the parent terminal.
#
# The archive path is computed by the orchestrator before the job
# starts and passed in. The builder writes its archive in place; no
# return value is needed.
$tierBuilder = {
  param($logLevel, $projectRoot, $tier, $archive, $optHash, $forcePull, $vars)
  $script:LogLevel = $logLevel
  . "$projectRoot\lib\Log.ps1"
  $stage = "tools.$tier"

  $archiveOk = { param($p)
    if (-not [IO.File]::Exists($p)) { return $false }
    if ([IO.FileInfo]::new($p).Length -eq 0) { return $false }
    & tar -tJf $p *> $null
    return ($LASTEXITCODE -eq 0)
  }

  # Shared prologue: pin → cache-hit → rebuild-prep
  if ($optHash) {
    if (-not (& $archiveOk $archive)) {
      Write-Log E $stage fail "pinned archive is corrupt: $([IO.Path]::GetFileName($archive))"
      throw "pinned $tier archive is corrupt"
    }
    Write-Log I $stage cache-pin ([IO.Path]::GetFileName($archive))
    return
  }
  if ((-not $forcePull) -and (& $archiveOk $archive)) {
    Write-Log I $stage cache-hit ([IO.Path]::GetFileName($archive))
    return
  }
  if ([IO.File]::Exists($archive) -and -not $forcePull) {
    Write-Log W $stage rebuild "cached archive corrupt; rebuilding"
    [IO.File]::Delete($archive)
  }

  $h = [Net.Http.HttpClient]::new()
  $h.DefaultRequestHeaders.UserAgent.ParseAdd('claude-code-sandbox/1.0')
  $tmpDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "claude-build-$(Get-Random)")
  [IO.Directory]::CreateDirectory($tmpDir) > $null
  try {
    # Tier-specific: download into $tmpDir and set $packInputs to the
    # list of files to include in the final archive.
    $packInputs = $null
    switch ($tier) {
      'base' {
        Write-Log I $stage downloading "node $($vars.nodeVer), ripgrep $($vars.rgVer), micro $($vars.microVer)"
        $nodeUrl = "https://nodejs.org/dist/v$($vars.nodeVer)/node-v$($vars.nodeVer)-linux-$($vars.archNode).tar.xz"
        $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/$($vars.rgVer)/ripgrep-$($vars.rgVer)-$($vars.archRg).tar.gz"
        $microUrl = "https://github.com/zyedidia/micro/releases/download/v$($vars.microVer)/micro-$($vars.microVer)-$($vars.archMicro).tar.gz"
        $nodeTask = $h.GetByteArrayAsync($nodeUrl)
        $rgTask = $h.GetByteArrayAsync($rgUrl)
        $microTask = $h.GetByteArrayAsync($microUrl)
        [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask)

        $nodeTmp = "$tmpDir\_node.tar.xz"; [IO.File]::WriteAllBytes($nodeTmp, $nodeTask.Result)
        tar -xJf $nodeTmp -C $tmpDir --strip-components=2 "node-v$($vars.nodeVer)-linux-$($vars.archNode)/bin/node"
        [IO.File]::Delete($nodeTmp)

        $rgTmp = "$tmpDir\_rg.tar.gz"; [IO.File]::WriteAllBytes($rgTmp, $rgTask.Result)
        tar -xzf $rgTmp -C $tmpDir --strip-components=1 "ripgrep-$($vars.rgVer)-$($vars.archRg)/rg"
        [IO.File]::Delete($rgTmp)

        $microTmp = "$tmpDir\_micro.tar.gz"; [IO.File]::WriteAllBytes($microTmp, $microTask.Result)
        tar -xzf $microTmp -C $tmpDir --strip-components=1 "micro-$($vars.microVer)/micro"
        [IO.File]::Delete($microTmp)

        [IO.File]::Copy("$projectRoot\bin\claude-wrapper.sh", "$tmpDir\claude-wrapper", $true)
        $packInputs = @('node', 'rg', 'micro', 'claude-wrapper')
      }
      'tool' {
        Write-Log I $stage downloading "pnpm $($vars.pnpmVer), uv $($vars.uvVer)"
        $pnpmTask = $h.GetByteArrayAsync("https://github.com/pnpm/pnpm/releases/download/v$($vars.pnpmVer)/pnpm-$($vars.archPnpm)")
        $uvTask = $h.GetByteArrayAsync("https://github.com/astral-sh/uv/releases/download/$($vars.uvVer)/uv-$($vars.archUv).tar.gz")
        [Threading.Tasks.Task]::WaitAll($pnpmTask, $uvTask)

        [IO.File]::WriteAllBytes("$tmpDir\pnpm", $pnpmTask.Result)
        $uvTmp = "$tmpDir\_uv.tar.gz"; [IO.File]::WriteAllBytes($uvTmp, $uvTask.Result)
        tar -xzf $uvTmp -C $tmpDir --strip-components=1
        [IO.File]::Delete($uvTmp)
        $packInputs = @('pnpm', 'uv', 'uvx')
      }
      'claude' {
        Write-Log I $stage downloading "claude $($vars.claudeVer)"
        $gcsBucket = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
        $claudeBytes = $h.GetByteArrayAsync("$gcsBucket/$($vars.claudeVer)/$($vars.archClaude)/claude").Result
        [IO.File]::WriteAllBytes("$tmpDir\claude", $claudeBytes)
        $packInputs = @('claude')
      }
      default { throw "unknown tier: $tier" }
    }

    # Shared pack + atomic-rename. Build to a temp path and rename on
    # success — if the process is killed mid-tar, the partial file
    # sits at the .partial path and gets swept on the next run; the
    # final archive path is never partially written.
    Write-Log I $stage packing ([IO.Path]::GetFileName($archive))
    $tmp = "$archive.partial.$PID"
    tar -cJf $tmp -C $tmpDir @packInputs
    [IO.File]::Move($tmp, $archive, $true)
    Write-Log I $stage cached ([IO.Path]::GetFileName($archive))
  }
  finally { try { [IO.Directory]::Delete($tmpDir, $true) } catch {} }
}

$buildToolArchives = {
  [IO.Directory]::CreateDirectory($toolsDir) > $null
  # Sweep stale .partial.* archives left by interrupted previous runs
  # (we build to a temp name and atomic-rename on success, so a
  # partial archive at the final path should never exist — but the
  # temp file leaks on Ctrl-C and needs collecting).
  foreach ($stale in [IO.Directory]::EnumerateFiles($toolsDir, '*.partial.*')) {
    try { [IO.File]::Delete($stale) } catch {}
  }

  # Fetch versions once, up front, if any tier is unpinned. The 3 tier
  # workers each need their own version vars, so we resolve them here
  # before fanning out — fetchToolVersions does all 6 HTTP calls in
  # parallel anyway.
  if ((-not $optBaseHash) -or (-not $optToolHash) -or (-not $optClaudeHash)) {
    if (-not $script:nodeVer) { . $fetchToolVersions }
  }

  # Resolve all 3 archive paths up front so the parallel workers are
  # fully independent — each just operates on the path it was given.
  if ($optBaseHash) {
    $script:baseArchive = & $resolveArchive 'base' $optBaseHash
  }
  else {
    # Normalize line endings: the .sh launcher reads this file via raw
    # `cat`, so a CRLF checkout on Windows would otherwise produce a
    # different cache hash for the same canonical source.
    $wrapperSrc = ([IO.File]::ReadAllText("$projectRoot\bin\claude-wrapper.sh")).Replace("`r`n", "`n")
    $baseHash = & $sha256 "base-node:$nodeVer-rg:$rgVer-micro:$microVer-$wrapperSrc"
    $script:baseArchive = "$toolsDir\base-$baseHash.tar.xz"
  }
  if ($optToolHash) {
    $script:toolArchive = & $resolveArchive 'tool' $optToolHash
  }
  else {
    $toolHash = & $sha256 "tool-pnpm:$pnpmVer-uv:$uvVer"
    $script:toolArchive = "$toolsDir\tool-$toolHash.tar.xz"
  }
  if ($optClaudeHash) {
    $script:claudeArchive = & $resolveArchive 'claude' $optClaudeHash
  }
  else {
    $claudeHash = & $sha256 "claude-$claudeVer"
    $script:claudeArchive = "$toolsDir\claude-$claudeHash.tar.xz"
  }

  # Fan out: 3 thread jobs, one per tier. Tiers are fully independent
  # — different downloads, different archive paths, no shared state —
  # so the cold-cache wall time drops from sum(tiers) to max(tiers).
  # On warm cache, the 3 `tar -tJf` validations also run concurrently.
  $baseVars = @{
    nodeVer   = $script:nodeVer;  rgVer    = $script:rgVer;    microVer = $script:microVer
    archNode  = $script:archNode; archRg   = $script:archRg;   archMicro = $script:archMicro
  }
  $toolVars = @{
    pnpmVer = $script:pnpmVer; uvVer = $script:uvVer
    archPnpm = $script:archPnpm; archUv = $script:archUv
  }
  $claudeVars = @{
    claudeVer = $script:claudeVer; archClaude = $script:archClaude
  }
  $jobs = @(
    Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
      $script:LogLevel, $projectRoot, 'base', $script:baseArchive, $optBaseHash, $forcePull, $baseVars
    )
    Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
      $script:LogLevel, $projectRoot, 'tool', $script:toolArchive, $optToolHash, $forcePull, $toolVars
    )
    Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
      $script:LogLevel, $projectRoot, 'claude', $script:claudeArchive, $optClaudeHash, $forcePull, $claudeVars
    )
  )
  # Receive-Job -Wait re-throws any exception from a failed tier
  # in the parent runspace, so a broken pin or a download failure
  # surfaces normally.
  $jobs | Receive-Job -Wait -AutoRemoveJob
}
