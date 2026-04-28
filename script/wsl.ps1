param(
  [string]$Agent = 'claude',
  [string]$BaseHash = '',
  [string]$ToolHash = '',
  [string]$AgentHash = '',
  [switch]$ForcePull,
  [string]$Image = 'fedora:latest',
  [switch]$AllowDnf,
  [switch]$NewSession,
  [string]$Session = '',
  [ValidateSet('I', 'W', 'E')][string]$LogLevel = 'W'
)
$ErrorActionPreference = 'Stop'
if ($NewSession -and $Session) {
  throw '-NewSession and -Session are mutually exclusive'
}

# Re-exec into a child pwsh — same rationale as podman-container.ps1's
# fork prelude. The bash backend forks naturally (subshell pid); .ps1
# scripts don't, so without this the child of $PID lookup in
# $captureCtx returns the user's wt.exe / conhost instead of the
# interactive pwsh, breaking tab-isolated reclaim. After fork, $PID is
# the launch's own pwsh and ParentProcessId is the user's pwsh — the
# bash-equivalent (pid, ppid) pairing.
if (-not $env:CRATE_LAUNCHER_FORKED) {
  $fwd = @()
  foreach ($k in $PSBoundParameters.Keys) {
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) {
      if ($v.IsPresent) { $fwd += "-$k" }
    }
    else {
      $fwd += "-$k"
      $fwd += [string]$v
    }
  }
  $env:CRATE_LAUNCHER_FORKED = '1'
  try {
    & pwsh -NoProfile -NoLogo -File $PSCommandPath @fwd
    $childExit = $LASTEXITCODE
  }
  finally {
    Remove-Item env:CRATE_LAUNCHER_FORKED -ErrorAction SilentlyContinue
  }
  if ($childExit -ne 0) { throw "launcher exited with code $childExit" }
  return
}
Remove-Item env:CRATE_LAUNCHER_FORKED -ErrorAction SilentlyContinue

$LogLevel = $LogLevel.ToUpperInvariant()
$script:LogLevel = $LogLevel

$scriptDir = $PSScriptRoot
$projectRoot = [IO.Path]::GetDirectoryName($scriptDir)
$agent = $Agent
. "$projectRoot\lib\Init-Launcher.ps1"
. "$projectRoot\lib\Build-Image.ps1"

$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optAgentHash = $AgentHash
$forcePull = $ForcePull.IsPresent
$distroName = $null
$sessionTempDir = $null
$stateFile = $null

# State dir: each launch writes "<distroName>.distro" with `pid`,
# `start` (process start time as a stable Int64), and `cmd` (cmdline)
# as KV lines. A future launch reclaims any distro whose owner is no
# longer the same live process — pid alone is insufficient on
# long-uptime hosts where the OS can reuse the recorded pid for an
# unrelated process. The 3-field tuple (pid + start + cmd) is unique
# per process lifetime, mirroring the session-owner liveness check in
# lib/Init-Launcher.ps1.
$stateDir = [IO.Path]::Combine($env:LocalAppData, 'crate', 'distros')
[IO.Directory]::CreateDirectory($stateDir) > $null

# Returns $true if the named distro is currently registered with WSL.
# `wsl --list --quiet` writes UTF-16LE on some hosts, so normalize line
# endings + nulls before comparing. NOTE: `return` inside ForEach-Object
# only exits the script block, not the function — the original
# `... | ForEach-Object { return $true }` form yields mixed pipeline
# output and falls through to `return $false`. Use `-contains` against
# the trimmed list directly so the function is unambiguously boolean.
function Test-WslDistroRegistered([string]$Name) {
  $list = (wsl --list --quiet 2>$null) -join "`n"
  if (-not $list) { return $false }
  $list = $list -replace "`0", '' -replace "`r", ''
  $names = $list -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  return [bool]($names -contains $Name)
}

# Reclaim distros whose launcher process is no longer alive (kill -9,
# reboot) OR whose pid has been reused by an unrelated process. The
# marker is a KV file with `pid`, `start`, and `cmd`. A distro is
# "still owned" iff: pid is alive AND its current start time matches
# the recorded one AND its current cmdline matches the recorded one.
# Anything else → abandoned. Legacy markers (single-line pid, no
# `start=`) fall back to pid-only liveness.
#
# Use a distinct loop variable ($staleMarker) — `foreach` in PowerShell
# does NOT scope its iterator, so reusing $stateFile here would leak
# the last-scanned marker path into outer scope and the launch's
# `finally` block could delete a marker for a leak that wasn't
# actually cleaned up if the launch fails before line ~104 sets
# $stateFile to the current run's marker.
foreach ($staleMarker in [IO.Directory]::EnumerateFiles($stateDir, '*.distro')) {
  $ownerPid = & $ownerGet $staleMarker 'pid'
  $ownerStart = & $ownerGet $staleMarker 'start'
  $ownerCmd = & $ownerGet $staleMarker 'cmd'
  if (-not $ownerPid) {
    # Legacy single-line marker: first line is the pid, no KV pairs.
    $legacy = & $readFirstLine $staleMarker
    if ($legacy -match '^\d+$') { $ownerPid = $legacy }
  }
  $alive = $false
  if ($ownerPid -match '^\d+$' -and (& $pidAlive ([int]$ownerPid))) {
    if ($ownerStart) {
      $curStart = & $pidStart ([int]$ownerPid)
      $curCmd = & $pidCmdline ([int]$ownerPid)
      if ($curStart -eq $ownerStart -and $curCmd -eq $ownerCmd) {
        $alive = $true
      }
    }
    else {
      $alive = $true
    }
  }
  if (-not $alive) {
    $abandoned = [IO.Path]::GetFileNameWithoutExtension($staleMarker)
    Write-Log W distro reclaim "removing abandoned distro '$abandoned' (owner pid '$ownerPid' not alive)"
    wsl --terminate $abandoned 2>$null
    wsl --unregister $abandoned 2>$null
    $abandonedDir = [IO.Path]::Combine($env:LocalAppData, $abandoned)
    $dirGone = $true
    if ([IO.Directory]::Exists($abandonedDir)) {
      try { [IO.Directory]::Delete($abandonedDir, $true) } catch { $dirGone = $false }
      if ([IO.Directory]::Exists($abandonedDir)) { $dirGone = $false }
    }
    # Only drop the marker once both the distro and its backing dir are
    # actually gone — otherwise the next launch loses its only handle on
    # the leak.
    if ((Test-WslDistroRegistered $abandoned) -or -not $dirGone) {
      Write-Log E distro reclaim-fail "distro '$abandoned' or its backing dir still present after teardown; state file preserved at $staleMarker for retry on next launch"
    }
    else {
      try { [IO.File]::Delete($staleMarker) } catch {}
    }
  }
}

try {
  $optNewSession = $NewSession.IsPresent
  $optSessionId = $Session
  . $initLauncher

  # ── WSL distro ──
  #
  # Every launch imports a fresh distro and the finally block below
  # unregisters it on exit — no reuse across sessions.

  # Reuse the launcher's resolved $sessionId (8-char base36, set by
  # Init-Launcher.ps1 → $resolveSessionId) as the distro identity, so
  # backend name and session config dir share one id. Format:
  # `crate-<agent>-<sessionId>` (≤21 chars).
  $distroName = "crate-$agent-$sessionId"
  $distroDir = "$env:LocalAppData\$distroName"

  # Register this distro before --import: if import fails, the finally
  # below removes the half-created distro AND this state file together.
  # KV format with pid + start + cmd so a future launch can detect both
  # kill-9 leaks and PID-reuse on long-uptime hosts. cmd is collapsed
  # to a single line so the KV reader stays valid.
  $stateFile = [IO.Path]::Combine($stateDir, "$distroName.distro")
  $startTok = & $pidStart $PID
  $cmdTok = (& $pidCmdline $PID).Replace("`r", '').Replace("`n", ' ')
  [IO.File]::WriteAllText($stateFile, "pid=$PID`nstart=$startTok`ncmd=$cmdTok`n")

  # Per-session temp dir so parallel launches don't overwrite each other's
  # staging files (base.tar, the LF-normalized .sh copies). Cleaned in the
  # finally below.
  $sessionTempDir = [IO.Path]::Combine($env:TEMP, "crate-$sessionId")
  [IO.Directory]::CreateDirectory($sessionTempDir) > $null

  . $buildBaseImage
  $baseTar = [IO.Path]::Combine($sessionTempDir, 'base.tar')
  Write-Log I distro export "$imageTag -> $baseTar"
  $exportCtr = (Invoke-Must podman container create $imageTag true)
  try {
    Invoke-Must podman container export $exportCtr -o $baseTar
  }
  finally {
    podman container rm $exportCtr 2>$null
  }

  [IO.Directory]::CreateDirectory($distroDir) > $null
  try {
    Write-Log I distro import $distroName
    Invoke-Must wsl --import $distroName $distroDir $baseTar
  }
  finally {
    [IO.File]::Delete($baseTar)
  }

  # Stage shell scripts to $sessionTempDir with CRLF→LF normalization. A
  # Windows checkout with `core.autocrlf=true` leaves '\r' at line ends
  # in the file; `sh` then chokes on the carriage returns. $lfOnly
  # collapses CRLF pairs only — bare `\r` inside content is preserved
  # in case it carries meaning (escape sequences, embedded bytes).
  $writeLf = { param([string]$src, [string]$basename)
    $dest = [IO.Path]::Combine($sessionTempDir, $basename)
    [IO.File]::WriteAllText($dest, (& $lfOnly ([IO.File]::ReadAllText($src))))
    $dest
  }

  Write-Log I archive inject "base+tool+$agent tarballs"
  $wslSetup = & $wslSrc (& $writeLf "$projectRoot\bin\setup-tools.sh" 'setup-tools.sh')
  $wslArchives = @()
  foreach ($archive in $baseArchive, $toolArchive, $agentArchive) {
    $wslArchives += & $wslSrc $archive
  }
  # Run as `agent` (uid 24368, baked into the imported image) — NOT
  # root. Running as root would leave /home/agent/.local/{bin,lib}
  # root-owned, breaking any in-session install or generated shim that
  # writes back into $HOME/.local. Container/podman-machine backends
  # already extract under the runtime user; match that here.
  Invoke-Must wsl -d $distroName -u agent -- env AGENT_BIN_DIR=/home/agent/.local/bin AGENT_LIB_DIR=/home/agent/.local/lib sh $wslSetup --log-level $LogLevel @wslArchives

  # Bake setup-system-mounts.sh into the distro at a stable path.
  # Must happen here (while /mnt/c is still automounted) because
  # wsl.conf below disables automount.
  $wslSetupSys = & $wslSrc (& $writeLf "$projectRoot\bin\setup-system-mounts.sh" 'setup-system-mounts.sh')
  Invoke-Must wsl -d $distroName -u root -- cp $wslSetupSys /usr/local/libexec/crate/setup-system-mounts.sh
  Invoke-Must wsl -d $distroName -u root -- chmod +x /usr/local/libexec/crate/setup-system-mounts.sh

  # Stage wsl.conf through $writeLf too — WSL's parser is forgiving of
  # CRLF in practice, but the script-owns-EOL principle says we
  # normalize before crossing into the distro instead of trusting how
  # the file landed on disk.
  $wslConf = & $wslSrc (& $writeLf "$projectRoot\config\wsl.conf" 'wsl.conf')
  Invoke-Must wsl -d $distroName -u root -- cp $wslConf /etc/wsl.conf
  wsl --terminate $distroName 2>$null

  # ── Mount and configure ──

  # Mount the Windows workdir into the distro via drvfs with metadata.
  #
  # metadata/uid/gid/umask/fmask are required for Linux mode bits and
  # ownership to persist on a Windows-backed mount (the default drvfs
  # mount ignores chmod/chown silently, which makes codex's
  # set_permissions(0o600) calls return EPERM and crash TUI bootstrap).
  # uid/gid match the agent user pinned by the Containerfile (24368).
  Write-Log I distro mount "$($PWD.Path) -> /var/workdir"
  $winWorkdir = $PWD.Path
  # $lfOnly defends against a CRLF source file (Windows checkout); the
  # multi-line literal would otherwise carry `\r` bytes into sh -c and
  # trigger `$'\r': command not found` on each line break.
  $mountCmd = & $lfOnly @"
mkdir -p /var/workdir &&
mount -t drvfs -o metadata,uid=24368,gid=24368,umask=0022,fmask=0022 '$($winWorkdir.Replace("'", "'\''"))' /var/workdir
"@
  Invoke-Must wsl -d $distroName -u root -- sh -c $mountCmd

  Write-Log I mounts assemble "$crateDir"
  # Encode each list as base64 of NUL-delimited UTF-8 — survives wsl.exe
  # argv marshalling AND lets the receiver split on NUL so filenames
  # containing spaces/quotes/newlines round-trip exactly. Empty list ⇒
  # empty string.
  $toNulB64 = {
    param([string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    $ms = [System.IO.MemoryStream]::new()
    foreach ($s in $Items) {
      $b = [Text.Encoding]::UTF8.GetBytes($s)
      $ms.Write($b, 0, $b.Length)
      $ms.WriteByte(0)
    }
    [Convert]::ToBase64String($ms.ToArray())
  }
  $cfB64 = & $toNulB64 ([string[]]$configFiles)
  $rfB64 = & $toNulB64 ([string[]]$roFiles)
  $rdB64 = & $toNulB64 ([string[]]$roDirs)
  Invoke-Must wsl -d $distroName -u root -- `
    /usr/local/libexec/crate/setup-system-mounts.sh `
    --log-level $LogLevel `
    --workdir /var/workdir `
    --project-dir $agentProjectDir `
    --session-id $sessionId `
    --target $crateDir `
    --config-files $cfB64 `
    --ro-files $rfB64 `
    --ro-dirs $rdB64

  # ── Launch ──

  $envArgs = ''
  if ($AllowDnf) { $envArgs = 'CRATE_ALLOW_DNF=1' }

  Write-Log I run launch "wsl -d $distroName ($agent)"
  $launchCmd = & $lfOnly "exec env $envArgs `$HOME/.local/bin/$agentBinary --log-level $LogLevel"
  Invoke-Must wsl -d $distroName --cd /var/workdir -- sh -c $launchCmd
}
finally {
  $teardownOk = $true
  if ($distroName) {
    Write-Log I distro teardown $distroName
    try { wsl --terminate $distroName 2>$null } catch {}
    try { wsl --unregister $distroName 2>$null } catch {}
    if (Test-WslDistroRegistered $distroName) { $teardownOk = $false }
    if ($distroDir -and [IO.Directory]::Exists($distroDir)) {
      try { [IO.Directory]::Delete($distroDir, $true) } catch {}
      if ([IO.Directory]::Exists($distroDir)) { $teardownOk = $false }
    }
  }
  if ($stateFile -and [IO.File]::Exists($stateFile)) {
    if ($teardownOk) {
      try { [IO.File]::Delete($stateFile) } catch {}
    }
    else {
      Write-Log E distro teardown-fail "distro '$distroName' or its backing dir still present after teardown; state file preserved at $stateFile for retry on next launch"
    }
  }
  if ($sessionTempDir -and [IO.Directory]::Exists($sessionTempDir)) {
    try { [IO.Directory]::Delete($sessionTempDir, $true) } catch {}
  }
}
