# List-Sessions.ps1 — enumerate CRATE sessions in the current working
# directory across all known agents, or one if `-Agent NAME` is given.
# Mirror of script/list-sessions.sh. Liveness uses the shared
# $ownerAlive helper (pid + start + cmdline match) so the displayed
# `state` matches launcher reclaim semantics — start defeats PID reuse
# on long-uptime hosts where the OS pid space wraps and a recycled pid
# could otherwise be tagged `alive` by a pid-only or pid+cmd check.
#
# Output formatting goes through Format-Table -AutoSize so column
# widths track the actual data — no hand-rolled width table.
#
# Parameter binding leans on PowerShell's built-in attributes:
#   - [string[]]$Columns lets the caller pass a native array
#     (`-Columns id,agent,age,cwd`); PS auto-splits the comma list.
#   - [ValidateSet] enforces the allowed column names per-element and
#     surfaces tab completion + a standard "not in the set" error,
#     so we don't hand-roll validation or an "available:" message.
param(
  [string]$Agent = '',
  [ValidateSet('id', 'agent', 'state', 'pid', 'cmd', 'ppid', 'ppid_start', 'ppid_cmd', 'cwd', 'user', 'host', 'created', 'age')]
  [string[]]$Columns = @('id', 'agent', 'age', 'cwd')
)
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = [IO.Path]::GetDirectoryName($scriptDir)

# Reuse the shared `owner` KV reader instead of re-implementing — the
# launcher's PS init also dot-sources this file.
. "$projectRoot\lib\Session.ps1"

# Bulk-fetch the process tables once and override Session.ps1's per-pid
# helpers with hashtable-backed lookups. Without this, every session
# row would trigger its own Get-CimInstance Win32_Process (50-200ms
# each on cold WMI), turning an N-session listing into N×WMI roundtrips
# — the dominant cost on a typical 6-session workdir.
#
# Two snapshots:
#   Get-CimInstance Win32_Process — for CommandLine (no .NET equivalent
#     surfaces argv).
#   [Diagnostics.Process]::GetProcesses() — for liveness + StartTime
#     (faster than WMI for these two fields, and StartTime.ToFileTimeUtc
#     matches the value the launcher records via $pidStart).
#
# The override pattern relies on PowerShell's late-bound variable
# resolution: $ownerAlive (defined in Session.ps1, dot-sourced into
# this script's scope) references $pidAlive/$pidStart/$pidCmdline by
# name; reassigning those names in this scope makes the next $ownerAlive
# call pick up the cached versions. Session.ps1 stays correct for the
# launcher path, where one-shot lookups don't justify the bulk cost.
$cimCmdline = @{}
foreach ($cim in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
  if ($cim.CommandLine) { $cimCmdline[[int]$cim.ProcessId] = [string]$cim.CommandLine }
}
$procAlive = @{}
$procStart = @{}
foreach ($p in [Diagnostics.Process]::GetProcesses()) {
  $procAlive[$p.Id] = $true
  try { $procStart[$p.Id] = [string]$p.StartTime.ToFileTimeUtc() } catch {}
}
$pidAlive   = { param([int]$p) $procAlive.ContainsKey($p) }
$pidStart   = { param([int]$p) if ($procStart.ContainsKey($p))  { $procStart[$p]  } else { '' } }
$pidCmdline = { param([int]$p) if ($cimCmdline.ContainsKey($p)) { $cimCmdline[$p] } else { '' } }

$agentRoot = [IO.Path]::Combine($projectRoot, 'agent')
if ($Agent) {
  if (-not [IO.Directory]::Exists([IO.Path]::Combine($agentRoot, $Agent))) {
    Write-Error "unknown agent: $Agent"
    exit 1
  }
  $agents = @($Agent)
}
else {
  $agents = if ([IO.Directory]::Exists($agentRoot)) {
    [IO.Directory]::EnumerateDirectories($agentRoot) | ForEach-Object { [IO.Path]::GetFileName($_) }
  }
  else { @() }
}

$now = [DateTimeOffset]::UtcNow

# Collect rows as PSCustomObjects with every field populated; the
# selected columns are picked up at Format-Table time.
$rows = [Collections.Generic.List[object]]::new()
foreach ($a in $agents) {
  $manifest = [IO.Path]::Combine($agentRoot, $a, 'manifest.json')
  if (-not [IO.File]::Exists($manifest)) { continue }
  $projDir = ([IO.File]::ReadAllText($manifest) | ConvertFrom-Json).projectDir
  # Same single-segment whitelist Invoke-AgentLoad applies. Without it
  # a hostile manifest's .projectDir (e.g. '..\..\etc') would traverse
  # out of $PWD and make this tool stat arbitrary host directories.
  # Skip-with-warning instead of throwing so a single bad manifest
  # doesn't blank the entire listing.
  if ($projDir -isnot [string] -or $projDir -notmatch '^[A-Za-z0-9._-]+$' -or $projDir -in @('.', '..')) {
    [Console]::Error.WriteLine("skipping ${a}: invalid .projectDir in ${manifest}: '$projDir' (must match [A-Za-z0-9._-]+)")
    continue
  }
  $sdir = [IO.Path]::Combine($PWD.Path, $projDir, '.system', 'sessions')
  if (-not [IO.Directory]::Exists($sdir)) { continue }
  foreach ($s in [IO.Directory]::EnumerateDirectories($sdir)) {
    $owner = [IO.Path]::Combine($s, 'owner')
    $ownerPid = [IO.Path]::Combine($s, 'owner.pid')
    $row = [ordered]@{
      id         = [IO.Path]::GetFileName($s)
      agent      = $a
      state      = '-'
      pid        = '-'
      cmd        = '-'
      ppid       = '-'
      ppid_start = '-'
      ppid_cmd   = '-'
      cwd        = '-'
      user       = '-'
      host       = '-'
      created    = '-'
      age        = '-'
    }
    $mtSrc = $s
    $ownerStart = ''
    if ([IO.File]::Exists($owner)) {
      foreach ($k in 'pid', 'cmd', 'ppid', 'ppid_start', 'ppid_cmd', 'cwd', 'user', 'host', 'created') {
        $v = & $ownerGet $owner $k
        if ($v) { $row[$k] = $v }
      }
      # `start` is read for the liveness check but not surfaced as a
      # column — ppid_start already covers the parent identity tuple
      # users typically debug with.
      $ownerStart = & $ownerGet $owner 'start'
      $mtSrc = $owner
    }
    elseif ([IO.File]::Exists($ownerPid)) {
      $line = & $readFirstLine $ownerPid
      if ($line) { $row.pid = $line }
      $ownerCmdLegacy = [IO.Path]::Combine($s, 'owner.cmd')
      if ([IO.File]::Exists($ownerCmdLegacy)) {
        $row.cmd = [IO.File]::ReadAllText($ownerCmdLegacy)
      }
      $mtSrc = $ownerPid
    }
    $alive = $false
    $pidNum = 0
    if ([int]::TryParse($row.pid, [ref]$pidNum)) {
      # $ownerAlive does pid + start + cmdline match, matching launcher
      # reclaim. row.cmd is '-' for legacy sessions with no recorded
      # cmd; pass '' so $ownerAlive falls back. Same for $ownerStart
      # when the legacy owner.pid path is used.
      $expectedCmd = if ($row.cmd -eq '-') { '' } else { [string]$row.cmd }
      $alive = & $ownerAlive $pidNum $ownerStart $expectedCmd
    }
    $row.state = if ($alive) { 'alive' } else { 'dead' }
    # mtSrc is either a file (owner / owner.pid) or a directory ($s).
    # [IO.File] handles files; fall back to [IO.Directory] for dirs.
    $mt = if ([IO.File]::Exists($mtSrc)) {
      [IO.File]::GetLastWriteTimeUtc($mtSrc)
    }
    elseif ([IO.Directory]::Exists($mtSrc)) {
      [IO.Directory]::GetLastWriteTimeUtc($mtSrc)
    }
    else {
      $now.UtcDateTime
    }
    $secs = [int]($now - [DateTimeOffset]$mt).TotalSeconds
    $row.age = if ($secs -lt 60) { "${secs}s" }
    elseif ($secs -lt 3600) { "$([int]($secs/60))m" }
    elseif ($secs -lt 86400) { "$([int]($secs/3600))h" }
    else { "$([int]($secs/86400))d" }
    $rows.Add([pscustomobject]$row)
  }
}

# Build Format-Table column expressions: uppercase header label, value
# pulled from the selected property. -AutoSize makes column widths
# track the data so cmd / cwd aren't truncated when present.
$tableCols = $Columns | ForEach-Object {
  $name = $_
  @{
    Label      = $name.ToUpperInvariant()
    Expression = [scriptblock]::Create("`$_.'$name'")
  }
}
# Bash variant always prints a header line (via _emit_row h before the
# scan). Format-Table on an empty pipeline emits nothing, which would
# leave a no-sessions invocation silent and break parity with the
# POSIX tool — synthesize the header by hand in that case.
if ($rows.Count -eq 0) {
  ($Columns | ForEach-Object { $_.ToUpperInvariant() }) -join '  '
}
else {
  $rows | Format-Table -Property $tableCols -AutoSize
}
