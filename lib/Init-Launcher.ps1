# Init-Launcher.ps1 — shared launcher initialization (multi-agent).
# Dot-sourced (not executed). Requires: $projectRoot, $agent (set by caller).
#
# Sources Agent.ps1, Init-Config.ps1, Tools.ps1. Provides $initLauncher
# which runs credential check, config init, arch detection, and
# tool archive build.
#
# Also provides:
#   Invoke-Must — run a native command and throw on non-zero exit
#   $wslSrc     — convert a Windows path to a WSL absolute path

function Invoke-Must {
  $cmd = $args[0]
  $cmdArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
  & $cmd @cmdArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed (exit $LASTEXITCODE): $cmd $($cmdArgs -join ' ')"
  }
}

# Log.ps1 first so every downstream lib can call Write-Log. Common.ps1
# (cross-cutting constants like $crateUserAgent) loads next so Tools.ps1
# can reference them.
. "$projectRoot\lib\Log.ps1"
. "$projectRoot\lib\Common.ps1"
. "$projectRoot\lib\Session.ps1"
. "$projectRoot\lib\Agent.ps1"
. "$projectRoot\lib\Init-Config.ps1"
. "$projectRoot\lib\Tools.ps1"

# Convert a Windows host path to a WSL `/mnt/<drive>/...` path. Only
# drive-letter paths are supported: drvfs auto-mounts drive letters
# under /mnt, but UNC shares (`\\server\share`, `\\wsl$\...`,
# `\\?\C:\...`) are NOT auto-mounted and would need per-share `mount -t
# drvfs` plumbing inside the distro to be reachable. Run the launcher
# from a drive-letter working directory and keep the CRATE checkout
# under one too. See README "Windows path requirements".
$wslSrc = { param($p)
  $abs = [IO.Path]::GetFullPath($p)
  if ($abs.Length -lt 3 -or $abs[1] -ne ':') {
    throw "Windows-side path '$abs' is not a drive-letter path; CRATE on WSL only supports drive-letter paths (UNC and \\wsl$ paths are not auto-mounted into the distro). Move the working directory and the CRATE checkout to a drive-letter location (e.g. C:\\)."
  }
  '/mnt/' + $abs.Substring(0, 1).ToLower() + $abs.Substring(2).Replace('\', '/')
}

# SELinux probe — mirrors script/podman-container.sh. Only meaningful
# when pwsh is running on a Linux host (PowerShell Core); on Windows/
# macOS the checks fall through and $selinuxOpt stays empty. Build-
# Image.ps1 and the container launcher splat $selinuxOpt into their
# `podman image build` / `podman container run` invocations so SELinux
# label denial does not break access to the bind-mounted workdir.
$selinuxOpt = @()
if ($IsLinux) {
  $_seState = $null
  if (Get-Command getenforce -ErrorAction SilentlyContinue) {
    try { $_seState = (& getenforce 2>$null | Select-Object -First 1).Trim() } catch {}
  }
  elseif ([IO.File]::Exists('/sys/fs/selinux/enforce')) {
    $_raw = & $readFirstLine '/sys/fs/selinux/enforce'
    if ($_raw -eq '1') { $_seState = 'Enforcing' }
    elseif ($_raw -eq '0') { $_seState = 'Permissive' }
  }
  if ($_seState -and $_seState -ne 'Disabled') {
    $selinuxOpt = @('--security-opt', 'label=disable')
    Write-Log I launcher selinux "detected $_seState; using --security-opt label=disable"
  }
}

# 8 chars base36 → 36^8 ≈ 2.82e12. Mirror of _gen_session_id in
# lib/init-launcher.sh. Source: 6 bytes RNG → bigint → modulo 36^8 →
# fixed 8-iteration encode loop. Modulo is the fix for the prior
# truncation bug (taking Substring(0,8) of a 9-10 digit base36 string
# discarded low-order entropy and skewed the leading digits).
$genSessionId = {
  $bytes = [byte[]]::new(6)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  $n = [bigint]0
  foreach ($b in $bytes) { $n = ($n -shl 8) -bor $b }
  $n = $n % [bigint]2821109907456    # 2821109907456 = 36^8
  $alpha = '0123456789abcdefghijklmnopqrstuvwxyz'
  $chars = [char[]]::new(8)
  for ($i = 7; $i -ge 0; $i--) {
    $chars[$i] = $alpha[[int]($n % 36)]
    $n = $n / 36
  }
  -join $chars
}

# $pidCmdline, $pidStart, $ownerGet, $ownerAlive live in
# lib/Session.ps1 — shared with script/List-Sessions.ps1.

# Capture the launcher's "context" — the 6 attributes used both to tag
# a fresh session and to look up an existing one to reclaim.
# Same shell tab + same project + same user → identical ctx across
# re-launches, which is what makes default reclaim re-attach
# deterministically. Different tab / new login / moved project → at
# least one field changes → fall through to fresh id.
$captureCtx = {
  $script:ctxPpid = 0
  try {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    if ($cim) { $script:ctxPpid = [int]$cim.ParentProcessId }
  }
  catch {}
  $script:ctxPpidStart = & $pidStart $script:ctxPpid
  $script:ctxPpidCmd = & $pidCmdline $script:ctxPpid
  $script:ctxCwd = $PWD.Path
  $script:ctxUser = [Environment]::UserName
  $script:ctxHost = [Environment]::MachineName
}

# Atomic write of the unified `owner` metadata file. One `key=value`
# per line. Newlines in values are collapsed to spaces so the KV
# format stays parsable. Caller must have populated the $script:ctx*
# vars via $captureCtx first AND must hold the session's .lock file,
# since this is a read-modify-write of the existing owner file.
#
# `start` is the launcher's own process start token, recorded so
# liveness can require pid + start + cmd — same 3-field identity the
# VM/distro state markers already use to defeat PID reuse.
#
# `created` is the first-claim epoch, preserved across reclaim so it
# stays the session's birth time — used as the within-tier tiebreak
# in $reclaimSession ("oldest matching session wins"). A missing
# `created` (legacy session pre-dating this field) is treated as 0
# on read, sorting oldest-first so legacy sessions drain cleanly.
$writeOwnerFile = { param([string]$Path)
  $ownPid = $PID
  $ownStart = & $pidStart $ownPid
  $ownCmd = (& $pidCmdline $ownPid).Replace("`r", '').Replace("`n", ' ')
  $ppidCmdSafe = $script:ctxPpidCmd.Replace("`r", '').Replace("`n", ' ')
  $created = if ([IO.File]::Exists($Path)) { & $ownerGet $Path 'created' } else { '' }
  if (-not $created) { $created = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
  $sb = [Text.StringBuilder]::new(512)
  [void]$sb.Append("pid=$ownPid`n")
  [void]$sb.Append("start=$ownStart`n")
  [void]$sb.Append("cmd=$ownCmd`n")
  [void]$sb.Append("ppid=$($script:ctxPpid)`n")
  [void]$sb.Append("ppid_start=$($script:ctxPpidStart)`n")
  [void]$sb.Append("ppid_cmd=$ppidCmdSafe`n")
  [void]$sb.Append("cwd=$($script:ctxCwd)`n")
  [void]$sb.Append("user=$($script:ctxUser)`n")
  [void]$sb.Append("host=$($script:ctxHost)`n")
  [void]$sb.Append("created=$created`n")
  $tmp = "$Path.tmp.$([Guid]::NewGuid().ToString('N'))"
  [IO.File]::WriteAllText($tmp, $sb.ToString())
  [IO.File]::Move($tmp, $Path, $true)
}

# True iff the session at $Dir has an alive owner. Reads the unified
# `owner` KV file first, falling back to legacy owner.pid + owner.cmd
# (which predates start recording — $ownerAlive falls back to pid+cmd
# in that case).
$sessionAlive = { param([string]$Dir)
  $owner = [IO.Path]::Combine($Dir, 'owner')
  $opid = 0; $ostart = ''; $ocmd = ''
  if ([IO.File]::Exists($owner)) {
    $p = & $ownerGet $owner 'pid'
    if ($p -match '^\d+$') { $opid = [int]$p }
    $ostart = & $ownerGet $owner 'start'
    $ocmd = & $ownerGet $owner 'cmd'
  }
  else {
    $opidFile = [IO.Path]::Combine($Dir, 'owner.pid')
    $ocmdFile = [IO.Path]::Combine($Dir, 'owner.cmd')
    $line = & $readFirstLine $opidFile
    if ($line -match '^\d+$') { $opid = [int]$line }
    if ([IO.File]::Exists($ocmdFile)) {
      try { $ocmd = [IO.File]::ReadAllText($ocmdFile) } catch {}
    }
  }
  return (& $ownerAlive $opid $ostart $ocmd)
}

# Compute the reclaim "match tier" of a session against the current
# launcher's $script:ctx* (must be populated). Lower tier = stronger
# match; mirrors _session_match_tier in lib/init-launcher.sh.
#
# Field stability ladder (most-stable → most-volatile):
#   host  > user  > cwd  > ppid_cmd  > ppid_start  > ppid
# The rightmost mismatch determines the tier.
#
#   1 — exact (all six match — same shell instance / same tab)
#   2 — only ppid mismatch (parallel launches w/ identical ctx; rare)
#   3 — + ppid_start mismatch (closed tab, opened a new one running
#       the same shell program in the same project)
#   4 — + ppid_cmd mismatch (different shell program — pwsh↔cmd, or
#       different terminal host — same project / user / host)
#   5 — cwd mismatch (project directory was moved or renamed)
#   6 — user mismatch (cross-user reclaim; runtime state from another
#       login flows into your sandbox — see README)
#   7 — host mismatch (cross-host reclaim, e.g. project on a network
#       share — see README)
#
# Sessions without an `owner` file (legacy / corrupt) tier to 7.
$sessionMatchTier = { param([string]$Dir)
  $owner = [IO.Path]::Combine($Dir, 'owner')
  if (-not [IO.File]::Exists($owner)) { return 7 }
  if ((& $ownerGet $owner 'host') -ne $script:ctxHost) { return 7 }
  if ((& $ownerGet $owner 'user') -ne $script:ctxUser) { return 6 }
  if ((& $ownerGet $owner 'cwd') -ne $script:ctxCwd) { return 5 }
  if ((& $ownerGet $owner 'ppid_cmd') -ne $script:ctxPpidCmd) { return 4 }
  if ((& $ownerGet $owner 'ppid_start') -ne $script:ctxPpidStart) { return 3 }
  if ((& $ownerGet $owner 'ppid') -ne [string]$script:ctxPpid) { return 2 }
  return 1
}

# Atomic claim of a session by id. Mirror of _try_claim_session in
# lib/init-launcher.sh. The exclusivity primitive is FileMode.CreateNew
# on a `.lock` file, which atomically fails (IOException) if the file
# already exists — drvfs (WSL2), NTFS, and POSIX FS all honor this.
# Stale-lock recovery: a lock older than 30s is treated as held by a
# dead claimer.
#
# After winning the lock, liveness is checked via pid + start + cmdline
# (see $ownerAlive) so a recycled pid does not block reclaim. On success we
# write the unified `owner` file and drop any legacy owner.pid /
# owner.cmd artifacts. Caller must have run $captureCtx first.
#
# Returns $true if claimed, $false if another launcher owns it.
$tryClaimSession = { param([string]$Id, [string]$SDir)
  $dir = [IO.Path]::Combine($SDir, $Id)
  [IO.Directory]::CreateDirectory($dir) > $null
  $lock = [IO.Path]::Combine($dir, '.lock')

  $acquired = $false
  try {
    $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    $fs.Close()
    $acquired = $true
  }
  catch [IO.IOException] {
    if ([IO.File]::Exists($lock)) {
      $age = (Get-Date) - [IO.File]::GetLastWriteTime($lock)
      if ($age.TotalSeconds -gt 30) {
        try { [IO.File]::Delete($lock) } catch {}
        try {
          $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
          $fs.Close()
          $acquired = $true
        }
        catch {}
      }
    }
  }
  if (-not $acquired) { return $false }

  try {
    if (& $sessionAlive $dir) { return $false }
    & $writeOwnerFile ([IO.Path]::Combine($dir, 'owner'))
    foreach ($legacy in @('owner.pid', 'owner.cmd')) {
      $lf = [IO.Path]::Combine($dir, $legacy)
      if ([IO.File]::Exists($lf)) {
        try { [IO.File]::Delete($lf) } catch {}
      }
    }
    return $true
  }
  finally {
    try { [IO.File]::Delete($lock) } catch {}
  }
}

# Walk all session dirs and atomically claim the best-matching
# abandoned one. Score each candidate via $sessionMatchTier (1-7;
# lower = more specific) and break ties on `created` ascending —
# oldest matching session wins because long-lived sessions
# accumulate more agent context (history, mutable settings) and are
# the more likely "main thread of work" to resume. Race-safe:
# parallel reclaims of the same id are mediated by
# $tryClaimSession's lock.
#
# Returns the reclaimed id or $null only when every session in the
# directory is currently live (tier 7 is the catch-all match).
$reclaimSession = { param([string]$Dir)
  if (-not [IO.Directory]::Exists($Dir)) { return $null }
  $candidates = [Collections.Generic.List[object]]::new()
  foreach ($entry in [IO.Directory]::EnumerateDirectories($Dir)) {
    if (& $sessionAlive $entry) { continue }
    $tier = & $sessionMatchTier $entry
    $owner = [IO.Path]::Combine($entry, 'owner')
    $createdRaw = if ([IO.File]::Exists($owner)) { & $ownerGet $owner 'created' } else { '' }
    $createdN = [int64]0
    [void][int64]::TryParse($createdRaw, [ref]$createdN)
    $candidates.Add([pscustomobject]@{
        Tier    = [int]$tier
        Created = $createdN
        Id      = [IO.Path]::GetFileName($entry)
      })
  }
  if ($candidates.Count -eq 0) { return $null }
  foreach ($c in ($candidates | Sort-Object Tier, Created)) {
    if (& $tryClaimSession $c.Id $Dir) { return $c.Id }
  }
  return $null
}

# Resolve $script:sessionId via three modes (caller sets $optSessionId
# and/or $optNewSession; mutually exclusive):
#   $optSessionId  → claim that id (must not be live)
#   $optNewSession → generate fresh id
#   neither        → reclaim the best-matching abandoned session under
#                    the 7-tier match ladder (see $sessionMatchTier);
#                    within a tier, oldest `created` wins. Tier 7 is
#                    the catch-all so any abandoned session in the
#                    workdir will be reclaimed in default mode — pass
#                    -NewSession to force a fresh id.
# A session is "abandoned" when its recorded pid is dead OR the process
# at that pid no longer matches the recorded start + cmd (PID reuse).
$resolveSessionId = {
  $sessionsDir = [IO.Path]::Combine($PWD.Path, $agentProjectDir, '.system', 'sessions')
  [IO.Directory]::CreateDirectory($sessionsDir) > $null
  . $captureCtx

  if ($optSessionId) {
    if ($optSessionId -notmatch '^[0-9a-z]{8}$') {
      Write-Log E launcher arg-parse "-Session ID must be 8 lowercase base36 chars (0-9a-z): '$optSessionId'"
      throw "invalid -Session id"
    }
    $script:sessionId = $optSessionId
    if (-not (& $tryClaimSession $script:sessionId $sessionsDir)) {
      $owner = [IO.Path]::Combine($sessionsDir, $script:sessionId, 'owner')
      $line = & $ownerGet $owner 'pid'
      if (-not $line) {
        $line = & $readFirstLine ([IO.Path]::Combine($sessionsDir, $script:sessionId, 'owner.pid'))
      }
      if (-not $line) { $line = '?' }
      Write-Log E launcher session-busy "session '$($script:sessionId)' is in use by pid $line; pass -NewSession for a fresh one or omit -Session to reclaim the best-matching abandoned session"
      throw "session busy"
    }
    Write-Log I launcher session "claim $($script:sessionId) (explicit)"
  }
  elseif ($optNewSession) {
    # Generate + atomic-claim. Re-roll on the vanishingly unlikely
    # collision (36^8 space, parallel launches racing).
    $script:sessionId = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
      $candidate = & $genSessionId
      if (& $tryClaimSession $candidate $sessionsDir) {
        $script:sessionId = $candidate
        break
      }
    }
    if (-not $script:sessionId) {
      Write-Log E launcher session-fail "could not claim a fresh session id after 5 attempts (filesystem locked?)"
      throw "session-fail"
    }
    Write-Log I launcher session "new $($script:sessionId) (-NewSession)"
  }
  else {
    $reclaimed = & $reclaimSession $sessionsDir
    if ($reclaimed) {
      $script:sessionId = $reclaimed
      Write-Log I launcher session "reclaim $($script:sessionId)"
    }
    else {
      $script:sessionId = $null
      for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $candidate = & $genSessionId
        if (& $tryClaimSession $candidate $sessionsDir) {
          $script:sessionId = $candidate
          break
        }
      }
      if (-not $script:sessionId) {
        Write-Log E launcher session-fail "could not claim a fresh session id after 5 attempts (filesystem locked?)"
        throw "session-fail"
      }
      Write-Log I launcher session "new $($script:sessionId) (no abandoned session to reclaim)"
    }
  }
  $script:sessionDir = [IO.Path]::Combine($sessionsDir, $script:sessionId)
}

# Preflight on Windows: every host path that crosses into the WSL
# distro/podman container goes through $wslSrc, which only handles
# drive-letter paths. Validate the user-controlled roots up front so a
# UNC working directory fails BEFORE we import a distro or pull
# tarballs, instead of mid-bootstrap.
$preflightWslPaths = {
  if (-not $IsWindows) { return }
  foreach ($p in @($PWD.Path, $projectRoot, $cacheDir)) {
    if (-not $p) { continue }
    $abs = [IO.Path]::GetFullPath($p)
    if ($abs.Length -lt 3 -or $abs[1] -ne ':') {
      Write-Log E launcher fail "host path '$abs' is not a drive-letter path; CRATE on Windows only supports drive-letter paths (UNC and \\wsl$ paths are not auto-mounted into the distro). See README 'Windows path requirements'."
      throw "non-drive-letter host path: $abs"
    }
  }
}

$initLauncher = {
  Invoke-AgentLoad
  Write-Log I launcher start "CRATE ($agent) $($MyInvocation.ScriptName)"
  . $preflightWslPaths
  & "$projectRoot\script\Ensure-Credential.ps1" -Agent $agent -LogLevel $script:LogLevel
  . $resolveSessionId
  . $initConfigDir
  . $detectArch
  . $buildToolArchives
}
