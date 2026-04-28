# Init-Config.ps1 — stage system-scope agent config into the project's
# <projectDir>\.system directory. Dot-sourced (not executed).
#
# Requires (from Agent.ps1):       $agentConfigDir, $agentProjectDir,
#                                  $agentManifest.
# Requires (from Init-Launcher.ps1): $sessionId, $sessionDir.
#
# Sets: $systemDir, $configFiles, $roFiles, $roDirs
#
# Layout (same as lib/init-config.sh):
#
#   $PWD\<projectDir>\.system\
#     ├── ro\                       (shared; wiped + re-copied each launch)
#     ├── rw\                       (shared; wiped + re-linked each launch)
#     ├── .mask\                    (shared; empty dir — masks .system from proj scope)
#     └── sessions\<id>\
#         ├── cr\                       (per-session runtime state; persists)
#         └── owner                     (KV: pid, start, cmd, ppid, ppid_start, ppid_cmd,
#                                          cwd, user, host, created; written by
#                                          lib/Init-Launcher.ps1; legacy
#                                          owner.pid/owner.cmd are still read as a fallback)

# Assert a symlink-resolved path stays under a trusted root: the
# canonical agent config dir ($script:realConfigDir), or any path
# declared in the manifest's `trustedSymlinkRoots` array (canonicalised
# in Agent.ps1 → $script:agentTrustedRoots). C:\Windows\..., /etc/...,
# ~/.ssh, browser tokens etc. all fail by default — the previous
# blanket "all of $HOME" widening let an LLM agent with write access
# to its own config dir plant a junction to any home-resident secret
# and have it staged into the next session. See code-review-handoff.md
# CR-001. To re-enable a known cross-app layout (scoop persist, etc.),
# declare it explicitly in the agent manifest.
#
# Trim trailing separators so '/' vs '/*' comparisons aren't confused
# by path style differences across platforms. Comparison is
# OrdinalIgnoreCase so NTFS's case-insensitive semantics don't cause
# a 'C:\Users\LL' vs 'C:\Users\ll' mismatch on Windows.
$assertUnderConfig = { param($real, $orig)
  $cmp = $real.TrimEnd('/', '\')
  $oic = [StringComparison]::OrdinalIgnoreCase
  $under = {
    param($p)
    if (-not $p) { return $false }
    [string]::Equals($cmp, $p, $oic) -or
      $cmp.StartsWith($p + '/', $oic) -or
      $cmp.StartsWith($p + '\', $oic)
  }
  if (& $under $script:realConfigDir) { return }
  foreach ($trusted in $script:agentTrustedRoots) {
    if (& $under $trusted) { return }
  }
  Write-Log E config fail "manifest entry resolves outside trusted dirs: $orig -> $real (must stay under $($script:realConfigDir) or a manifest-declared trustedSymlinkRoots entry)"
  throw "manifest entry escapes trusted dirs: $orig"
}

$stageRoFile = { param($src, $dest)
  $realInfo = [IO.File]::ResolveLinkTarget($src, $true)
  $real = if ($realInfo) { $realInfo.FullName } else { [IO.Path]::GetFullPath($src) }
  & $assertUnderConfig $real $src
  # Create parent dirs first — manifest validation accepts nested
  # entries like `rules/foo/bar.json`, but Copy would fail if ro/foo/
  # didn't already exist.
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) > $null
  [IO.File]::Copy($real, $dest, $true)
}

$stageRwFile = { param($src, $dest)
  $realInfo = [IO.File]::ResolveLinkTarget($src, $true)
  $real = if ($realInfo) { $realInfo.FullName } else { [IO.Path]::GetFullPath($src) }
  & $assertUnderConfig $real $src
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) > $null
  if ([IO.File]::Exists($dest)) { [IO.File]::Delete($dest) }
  try {
    New-Item -ItemType HardLink -Path $dest -Target $real -ErrorAction Stop > $null
  }
  catch {
    Write-Log E config fail "cannot hardlink $real -> $dest (cross-filesystem?); writable config requires same filesystem for host sync"
    throw "cannot hardlink $real -> $dest"
  }
}

$resolveDir = { param($path)
  $info = [IO.Directory]::ResolveLinkTarget($path, $true)
  if ($info) { $info.FullName } else { [IO.Path]::GetFullPath($path) }
}

# Recursive copy used for manifest-declared roDirs. Dereferences
# symlinks so a symlinked skill dir lands as real content in the
# stage. Each entry's resolved path is gated against the agent
# config root so a junction/symlink to e.g. C:\Windows or /etc can't
# stage host secrets through the sandbox.
#
# $visited threads a HashSet[string] of canonical real-paths we've
# entered through the recursion so a junction/symlink loop within
# the config dir (e.g. `rules/loop -> ..` — passes containment
# because the target is still inside the config dir) doesn't
# stack-overflow. Bash side gets this for free from `find -L`'s
# POSIX-required loop detection; the Windows path needs explicit
# tracking.
#
# Comparer is OrdinalIgnoreCase: NTFS / drvfs are case-insensitive,
# so `C:\Foo` and `C:\foo` are the same target — case-sensitive
# matching would miss that cycle. On a case-sensitive volume the
# trade is over-detection (skip a legit non-cycle that differs only
# in case → a content-staging miss, recoverable) vs under-detection
# (stack overflow → process crash, not recoverable). Fail toward
# the safer mode.
$copyRoDir = { param($src, $dest, $visited)
  if (-not $visited.Add($src)) { return }
  [IO.Directory]::CreateDirectory($dest) > $null
  foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($src)) {
    $name = [IO.Path]::GetFileName($entry)
    $out = [IO.Path]::Combine($dest, $name)
    if ([IO.Directory]::Exists($entry)) {
      $realSub = & $resolveDir $entry
      & $assertUnderConfig $realSub $entry
      & $copyRoDir $realSub $out $visited
    }
    else {
      # $stageRoFile validates the file's real path is under config dir.
      & $stageRoFile $entry $out
    }
  }
}

$initConfigDir = {
  Write-Log I config start "staging $($PWD.Path)\$agentProjectDir\.system"
  if (-not [IO.Directory]::Exists($agentConfigDir)) {
    Write-Log E config fail "$agent config directory not found: $agentConfigDir"
    throw "$agent config directory not found: $agentConfigDir"
  }

  # Canonical agent config root, resolved through any junctions /
  # symlinks. Used by $assertUnderConfig to gate every manifest-
  # supplied entry — without this, a symlink in files.{rw,ro,roDirs}
  # could redirect the stage to arbitrary host files (Test-ManifestPaths
  # in Agent.ps1 only validates the manifest string, not the actual
  # link target on disk).
  $rootInfo = [IO.Directory]::ResolveLinkTarget($agentConfigDir, $true)
  $script:realConfigDir = if ($rootInfo) {
    $rootInfo.FullName
  }
  else {
    [IO.Path]::GetFullPath($agentConfigDir)
  }
  $script:realConfigDir = $script:realConfigDir.TrimEnd('/', '\')

  $script:systemDir = [IO.Path]::Combine($PWD.Path, $agentProjectDir, '.system')

  # Walk upward from $PWD to find the repo top-level: the launcher may
  # run from a subdir of a larger repo (e.g. C:\repo\subproj\), in which
  # case `.system\` is still commit-visible from the parent and the
  # warning must still fire. The previous `$PWD\.git` check missed that.
  # `.git` matches both regular repos (directory) and worktrees /
  # submodules (regular file pointer). See code-review-handoff.md CR-003.
  $gitTop = $null
  $walk = $PWD.Path
  while ($walk) {
    $candidate = [IO.Path]::Combine($walk, '.git')
    if ([IO.Directory]::Exists($candidate) -or [IO.File]::Exists($candidate)) {
      $gitTop = $walk
      break
    }
    $parent = [IO.Path]::GetDirectoryName($walk)
    if ([string]::IsNullOrEmpty($parent) -or $parent -eq $walk) { break }
    $walk = $parent
  }
  if ($gitTop) {
    $gi = [IO.Path]::Combine($gitTop, '.gitignore')
    $hasMatch = $false
    if ([IO.File]::Exists($gi)) {
      $pattern = '(?m)^\s*/?' + [regex]::Escape($agentProjectDir) + '(/(\.system)?/?)?\s*$'
      $hasMatch = [IO.File]::ReadAllText($gi) -match $pattern
    }
    if (-not $hasMatch) {
      Write-Log W config gitignore "$gi does not exclude $agentProjectDir/.system/; add a '$agentProjectDir/.system/' entry to keep credentials and session history out of commits"
    }
  }

  $stageRo = [IO.Path]::Combine($script:systemDir, 'ro')
  $stageRw = [IO.Path]::Combine($script:systemDir, 'rw')
  $stageCr = [IO.Path]::Combine($script:sessionDir, 'cr')
  $stageMask = [IO.Path]::Combine($script:systemDir, '.mask')

  [IO.Directory]::CreateDirectory($stageCr) > $null
  [IO.Directory]::CreateDirectory($stageMask) > $null

  # Wipe ro/ AND rw/ each launch so removing or renaming a
  # files.{rw,ro,roDirs} entry doesn't leave a stale alias pointing at
  # host config — for rw/ specifically that would mean a dropped
  # credentials file remaining hardlinked into the staging tree (and
  # bind-mounted into the sandbox) on subsequent launches. rw/ entries
  # are NTFS hardlinks; deleting them decrements the inode's link
  # count without touching the host original. Remove-Item -Force
  # clears read-only attributes before deleting; [IO.Directory]::Delete
  # throws on read-only files (a copied ro config that preserved the
  # attribute would otherwise wedge the rebuild on Windows).
  foreach ($stage in @($stageRo, $stageRw)) {
    if ([IO.Directory]::Exists($stage)) {
      Remove-Item -LiteralPath $stage -Recurse -Force
    }
    [IO.Directory]::CreateDirectory($stage) > $null
  }

  $script:configFiles = [Collections.Generic.List[string]]::new()
  foreach ($f in (Get-AgentList '.files.rw')) {
    $src = [IO.Path]::Combine($agentConfigDir, $f)
    if ([IO.File]::Exists($src)) {
      $script:configFiles.Add($f)
      & $stageRwFile $src ([IO.Path]::Combine($stageRw, $f))
    }
  }

  $script:roFiles = [Collections.Generic.List[string]]::new()
  foreach ($f in (Get-AgentList '.files.ro')) {
    $src = [IO.Path]::Combine($agentConfigDir, $f)
    if ([IO.File]::Exists($src)) {
      $script:roFiles.Add($f)
      & $stageRoFile $src ([IO.Path]::Combine($stageRo, $f))
    }
  }

  $script:roDirs = [Collections.Generic.List[string]]::new()
  foreach ($d in (Get-AgentList '.files.roDirs')) {
    $srcDir = [IO.Path]::Combine($agentConfigDir, $d)
    if (-not [IO.Directory]::Exists($srcDir)) { continue }
    $realSrcDir = & $resolveDir $srcDir
    & $assertUnderConfig $realSrcDir $d
    $script:roDirs.Add($d)
    # Fresh visited-set per top-level roDirs entry so two unrelated
    # entries don't share state (an unlikely but real concern: if `rules`
    # and `commands` are siblings, walking `rules` shouldn't pre-block
    # `commands`).
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    & $copyRoDir $realSrcDir ([IO.Path]::Combine($stageRo, $d)) $visited
  }

  $crPlaceholders = @($script:configFiles) + @($script:roFiles)
  foreach ($f in $crPlaceholders) {
    $p = [IO.Path]::Combine($stageCr, $f)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)) > $null
    if (-not [IO.File]::Exists($p)) { [IO.File]::WriteAllText($p, '') }
  }
  foreach ($d in $script:roDirs) {
    [IO.Directory]::CreateDirectory([IO.Path]::Combine($stageCr, $d)) > $null
  }
  Write-Log I config done "session=$($script:sessionId) rw=$($script:configFiles.Count) ro-files=$($script:roFiles.Count) ro-dirs=$($script:roDirs.Count)"
}
