# Tools.ps1 — tool archive build system
# Dot-sourced (not executed). Requires: $projectRoot

$sha256 = {
  [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
  ).Replace('-', '').ToLower()
}

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
    default { throw "Unsupported architecture: $osArch" }
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

$resolveArchive = { param($tier, $prefix)
  $matches = @(Get-ChildItem "$toolsDir\${tier}-${prefix}*.tar.xz" -ErrorAction SilentlyContinue)
  if ($matches.Count -eq 0) { throw "No cached archive found for $tier hash '$prefix'" }
  if ($matches.Count -gt 1) { throw "Ambiguous hash prefix '$prefix' -- matches multiple $tier archives" }
  $matches[0].FullName
}

$buildToolArchives = {
  [IO.Directory]::CreateDirectory($toolsDir) > $null

  # ── Tier 1: Base ──
  if ($optBaseHash) {
    $script:baseArchive = & $resolveArchive 'base' $optBaseHash
  }
  else {
    if (-not $script:nodeVer) { . $fetchToolVersions }
    $baseHash = & $sha256 "base-node:$nodeVer-rg:$rgVer-micro:$microVer-$([IO.File]::ReadAllText("$projectRoot\bin\claude-wrapper.sh"))"
    $script:baseArchive = "$toolsDir\base-$baseHash.tar.xz"
    if (-not [IO.File]::Exists($baseArchive) -or $forcePull) {
      Write-Host "  Downloading node $nodeVer, ripgrep $rgVer, micro $microVer..." -ForegroundColor DarkGray
      $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "claude-build-$(Get-Random)"
      [IO.Directory]::CreateDirectory($tmpDir) > $null
      try {
        # Download node, rg, micro — start all async, then extract sequentially
        $nodeUrl = "https://nodejs.org/dist/v${nodeVer}/node-v${nodeVer}-linux-${archNode}.tar.xz"
        $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/${rgVer}/ripgrep-${rgVer}-${archRg}.tar.gz"
        $microUrl = "https://github.com/zyedidia/micro/releases/download/v${microVer}/micro-${microVer}-${archMicro}.tar.gz"
        $nodeTask = $http.GetByteArrayAsync($nodeUrl)
        $rgTask = $http.GetByteArrayAsync($rgUrl)
        $microTask = $http.GetByteArrayAsync($microUrl)
        [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask)

        # Write and extract each
        $nodeTmp = "$tmpDir\_node.tar.xz"; [IO.File]::WriteAllBytes($nodeTmp, $nodeTask.Result)
        tar -xJf $nodeTmp -C $tmpDir --strip-components=2 "node-v${nodeVer}-linux-${archNode}/bin/node"
        Remove-Item $nodeTmp

        $rgTmp = "$tmpDir\_rg.tar.gz"; [IO.File]::WriteAllBytes($rgTmp, $rgTask.Result)
        tar -xzf $rgTmp -C $tmpDir --strip-components=1 "ripgrep-${rgVer}-${archRg}/rg"
        Remove-Item $rgTmp

        $microTmp = "$tmpDir\_micro.tar.gz"; [IO.File]::WriteAllBytes($microTmp, $microTask.Result)
        tar -xzf $microTmp -C $tmpDir --strip-components=1 "micro-${microVer}/micro"
        Remove-Item $microTmp

        Copy-Item "$projectRoot\bin\claude-wrapper.sh" "$tmpDir\claude-wrapper"
        tar -cJf $baseArchive -C $tmpDir node rg micro claude-wrapper
      }
      finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  Write-Host "base:   $(Split-Path -Leaf $baseArchive)" -ForegroundColor DarkGray

  # ── Tier 2: Tool ──
  if ($optToolHash) {
    $script:toolArchive = & $resolveArchive 'tool' $optToolHash
  }
  else {
    if (-not $script:pnpmVer) { . $fetchToolVersions }
    $toolHash = & $sha256 "tool-pnpm:$pnpmVer-uv:$uvVer"
    $script:toolArchive = "$toolsDir\tool-$toolHash.tar.xz"
    if (-not [IO.File]::Exists($toolArchive) -or $forcePull) {
      Write-Host "  Downloading pnpm $pnpmVer, uv $uvVer..." -ForegroundColor DarkGray
      $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "claude-build-$(Get-Random)"
      [IO.Directory]::CreateDirectory($tmpDir) > $null
      try {
        $pnpmTask = $http.GetByteArrayAsync("https://github.com/pnpm/pnpm/releases/download/v${pnpmVer}/pnpm-${archPnpm}")
        $uvTask = $http.GetByteArrayAsync("https://github.com/astral-sh/uv/releases/download/${uvVer}/uv-${archUv}.tar.gz")
        [Threading.Tasks.Task]::WaitAll($pnpmTask, $uvTask)

        [IO.File]::WriteAllBytes("$tmpDir\pnpm", $pnpmTask.Result)
        $uvTmp = "$tmpDir\_uv.tar.gz"; [IO.File]::WriteAllBytes($uvTmp, $uvTask.Result)
        tar -xzf $uvTmp -C $tmpDir --strip-components=1
        Remove-Item $uvTmp

        tar -cJf $toolArchive -C $tmpDir pnpm uv uvx
      }
      finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  Write-Host "tools:  $(Split-Path -Leaf $toolArchive)" -ForegroundColor DarkGray

  # ── Tier 3: Claude ──
  if ($optClaudeHash) {
    $script:claudeArchive = & $resolveArchive 'claude' $optClaudeHash
  }
  else {
    if (-not $script:claudeVer) { . $fetchToolVersions }
    $claudeHash = & $sha256 "claude-$claudeVer"
    $script:claudeArchive = "$toolsDir\claude-$claudeHash.tar.xz"
    if (-not [IO.File]::Exists($claudeArchive) -or $forcePull) {
      Write-Host "  Downloading claude $claudeVer..." -ForegroundColor DarkGray
      $gcsBucket = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
      $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "claude-build-$(Get-Random)"
      [IO.Directory]::CreateDirectory($tmpDir) > $null
      try {
        $claudeBytes = $http.GetByteArrayAsync("$gcsBucket/$claudeVer/$archClaude/claude").Result
        [IO.File]::WriteAllBytes("$tmpDir\claude", $claudeBytes)
        tar -cJf $claudeArchive -C $tmpDir claude
      }
      finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  Write-Host "claude: $(Split-Path -Leaf $claudeArchive)" -ForegroundColor DarkGray
}
