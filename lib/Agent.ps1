# Agent.ps1 — manifest loader for multi-agent sandbox. Dot-sourced
# (not executed). Requires: $projectRoot, $agent (set by launcher).
#
# Sets (script scope) after Invoke-AgentLoad:
#   $agentDir           — $projectRoot\agent\<agent>
#   $agentManifestPath  — path to manifest.json
#   $agentManifest      — parsed PSCustomObject
#   $agentBinary        — e.g. "claude"
#   $agentProjectDir    — e.g. ".claude"
#   $agentConfigDir     — expanded host config dir (respects env override)
#   $crateDir           — in-sandbox config dir (mount target)
#   $crateEnv           — env var name the wrapper sets inside the sandbox
#                         to point at $crateDir; empty if the agent
#                         has no config-dir env var (Gemini)
#
# Sandbox-side path policy (see lib/agent.sh for the rationale):
#   - With configDir.env present, stage at /usr/local/etc/crate/<agent>
#     and let the wrapper export the env var.
#   - Without it, mount at the default path with $HOME rewritten to /home/agent.
#
# Helpers:
#   Get-AgentField $path  — dotted path lookup, returns $null if missing
#   Get-AgentList  $path  — array of strings (empty array if missing)
#   Get-AgentKv    $path  — hashtable of string → string

function Invoke-AgentLoad {
  # Validate $agent before it joins a path. Same single-segment whitelist
  # as the manifest fields below; otherwise '..\foo' as --agent would
  # escape $projectRoot\agent\ and point us at an arbitrary sibling
  # manifest.json/oauth.json before any later check could catch it.
  if ($agent -notmatch '^[A-Za-z0-9._-]+$' -or $agent -in @('.', '..')) {
    Write-Log E launcher fail "invalid --agent value: '$agent' (must match [A-Za-z0-9._-]+ and not be '.' or '..')"
    throw "invalid --agent: $agent"
  }
  $script:agentDir = [IO.Path]::Combine($projectRoot, 'agent', $agent)
  $script:agentManifestPath = [IO.Path]::Combine($agentDir, 'manifest.json')
  if (-not [IO.File]::Exists($script:agentManifestPath)) {
    Write-Log E launcher fail "unknown agent: $agent (no $($script:agentManifestPath))"
    throw "unknown agent: $agent"
  }

  $script:agentManifest = [IO.File]::ReadAllText($script:agentManifestPath) |
  ConvertFrom-Json
  # Both values flow into host paths, mount targets, and (via
  # $agentBinary) wsl/sh-c command strings where there is no argv to
  # escape into. Whitelist alphanumerics + `.` `_` `-`; reject empty,
  # '.', '..', and anything else, so a hostile manifest can't smuggle
  # path-traversal or shell metachars across that boundary.
  $script:agentBinary = $script:agentManifest.binary
  if ($script:agentBinary -notmatch '^[A-Za-z0-9._-]+$' -or $script:agentBinary -in @('.', '..')) {
    Write-Log E launcher fail "invalid .binary in $($script:agentManifestPath): '$($script:agentBinary)' (must match [A-Za-z0-9._-]+ and not be '.' or '..')"
    throw "invalid .binary: $($script:agentBinary)"
  }
  $script:agentProjectDir = $script:agentManifest.projectDir
  if ($script:agentProjectDir -notmatch '^[A-Za-z0-9._-]+$' -or $script:agentProjectDir -in @('.', '..')) {
    Write-Log E launcher fail "invalid .projectDir in $($script:agentManifestPath): '$($script:agentProjectDir)' (must be a single safe relative segment like '.claude')"
    throw "invalid .projectDir: $($script:agentProjectDir)"
  }

  $envName = $script:agentManifest.configDir.env
  $defaultPath = $script:agentManifest.configDir.default
  $script:agentConfigDir = ''
  $configDirFromEnv = $false
  if ($envName) {
    # Reject anything outside the POSIX shell-name grammar. The value
    # later flows into agent-manifest.sh as `export $envName=...`, so a
    # malicious manifest could otherwise smuggle shell into the wrapper.
    if ($envName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
      Write-Log E launcher fail "invalid configDir.env in $($script:agentManifestPath): '$envName' (must match [A-Za-z_][A-Za-z0-9_]*)"
      throw "invalid configDir.env: $envName"
    }
    $override = [Environment]::GetEnvironmentVariable($envName)
    if ($override) {
      $script:agentConfigDir = $override
      # Mark the source so the containment policy below can give env-
      # supplied paths a wider allowlist (user environment is trusted)
      # than manifest-supplied defaults (must stay under $HOME).
      $configDirFromEnv = $true
    }
  }
  if (-not $script:agentConfigDir) {
    if ($defaultPath.StartsWith('$HOME')) {
      $script:agentConfigDir = $HOME + $defaultPath.Substring('$HOME'.Length)
    }
    else {
      $script:agentConfigDir = $defaultPath
    }
  }

  # Canonicalise the resolved config dir. GetFullPath collapses '..'/'.'
  # syntactically; ResolveLinkTarget then follows junctions/symlinks so
  # a layout where '$HOME/.claude' points at C:\Windows\System32 (or
  # /var/secrets) surfaces as the real target before containment runs.
  #
  # First-run is fine: a brand-new install has no config dir yet, but
  # the user-facing "use the <agent> CLI to log in on the host" hint
  # is owned by Ensure-Credential.ps1 (which runs next in the launcher
  # chain). Failing here on a missing dir would short-circuit that
  # message with a generic canonicalisation error. Walk up to the
  # nearest existing ancestor instead, follow its symlinks, and re-
  # append the missing tail so the containment policy below still
  # applies.
  try {
    $canon = [IO.Path]::GetFullPath($script:agentConfigDir)
  }
  catch {
    Write-Log E launcher fail "agent config dir cannot be canonicalised: $($script:agentConfigDir)"
    throw "agent config dir cannot be canonicalised: $($script:agentConfigDir)"
  }
  if ([IO.Directory]::Exists($canon)) {
    $linkInfo = [IO.Directory]::ResolveLinkTarget($canon, $true)
    if ($linkInfo) { $canon = $linkInfo.FullName }
  }
  else {
    $tail = ''
    $head = $canon
    while ($head -and -not [IO.Directory]::Exists($head)) {
      $parent = [IO.Path]::GetDirectoryName($head)
      if ([string]::IsNullOrEmpty($parent) -or $parent -eq $head) { break }
      $leaf = [IO.Path]::GetFileName($head)
      $tail = if ($tail) { [IO.Path]::Combine($leaf, $tail) } else { $leaf }
      $head = $parent
    }
    if ($head -and [IO.Directory]::Exists($head)) {
      $linkInfo = [IO.Directory]::ResolveLinkTarget($head, $true)
      if ($linkInfo) { $head = $linkInfo.FullName }
      $canon = if ($tail) { [IO.Path]::Combine($head, $tail) } else { $head }
    }
    # else: leave $canon as the GetFullPath result; containment below
    # still operates against the syntactic absolute form.
  }
  $canon = $canon.TrimEnd('/', '\')

  # Reject filesystem root only — a malformed manifest like
  # `default="/"` or an env override `=/` would otherwise let later
  # stage operations roam the whole disk. We don't gate the
  # individual segment characters here: $script:agentConfigDir is
  # host-side, used only with [IO.Path]::Combine / [IO.File]::Exists
  # / Copy / hardlink APIs (no shell interpolation), so spaces and
  # normally-shell-sensitive characters in absolute paths (e.g.
  # 'C:\Users\Jane Doe\.claude') are safe to allow. Traversal is
  # already collapsed by GetFullPath.
  if (-not $canon -or $canon -match '^[A-Za-z]:$') {
    Write-Log E launcher fail "agent config dir resolves to filesystem root: $($script:agentConfigDir)"
    throw "agent config dir resolves to filesystem root"
  }

  # Containment policy:
  #   - Manifest-supplied default → must canonicalise under $HOME so a
  #     hostile manifest can't relocate the staging root to system
  #     dirs (the per-file checks would otherwise resolve under the
  #     attacker-chosen base).
  #   - Env-supplied override → any absolute path. Env vars are part
  #     of the user's trusted environment; a user who deliberately
  #     exports CLAUDE_CONFIG_DIR=/srv/agents/claude has chosen it.
  if (-not $configDirFromEnv) {
    $canonHome = [IO.Path]::GetFullPath($HOME)
    if ([IO.Directory]::Exists($canonHome)) {
      $homeLink = [IO.Directory]::ResolveLinkTarget($canonHome, $true)
      if ($homeLink) { $canonHome = $homeLink.FullName }
    }
    $canonHome = $canonHome.TrimEnd('/', '\')
    $isUnder = ($canon -eq $canonHome) -or
    $canon.StartsWith($canonHome + '/', [StringComparison]::Ordinal) -or
    $canon.StartsWith($canonHome + '\', [StringComparison]::Ordinal)
    if (-not $isUnder) {
      Write-Log E launcher fail "manifest configDir.default must canonicalise under `$HOME ($canonHome), got: $canon"
      throw "configDir.default not under `$HOME: $canon"
    }
  }

  # Use the canonical form everywhere downstream. Eliminates symlink/'..'
  # ambiguity in later prefix checks (e.g. $assertUnderConfig in
  # Init-Config.ps1).
  $script:agentConfigDir = $canon

  $script:crateEnv = $envName
  if ($envName) {
    $script:crateDir = "/usr/local/etc/crate/$agent"
  }
  elseif ($defaultPath.StartsWith('$HOME')) {
    $script:crateDir = '/home/agent' + $defaultPath.Substring('$HOME'.Length)
  }
  else {
    $script:crateDir = $defaultPath
  }

  Test-ManifestPaths
}

# Validate every manifest-supplied relative path (files.rw, files.ro,
# files.roDirs entries, plus credential.file). A hostile manifest could
# otherwise smuggle '..\etc\passwd' (or its POSIX equivalent) into the
# files lists — Init-Config.ps1 would happily hardlink it into the
# sandbox stage; Ensure-Credential.ps1 would read/overwrite the host
# file. Validation runs in this shared loader so both call sites get
# the same check before any path use.
#
# Allowed: relative paths whose every '/'-delimited segment matches
# [A-Za-z0-9._-]+ and is not '.' or '..'. Rejects empty strings,
# absolute paths, backslashes, control chars, and traversal segments.
function Test-ManifestPaths {
  $entries = [Collections.Generic.List[object]]::new()
  if ($script:agentManifest.PSObject.Properties.Name -contains 'files') {
    foreach ($listName in @('rw', 'ro', 'roDirs')) {
      $list = $script:agentManifest.files.$listName
      if ($null -ne $list) { foreach ($e in @($list)) { $entries.Add($e) } }
    }
  }
  if ($script:agentManifest.PSObject.Properties.Name -contains 'credential' -and
    $script:agentManifest.credential -and
    $script:agentManifest.credential.file) {
    $entries.Add($script:agentManifest.credential.file)
  }
  foreach ($e in $entries) {
    if (-not (Test-SafeManifestPath $e)) {
      $j = ($e | ConvertTo-Json -Compress -Depth 1)
      Write-Log E launcher fail "$($script:agentManifestPath) has unsafe path entry: $j (allowed: relative paths with [A-Za-z0-9._-] segments, no '.' / '..' / absolute / empty)"
      throw "unsafe manifest path: $j"
    }
  }
}

function Test-SafeManifestPath {
  param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()]$Value)
  if ($Value -isnot [string]) { return $false }
  if ($Value.Length -eq 0) { return $false }
  foreach ($seg in $Value.Split('/')) {
    if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { return $false }
    if ($seg -notmatch '^[A-Za-z0-9._-]+$') { return $false }
  }
  $true
}

function Get-AgentField {
  param([string]$Path)
  $cur = $script:agentManifest
  foreach ($seg in $Path.TrimStart('.').Split('.')) {
    if ($null -eq $cur) { return $null }
    if ($cur.PSObject.Properties.Name -notcontains $seg) { return $null }
    $cur = $cur.$seg
  }
  $cur
}

function Get-AgentList {
  param([string]$Path)
  $v = Get-AgentField $Path
  if ($null -eq $v) { return @() }
  [string[]]$v
}

function Get-AgentKv {
  param([string]$Path)
  $v = Get-AgentField $Path
  $h = [ordered]@{}
  if ($null -eq $v) { return $h }
  foreach ($p in $v.PSObject.Properties) {
    $h[$p.Name] = [string]$p.Value
  }
  $h
}
